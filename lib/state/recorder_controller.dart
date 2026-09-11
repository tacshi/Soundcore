import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/soniox_stt.dart';
import '../ai/moss_stt.dart';
import '../ai/soniox_stt_stream.dart';
import '../ai/soniox_languages.dart';
import '../ai/stt_types.dart';
import '../ai/apple_speech.dart';
import '../ai/speech_provider.dart';
import '../audio/audio_duration.dart';
import '../audio/ogg_opus.dart';
import '../audio/opus_pcm_decoder.dart';
import '../audio/opus_wave.dart';
import '../ble/ble_service.dart';
import '../ble/ble_file_pull.dart';
import '../ble/realtime_stream.dart';
import '../crypto/device_crypto.dart';
import '../platform/background_sync_service.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../wifi/wifi_export_service.dart';
import 'app_settings_store.dart';
import 'device_store.dart';
import 'export_catalog.dart';
import 'transcript_store.dart';
import 'recording.dart';
import 'moss_jobs.dart';

export 'recording.dart';
export '../ai/speech_provider.dart';

enum AppPhase { idle, scanning, connecting, ready, busy }

class RecorderController extends ChangeNotifier {
  static const _bleScanTimeout = Duration(seconds: 30);
  static const _boundReconnectDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  RecorderController({
    BleService? ble,
    bool loadPersistedState = true,
    PersistedDeviceLoader? persistedDeviceLoader,
    AppleSpeechService? appleSpeech,
    SonioxSttService? sonioxSpeech,
    MossSttService? mossSpeech,
    MossJobStore? mossJobStore,
    this.recordingShortcutScanTimeout = const Duration(seconds: 30),
  }) : _ble = ble ?? BleService(),
       _appleSpeech = appleSpeech ?? AppleSpeechService(),
       _sonioxStt = sonioxSpeech ?? SonioxSttService(),
       _mossStt = mossSpeech ?? MossSttService(),
       _persistedDeviceLoader = persistedDeviceLoader ?? DeviceStore.load {
    _subs.add(
      _ble.scanResults.listen((list) {
        devices = list;
        // If we have no saved unit yet, promote a bound D3200 from ads.
        if (lastKnownDevice == null) {
          for (final d in list) {
            if (d.isD3200 || d.looksLikeSoundcore) {
              if (d.isBoundAdvertised || bound) {
                lastKnownDevice = d;
                if (d.isBoundAdvertised) bound = true;
                activeDevice ??= d;
                unawaited(_persistDevice());
                break;
              }
            }
          }
        } else {
          // Refresh MAC/name from ads for the saved id.
          for (final d in list) {
            final saved = lastKnownDevice!;
            if (d.id == saved.id ||
                (d.macAddress != null && d.macAddress == saved.macAddress)) {
              lastKnownDevice = d;
              if (d.isBoundAdvertised) bound = true;
              if (!connected) activeDevice = d;
              break;
            }
          }
        }
        // Bound devices reconnect independently of the scan sheet. Previously
        // auto-connect only lived in that sheet, so a persisted bound device
        // stayed offline until the user opened it manually.
        unawaited(_tryAutoConnectBoundDevice(list));
        notifyListeners();
      }),
    );
    _subs.add(
      _ble.connectionState.listen((up) {
        connected = up;
        if (!up) {
          final wifiHandoff = isWifiExportSession;
          // Ignore transient "not ready" while a connect attempt is still running.
          // Emitting false mid-GATT used to force phase=idle and re-enable multi-tap.
          if (phase == AppPhase.connecting || _ble.isConnecting) {
            notifyListeners();
            return;
          }
          phase = wifiHandoff ? AppPhase.busy : AppPhase.idle;
          // Keep lastKnown* + bound + activeDevice for Device-tab offline UI.
          if (info != null) lastKnownInfo = info;
          if (activeDevice != null) lastKnownDevice = activeDevice;
          info = null;
          files = [];
          selectedFileIds.clear();
          selecting = false;
          recording = false;
          _snapshotLiveText();
          _currentRecording?.active = false;
          _recordWireStatus = 0;
          if (!wifiHandoff) {
            encryptReady = false;
            _crypto.resetSession();
            _encryptCompleter = null;
          }
          _stopBatteryPoll();
          _fileListPageTimeout?.cancel();
          _loadingFileListPages = false;
          _completeFileRefresh();
          unawaited(_realtime.stop());
          realtimeState = const RealtimeStreamState();
          unawaited(_finishStreamStt());
          unawaited(stopPlayback());
          // Reconnect unexpected drops immediately, except for the expected
          // BLE→Wi-Fi handoff; that reconnect starts after transfer cleanup.
          if (bound && !_explicitDisconnect && !wifiHandoff) {
            _resetBoundReconnectBackoff();
            unawaited(startScan());
          }
          _explicitDisconnect = false;
        } else {
          _resetBoundReconnectBackoff();
          // Connected (or reconnected) — keep battery fresh while linked.
          // Also drop any stale "未连接"-type error a command fired mid-drop
          // (e.g. a battery poll racing the Wi‑Fi SoftAP handoff) — it no
          // longer reflects reality and would otherwise stick around
          // forever next to a now-online status pill.
          errorMessage = null;
          _startBatteryPoll();
        }
        notifyListeners();
      }),
    );
    _subs.add(_ble.packets.listen(_onPacket));
    _subs.add(
      _ble.logs.listen((m) {
        logs = [m, ...logs].take(80).toList();
        notifyListeners();
      }),
    );

    _wifi = WifiExportService(
      blePackets: _ble.packets,
      bleWrite: _ble.writeCommand,
      crypto: _crypto,
    );
    _realtime = RealtimeBleStream(
      packets: _ble.packets,
      write: _ble.writeCommand,
      crypto: _crypto,
      onDecryptedFrame: _onRealtimeOpusFrame,
    );
    _blePull = BleFilePull(
      packets: _ble.packets,
      write: _ble.writeCommand,
      crypto: _crypto,
    );
    _subs.add(
      _wifi.progress.listen((p) {
        exportProgress = p;
        notifyListeners();
      }),
    );
    _subs.add(_realtime.stateStream.listen(_onRealtimeState));
    _wirePlayer();
    _mossJobs = MossJobQueue(
      service: _mossStt,
      store: mossJobStore ?? MossJobStore(inMemory: !loadPersistedState),
      apiKey: () => _mossStt.apiKey,
      canStart: () => !_disposed && _fileJobKey == null && !_liveProcessing,
      onChanged: notifyListeners,
      onResult: (job, result) async {
        await _transcriptsLoaded;
        if (_disposed || job.discarded) return;
        if (!await File(job.path).exists()) throw const MossException('audio');
        final path =
            recordingView(RecordingReference(path: job.path)).path ?? job.path;
        if (_disposed || job.discarded) return;
        rememberTranscript(
          path,
          result.text,
          provider: SttProvider.moss,
          sourceLanguage: result.language ?? 'auto',
        );
        await _persistTranscripts(strict: true);
        final session = _sessionForReference(RecordingReference(path: path));
        if (session != null) {
          session.error = null;
          session.text = result.text;
        }
      },
    );
    _settingsReady = !loadPersistedState;
    _settingsLoaded = loadPersistedState
        ? _loadPersistedSettings().whenComplete(() => _settingsReady = true)
        : Future<void>.value();
    if (loadPersistedState) {
      unawaited(_settingsLoaded);
      unawaited(_loadLocalExports());
      _transcriptsLoaded = _loadPersistedTranscripts();
      unawaited(
        Future.wait([
          _settingsLoaded,
          _transcriptsLoaded,
        ]).then((_) => _mossJobs.load()),
      );
    }
    if (loadPersistedState || persistedDeviceLoader != null) {
      _persistedDeviceLoaded = _loadPersistedDevice();
      unawaited(_persistedDeviceLoaded);
    } else {
      _persistedDeviceLoaded = Future<void>.value();
    }
  }

  String? get mossApiKeyStored => _mossStt.apiKeyOverride;
  bool get mossConfigured => _mossStt.apiKey != null;
  String? get mossRecoveryError => _mossJobs.loadError;

  Future<void> validateAndSaveMossApiKey(String key) async {
    final candidate = key.trim();
    if (candidate.isEmpty) throw const MossException('credentials');
    await _mossStt.validateKey(candidate);
    if (_disposed) return;
    final previous = _mossStt.apiKeyOverride;
    _mossStt.apiKeyOverride = candidate;
    try {
      await _persistSettings(strict: true);
    } catch (_) {
      _mossStt.apiKeyOverride = previous;
      rethrow;
    }
    notifyListeners();
  }

  void clearMossApiKey() {
    _mossStt.apiKeyOverride = null;
    unawaited(_persistSettings());
    notifyListeners();
  }

  Future<void> _enqueueMossRecording(
    _RecordingSession owner,
    String path,
  ) async {
    if (_disposed ||
        owner.active ||
        owner.paused ||
        !owner.ended ||
        _finalizingRecordings.contains(_recordingKey(path: path)) ||
        owner.configuration.provider != SttProvider.moss ||
        !owner.configuration.enabled ||
        !_isConfigured(owner.configuration)) {
      return;
    }
    try {
      await _mossJobs.enqueue(
        _recordingKey(path: path),
        path,
        key: owner.configuration.mossKey,
      );
    } catch (_) {
      owner.error = '无法保存转写任务，请在录音详情中重试';
      notifyListeners();
    }
  }

  Future<void> _loadPersistedSettings() async {
    final s = await AppSettingsStore.load();
    if (s.sonioxApiKey != null) _sonioxStt.apiKeyOverride = s.sonioxApiKey;
    _mossStt.apiKeyOverride = s.mossApiKey;
    autoTranscribe = s.autoTranscribe;
    autoRealtime = s.autoRealtime;
    transcriptLanguage = s.transcriptLanguage;
    appleSourceLanguage = s.appleSourceLanguage;
    translationTargetLanguage = s.translationTargetLanguage;
    ownerLanguage = isSonioxLanguage(s.ownerLanguage)
        ? s.ownerLanguage.toLowerCase()
        : 'zh';
    guestLanguage = isSonioxLanguage(s.guestLanguage)
        ? s.guestLanguage.toLowerCase()
        : 'en';
    if (ownerLanguage == guestLanguage) {
      ownerLanguage = 'zh';
      guestLanguage = 'en';
    }
    sttMode = autoTranscribe ? s.sttMode : SttDisplayMode.transcription;
    await refreshAppleCapabilities();
    if (_disposed) return;
    speechProvider = initialSpeechProvider(
      saved: s.speechProvider,
      appleSupported: appleCapabilities.supported,
      sonioxConfigured: _sonioxStt.isConfigured,
    );
    if (speechProvider == SttProvider.moss ||
        (speechProvider == SttProvider.apple &&
            sttMode == SttDisplayMode.conversation)) {
      sttMode = SttDisplayMode.transcription;
    }
    if (s.speechProvider == null) unawaited(_persistSettings());
    notifyListeners();
  }

  Future<void> _persistSettings({bool strict = false}) async {
    await AppSettingsStore.save(
      AppSettings(
        speechProvider: speechProvider,
        appleSourceLanguage: appleSourceLanguage,
        sonioxApiKey: _sonioxStt.apiKeyOverride,
        mossApiKey: _mossStt.apiKeyOverride,
        autoTranscribe: autoTranscribe,
        autoRealtime: autoRealtime,
        transcriptLanguage: transcriptLanguage,
        sttMode: sttMode,
        translationTargetLanguage: translationTargetLanguage,
        ownerLanguage: ownerLanguage,
        guestLanguage: guestLanguage,
      ),
      strict: strict,
    );
  }

  bool get appleSpeechReady =>
      appleSourceLanguage.isNotEmpty &&
      appleCapabilities.supported &&
      appleCapabilities.speechStatus == SpeechResourceStatus.ready &&
      !appleCapabilitiesLoading;

  bool get appleTranslationAvailable =>
      appleSourceLanguage.isNotEmpty &&
      appleCapabilities.supported &&
      appleCapabilities.translationStatus == SpeechResourceStatus.ready &&
      !appleCapabilitiesLoading;

  bool get conversationModeAvailable =>
      autoTranscribe && speechProvider == SttProvider.soniox;

  Future<void> refreshAppleCapabilities() async {
    final revision = ++_capabilityRevision;
    appleCapabilitiesLoading = true;
    appleSetupError = null;
    notifyListeners();
    try {
      var result = await _appleSpeech.capabilities(
        sourceLanguage: appleSourceLanguage.isEmpty
            ? null
            : appleSourceLanguage,
        targetLanguage: translationTargetLanguage,
      );
      if (_disposed || revision != _capabilityRevision) return;
      if (appleSourceLanguage.isEmpty &&
          result.suggestedSourceLanguage != null) {
        appleSourceLanguage = result.suggestedSourceLanguage!;
        result = await _appleSpeech.capabilities(
          sourceLanguage: appleSourceLanguage,
          targetLanguage: translationTargetLanguage,
        );
        if (_disposed || revision != _capabilityRevision) return;
      }
      appleCapabilities = result;
    } catch (error) {
      if (_disposed || revision != _capabilityRevision) return;
      appleCapabilities = const AppleSpeechCapabilities.unsupported();
      appleSetupError = _speechErrorMessage(error);
    } finally {
      if (!_disposed && revision == _capabilityRevision) {
        appleCapabilitiesLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> prepareAppleLanguages() async {
    if (appleLanguagePreparationBusy) return;
    if (appleSourceLanguage.isEmpty) {
      appleSetupError = '请选择录音语言';
      notifyListeners();
      return;
    }
    appleLanguagePreparationBusy = true;
    appleSetupError = null;
    notifyListeners();
    try {
      await _appleSpeech.prepareLanguages(
        sourceLanguage: appleSourceLanguage,
        targetLanguage: translationTargetLanguage,
      );
      if (_disposed) return;
      await refreshAppleCapabilities();
      await _persistSettings();
    } catch (error) {
      if (!_disposed) {
        // Speech may have installed even if the optional translation pair failed.
        await refreshAppleCapabilities();
        appleSetupError = _speechErrorMessage(error);
      }
    } finally {
      if (!_disposed) {
        appleLanguagePreparationBusy = false;
        notifyListeners();
      }
    }
  }

  void setSpeechProvider(SttProvider provider) {
    if (provider == speechProvider) return;
    speechProvider = provider;
    if (provider == SttProvider.moss ||
        (provider == SttProvider.apple &&
            sttMode == SttDisplayMode.conversation)) {
      sttMode = SttDisplayMode.transcription;
    }
    notifyListeners();
    unawaited(_persistSettings());
    if (provider == SttProvider.apple) unawaited(refreshAppleCapabilities());
  }

  void setAppleSourceLanguage(String language) {
    final code = language.trim();
    if (appleSourceLanguage == code) return;
    appleSourceLanguage = code;
    unawaited(refreshAppleCapabilities());
    unawaited(_persistSettings());
  }

  _SpeechConfiguration get _settingsConfiguration => _SpeechConfiguration(
    provider: speechProvider,
    sourceLanguage: speechProvider == SttProvider.apple
        ? appleSourceLanguage
        : transcriptLanguage,
    targetLanguage: translationTargetLanguage,
    ownerLanguage: ownerLanguage,
    guestLanguage: guestLanguage,
    mode: speechProvider == SttProvider.moss
        ? SttDisplayMode.transcription
        : sttMode,
    enabled: autoTranscribe,
    appleReady: appleSpeechReady,
    appleTranslationReady: appleTranslationAvailable,
    sonioxKey: _sonioxStt.apiKey,
    mossKey: _mossStt.apiKey,
  );

  _RecordingSession? get _currentRecording =>
      _recordingSessions[_currentSessionId];
  bool get _liveProcessing =>
      recording ||
      realtimeState.active ||
      streamingSttActive ||
      _streamSttStarting ||
      (_currentRecording?.finalizing ?? false);
  // Final BLE/file callbacks can arrive after capture and stream flags clear.
  // They still belong to this take and must never adopt the next provider.
  _SpeechConfiguration get _activeConfiguration =>
      _liveConfiguration ?? _settingsConfiguration;
  bool _isConfigured(_SpeechConfiguration config) =>
      config.provider == SttProvider.apple
      ? config.appleReady && config.sourceLanguage.isNotEmpty
      : config.provider == SttProvider.moss
      ? config.mossKey?.isNotEmpty == true
      : config.sonioxKey?.isNotEmpty == true;
  bool get _activeSttConfigured => _isConfigured(_activeConfiguration);
  bool get _activeAutoTranscribe => _activeConfiguration.enabled;
  String get activeTranslationTargetLanguage =>
      _activeConfiguration.targetLanguage;
  String get activeOwnerLanguage => _activeConfiguration.ownerLanguage;
  String get activeGuestLanguage => _activeConfiguration.guestLanguage;

  RecordingReference? get currentRecordingReference {
    final session = _currentRecording;
    if (session == null) return null;
    return RecordingReference(
      sessionId: session.id,
      fileId: session.fileId,
      path: session.path,
    );
  }

  String _recordingKey({int? fileId, String? path}) {
    final id = fileId ?? (path == null ? null : fileIdFromPath(path));
    return id == null ? 'path:$path' : 'file:$id';
  }

  String _referenceKey(RecordingReference ref) {
    final session = _recordingSessions[ref.sessionId];
    return _recordingKey(
      fileId: session?.fileId ?? ref.fileId,
      path: session?.path ?? ref.path,
    );
  }

  _RecordingSession? _sessionForReference(RecordingReference ref) {
    if (ref.sessionId != null) return _recordingSessions[ref.sessionId];
    final id =
        ref.fileId ?? (ref.path == null ? null : fileIdFromPath(ref.path!));
    for (final session in _recordingSessions.values.toList().reversed) {
      if (id != null && session.fileId == id ||
          ref.path != null && session.path == ref.path) {
        return session;
      }
    }
    return null;
  }

  RecordingViewData recordingView(RecordingReference ref) {
    final session = _sessionForReference(ref);
    final id =
        session?.fileId ??
        ref.fileId ??
        (ref.path == null ? null : fileIdFromPath(ref.path!));
    var path = id == null ? null : localPathsByFileId[id];
    if (path == null && id != null) {
      for (final candidate in exportedPaths) {
        if (fileIdFromPath(candidate) == id) {
          path = candidate;
          break;
        }
      }
    }
    path ??= session?.path ?? ref.path;
    final key = _recordingKey(fileId: id, path: path);
    final metadata = _transcriptMetadata[key];
    final stored = path == null
        ? (id == null ? null : transcriptForFileId(id))
        : transcriptForPath(path);
    final current = session != null && session.id == _currentSessionId;
    final readingLive = current && (session.active || session.finalizing);
    final text = readingLive ? session.text : (stored ?? session?.text ?? '');
    final savedTranslation = _recordingTranslations[key];
    final translated = readingLive
        ? session.translation
        : (savedTranslation?.sourceRevision == metadata?.revision
              ? savedTranslation
              : null);
    final label = path == null ? '' : ExportCatalog.editableLabelFromPath(path);
    final title = label.isNotEmpty
        ? label
        : id == null
        ? '当前录音'
        : _recordingDateTitle(id);
    return RecordingViewData(
      reference: RecordingReference(
        sessionId: ref.sessionId,
        fileId: id,
        path: path,
      ),
      path: path,
      title: title,
      text: text,
      translation: translated ?? (stored == null ? session?.translation : null),
      sourceLanguage:
          metadata?.sourceLanguage ?? session?.configuration.sourceLanguage,
      mode: session?.configuration.mode ?? SttDisplayMode.transcription,
      provider:
          metadata?.provider ??
          session?.configuration.provider ??
          speechProvider,
      transcriptionEnabled: session?.configuration.enabled ?? autoTranscribe,
      speechReady: _isConfigured(
        session?.configuration ?? _settingsConfiguration,
      ),
      live: current && recording,
      paused: session?.paused ?? false,
      audioLocked:
          (current && (recording || session.finalizing)) ||
          _isRecordingAudioLocked(id, path),
      processing:
          _fileJobKey == key ||
          session?.finalizing == true ||
          (_mossJobs.forRecording(key)?.pending ?? false) ||
          _mossJobs.active?.recordingKey == key,
      error:
          _recordingErrors[key] ??
          _mossJobs.forRecording(key)?.error ??
          session?.error,
      progress: _fileJobKey == key
          ? fileTranscriptionProgress
          : _mossJobs.forRecording(key)?.progress,
    );
  }

  String _recordingDateTitle(int id) {
    final date = DateTime.fromMillisecondsSinceEpoch(id * 1000);
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${date.year}/${pad(date.month)}/${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  bool _isRecordingAudioLocked(int? id, String? path) {
    final current = _currentRecording;
    final matches =
        current != null &&
        ((id != null && current.fileId == id) ||
            (path != null && current.path == path));
    return matches &&
            (recording || realtimeState.active || current.finalizing) ||
        (id != null && recording && realtimeState.fileId == id) ||
        _finalizingRecordings.contains(_recordingKey(fileId: id, path: path));
  }

  void _requireFinishedRecording(String path) {
    if (_isRecordingAudioLocked(fileIdFromPath(path), path)) {
      throw StateError('录音保存后再试');
    }
  }

  bool get fileProcessingBusy =>
      _fileJobKey != null || _mossJobs.busy || _liveProcessing;

  void _bindCurrentRecording({int? fileId, String? path}) {
    final session = _currentRecording;
    if (session == null) return;
    // A previous take can finish asynchronously after the next one starts.
    if (session.fileId != null && fileId != null && session.fileId != fileId) {
      return;
    }
    session.fileId ??= fileId ?? (path == null ? null : fileIdFromPath(path));
    if (path != null) session.path = path;
  }

  void _snapshotLiveText() {
    final session = _currentRecording;
    if (session == null) return;
    session.text =
        (transcriptPartial?.isNotEmpty == true
                ? transcriptPartial!
                : transcript)
            .trim();
    session.error = transcriptError;
    final turns = translationTurns.where((turn) => turn.text.trim().isNotEmpty);
    if (turns.isNotEmpty) {
      session.translation = RecordingTranslation(
        text: turns.map((turn) => turn.text.trim()).join('\n\n'),
        sourceLanguage: session.configuration.sourceLanguage,
        targetLanguage: session.configuration.targetLanguage,
        provider: session.configuration.provider,
        sourceRevision: 0,
      );
    }
  }

  void _saveLiveRecording(_RecordingSession session, {String? path}) {
    final destination = path ?? session.path;
    if (destination == null || session.text.isEmpty) return;
    session.path = destination;
    rememberTranscript(
      destination,
      session.text,
      provider: session.configuration.provider,
      sourceLanguage: session.configuration.sourceLanguage,
    );
    final translated = session.translation;
    if (translated != null) {
      final key = _recordingKey(path: destination);
      _recordingTranslations[key] = RecordingTranslation(
        text: translated.text,
        sourceLanguage: translated.sourceLanguage,
        targetLanguage: translated.targetLanguage,
        provider: translated.provider,
        sourceRevision: _transcriptMetadata[key]!.revision,
      );
      unawaited(_persistTranscripts());
    }
  }

  String _speechErrorMessage(Object error) {
    if (error is MossException) return error.message;
    final code = error is PlatformException ? error.code : error.toString();
    return switch (code) {
      'unsupported' => '此设备不支持设备端处理，请在设置中选择云端语音服务',
      'language_unsupported' => '不支持此语言，请更换语言',
      'resources_missing' => '请在设置中下载所需语言',
      'cancelled' => '处理已取消，可重试',
      'busy' => '请等待当前处理完成后重试',
      'audio_invalid' => '无法读取录音，请重新下载',
      _ => '处理失败，请重试',
    };
  }

  Future<void> _loadPersistedDevice() async {
    final saved = await _persistedDeviceLoader();
    if (saved.device == null && !saved.bound) return;
    lastKnownDevice = saved.device;
    lastKnownInfo = saved.info;
    if (saved.bound) bound = true;
    // Surface on Device tab even before this session connects.
    activeDevice ??= lastKnownDevice;
    notifyListeners();
    if (saved.bound && saved.device != null) {
      unawaited(_startBoundDeviceReconnect());
    }
  }

  Future<void> _startBoundDeviceReconnect() async {
    if (connected ||
        phase == AppPhase.scanning ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    statusMessage = '正在自动连接已绑定设备…';
    await startScan();
  }

  /// Handle the one-shot action exposed through the iOS Action Button.
  ///
  /// Repeated invocations coalesce while a request is pending or sending. A
  /// request is never retained beyond its reconnect attempt, preventing a
  /// later unrelated auto-reconnect from unexpectedly starting a recording.
  Future<void> requestRecordingFromShortcut() async {
    shortcutNavigationRevision++;
    notifyListeners();

    if (_recordingShortcutPending || _recordingShortcutStarting) return;
    if (recording) {
      statusMessage = '录音中';
      errorMessage = null;
      notifyListeners();
      return;
    }
    if (isWifiExportSession || isExporting) {
      _failRecordingShortcut('正在导出录音，暂时无法开始新的录音');
      return;
    }

    _recordingShortcutPending = true;
    statusMessage = connected ? '正在开始快捷录音…' : '快捷录音：正在准备连接…';
    errorMessage = null;
    notifyListeners();

    await _persistedDeviceLoaded;
    if (!_recordingShortcutPending) return;

    if (recording) {
      _finishRecordingShortcut();
      statusMessage = '录音中';
      notifyListeners();
      return;
    }

    if (connected && _ble.isConnected) {
      if (blocksRecordingControl) {
        _failRecordingShortcut('设备正忙，请稍后再按一次操作按钮');
        return;
      }
      await _runPendingRecordingShortcutIfReady();
      return;
    }

    if (!bound || lastKnownDevice == null) {
      _failRecordingShortcut('未找到已绑定的录音豆，请先在应用中连接设备');
      return;
    }

    statusMessage = '快捷录音：正在连接 ${lastKnownDevice!.displayName}…';
    _startRecordingShortcutScanTimeout();
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      _recordingShortcutConnecting = true;
      _recordingShortcutTimer?.cancel();
      _recordingShortcutTimer = null;
    }
    notifyListeners();

    if (phase != AppPhase.scanning &&
        phase != AppPhase.connecting &&
        !_ble.isConnecting) {
      await startScan();
      if (_recordingShortcutPending &&
          !connected &&
          phase == AppPhase.idle &&
          errorMessage != null) {
        _failRecordingShortcut(errorMessage!);
      }
    }
  }

  void _startRecordingShortcutScanTimeout() {
    _recordingShortcutTimer?.cancel();
    _recordingShortcutTimer = Timer(recordingShortcutScanTimeout, () {
      if (!_recordingShortcutPending || _recordingShortcutConnecting) return;
      _failRecordingShortcut('未在 30 秒内找到已绑定的录音豆，请靠近设备后重试');
    });
  }

  void _finishRecordingShortcut() {
    _recordingShortcutPending = false;
    _recordingShortcutConnecting = false;
    _recordingShortcutTimer?.cancel();
    _recordingShortcutTimer = null;
  }

  void _failRecordingShortcut(String message) {
    _finishRecordingShortcut();
    statusMessage = '快捷录音未开始';
    errorMessage = message;
    notifyListeners();
  }

  /// Returns null when there was no shortcut request, true for success/no-op,
  /// and false when the BLE start command failed.
  Future<bool?> _runPendingRecordingShortcutIfReady() async {
    if (!_recordingShortcutPending || _recordingShortcutStarting) return null;
    if (recording) {
      _finishRecordingShortcut();
      statusMessage = '录音中';
      notifyListeners();
      return true;
    }
    if (!connected || !_ble.isConnected) return null;
    if (isWifiExportSession || isExporting) {
      _failRecordingShortcut('正在导出录音，暂时无法开始新的录音');
      return false;
    }
    if (blocksRecordingControl) {
      _failRecordingShortcut('设备正忙，请稍后再按一次操作按钮');
      return false;
    }

    _finishRecordingShortcut();
    _recordingShortcutStarting = true;
    try {
      final started = await _startRecordChecked();
      if (!started) {
        statusMessage = '快捷录音未开始';
        notifyListeners();
      }
      return started;
    } finally {
      _recordingShortcutStarting = false;
    }
  }

  Future<void> _tryAutoConnectBoundDevice(List<ScannedDevice> scanned) async {
    if (!bound ||
        connected ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    final saved = lastKnownDevice;
    if (saved == null) return;

    ScannedDevice? target;
    for (final candidate in scanned) {
      final sameId = candidate.id == saved.id;
      final sameMac =
          saved.macAddress != null &&
          candidate.macAddress != null &&
          candidate.macAddress == saved.macAddress;
      if (sameId || sameMac) {
        target = candidate;
        break;
      }
    }
    if (target == null) return;

    await connect(target);
  }

  Future<void> _persistDevice() async {
    final d = activeDevice ?? lastKnownDevice;
    if (d == null && !bound) {
      await DeviceStore.clear();
      return;
    }
    await DeviceStore.save(
      bound: bound,
      device: d,
      info: info ?? lastKnownInfo,
    );
  }

  Future<void> _loadPersistedTranscripts() async {
    final saved = await TranscriptStore.load();
    // Merge so a transcript completed during startup is never overwritten.
    for (final entry in saved.byPath.entries) {
      transcriptsByPath.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.byFileId.entries) {
      transcriptsByFileId.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.aliasesByPath.entries) {
      speakerAliasesByPath.putIfAbsent(
        entry.key,
        () => Map<String, String>.from(entry.value),
      );
    }
    for (final entry in saved.aliasesByFileId.entries) {
      speakerAliasesByFileId.putIfAbsent(
        entry.key,
        () => Map<String, String>.from(entry.value),
      );
    }
    for (final entry in saved.metadata.entries) {
      _transcriptMetadata.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.translations.entries) {
      final metadata = _transcriptMetadata[entry.key];
      if (metadata?.revision == entry.value.sourceRevision) {
        _recordingTranslations.putIfAbsent(entry.key, () => entry.value);
      }
    }
    notifyListeners();
  }

  Future<void> _persistTranscripts({bool strict = false}) async {
    await _transcriptsLoaded;
    await TranscriptStore.save(
      byPath: transcriptsByPath,
      byFileId: transcriptsByFileId,
      aliasesByPath: speakerAliasesByPath,
      aliasesByFileId: speakerAliasesByFileId,
      metadata: _transcriptMetadata,
      translations: _recordingTranslations,
      strict: strict,
    );
  }

  void _onRealtimeState(RealtimeStreamState s) {
    if (s.fileId != null || s.path != null) {
      final owner = _sessionForReference(
        RecordingReference(fileId: s.fileId, path: s.path),
      );
      if (owner != null && owner.id != _currentSessionId) {
        if (s.path != null && s.bytesReceived > 0 && !s.active) {
          _registerExportedPaths([s.path!]);
          _saveLiveRecording(owner, path: s.path);
          final key = _recordingKey(path: s.path);
          _finalizingRecordings.add(key);
          unawaited(
            _convertExportToWav(s.path!).whenComplete(() {
              _finalizingRecordings.remove(key);
              unawaited(_enqueueMossRecording(owner, s.path!));
              notifyListeners();
            }),
          );
        }
        notifyListeners();
        return;
      }
    }
    final wasActive = realtimeState.active;
    realtimeState = s;
    _bindCurrentRecording(fileId: s.fileId, path: s.path);
    if (s.path != null && s.bytesReceived > 0) {
      final path = s.path!;
      _registerExportedPaths([path]);
      // Prefer low-latency PCM stream STT; fall back to rolling Ogg batch.
      if (s.active &&
          _activeAutoTranscribe &&
          !_streamSttPreferred &&
          _activeConfiguration.provider == SttProvider.soniox &&
          !sonioxTranslationModeActive) {
        unawaited(
          _maybeTranscribeRolling(path, s.bytesReceived, finalPass: false),
        );
      }
    }
    // When a session finishes with data, keep path listed for playback + final STT.
    if (!s.active && s.path != null && s.bytesReceived > 0) {
      final finishedPath = s.path!;
      final finishedKey = _recordingKey(path: finishedPath);
      _finalizingRecordings.add(finishedKey);
      unawaited(
        _convertExportToWav(finishedPath).whenComplete(() {
          _finalizingRecordings.remove(finishedKey);
          final owner = _sessionForReference(
            RecordingReference(path: finishedPath),
          );
          if (owner?.configuration.provider == SttProvider.moss) {
            owner!.finalizing = false;
            unawaited(_enqueueMossRecording(owner, finishedPath));
          }
          notifyListeners();
        }),
      );
      statusMessage =
          '实时录音已保存 ${s.path!.split('/').last}（${(s.bytesReceived / 1024).toStringAsFixed(1)} KB）';
      // Attach any live transcript we already have to this file card.
      final session = _sessionForReference(
        RecordingReference(fileId: s.fileId, path: s.path),
      );
      if (session != null) {
        if (session.id == _currentSessionId) _snapshotLiveText();
        _saveLiveRecording(session, path: s.path);
      }
      if (_activeAutoTranscribe && _recordWireStatus != 2) {
        if (_streamSttPreferred) {
          unawaited(_finishStreamStt(bindPath: s.path));
        } else if (_activeConfiguration.provider == SttProvider.soniox) {
          unawaited(
            _maybeTranscribeRolling(s.path!, s.bytesReceived, finalPass: true),
          );
        }
      }
    } else if (wasActive && !s.active) {
      unawaited(_finishStreamStt(bindPath: s.path));
      _scheduleAutoTransferMissing();
    }
    notifyListeners();
  }

  /// Store per-file transcript so Home list can show text (not just a button).
  void rememberTranscript(
    String path,
    String text, {
    SttProvider? provider,
    String? sourceLanguage,
  }) {
    final t = normalizeSttText(text);
    if (path.isEmpty || t.isEmpty) return;
    final key = _recordingKey(path: path);
    final previous = _rawTranscriptForPath(path);
    final metadata = _transcriptMetadata[key];
    final changed =
        previous != t ||
        metadata == null ||
        (sourceLanguage != null && sourceLanguage != metadata.sourceLanguage);
    if (changed) {
      _clearSpeakerAliases(path);
      _recordingTranslations.remove(key);
    }
    _transcriptMetadata[key] = TranscriptMetadata(
      provider: provider ?? metadata?.provider ?? SttProvider.soniox,
      sourceLanguage: sourceLanguage ?? metadata?.sourceLanguage,
      revision: (metadata?.revision ?? 0) + (changed ? 1 : 0),
    );
    transcriptsByPath[path] = t;
    // Also index by file id when known.
    final id = fileIdFromPath(path);
    if (id != null) transcriptsByFileId[id] = t;
    unawaited(_persistTranscripts());
  }

  String? transcriptForPath(String path) {
    final raw = _rawTranscriptForPath(path);
    if (raw == null) return null;
    return applyTranscriptSpeakerAliases(
      normalizeSttText(raw),
      _speakerAliasesForPath(path),
    );
  }

  String? _rawTranscriptForPath(String path) {
    final direct = transcriptsByPath[path];
    if (direct != null && direct.isNotEmpty) return direct;
    final id = fileIdFromPath(path);
    if (id != null) {
      final byId = transcriptsByFileId[id];
      if (byId != null && byId.isNotEmpty) return byId;
    }
    // Only mirror *live* draft onto the newest export while a session is active.
    // Avoids showing a previous take's text on the file list after a new start.
    if (isLiveSession &&
        _currentRecording != null &&
        (fileIdFromPath(path) == _currentRecording!.fileId ||
            path == _currentRecording!.path)) {
      final live = transcript.trim();
      if (live.isNotEmpty) return live;
      final partial = transcriptPartial?.trim();
      if (partial != null && partial.isNotEmpty) return partial;
    }
    return null;
  }

  String? transcriptForFileId(int fileId) {
    final raw = transcriptsByFileId[fileId];
    if (raw == null) return null;
    return applyTranscriptSpeakerAliases(
      normalizeSttText(raw),
      speakerAliasesByFileId[fileId] ?? const {},
    );
  }

  List<TranscriptSpeaker> transcriptSpeakersForPath(String path) {
    final raw = _rawTranscriptForPath(path);
    if (raw == null) return const [];
    return extractTranscriptSpeakers(
      normalizeSttText(raw),
      aliases: _speakerAliasesForPath(path),
    );
  }

  Future<void> renameTranscriptSpeaker(
    String path,
    String speakerId,
    String value,
  ) async {
    final id = speakerId.trim();
    final raw = _rawTranscriptForPath(path);
    if (id.isEmpty ||
        raw == null ||
        !extractTranscriptSpeakers(
          normalizeSttText(raw),
        ).any((speaker) => speaker.id == id)) {
      throw ArgumentError('说话人不存在');
    }

    var alias = value.trim();
    alias = alias.replaceFirst(RegExp(r'[:：]\s*$'), '').trimRight();
    if (alias.isEmpty) throw ArgumentError('请输入说话人姓名');
    if (alias.runes.length > 40) throw ArgumentError('说话人姓名不能超过 40 个字符');

    final defaultLabel = '说话人 $id';
    _setSpeakerAlias(speakerAliasesByPath, path, id, alias, defaultLabel);
    final fileId = fileIdFromPath(path);
    if (fileId != null) {
      _setSpeakerAlias(speakerAliasesByFileId, fileId, id, alias, defaultLabel);
    }
    notifyListeners();
    await _persistTranscripts();
  }

  Map<String, String> _speakerAliasesForPath(String path) {
    final direct = speakerAliasesByPath[path];
    if (direct != null) return direct;
    final id = fileIdFromPath(path);
    return id == null ? const {} : speakerAliasesByFileId[id] ?? const {};
  }

  void _setSpeakerAlias<K>(
    Map<K, Map<String, String>> aliasesByRecording,
    K recording,
    String speakerId,
    String alias,
    String defaultLabel,
  ) {
    if (alias == defaultLabel) {
      final aliases = aliasesByRecording[recording];
      aliases?.remove(speakerId);
      if (aliases?.isEmpty ?? false) aliasesByRecording.remove(recording);
      return;
    }
    aliasesByRecording.putIfAbsent(
      recording,
      () => <String, String>{},
    )[speakerId] = alias;
  }

  void _clearSpeakerAliases(String path) {
    speakerAliasesByPath.remove(path);
    final id = fileIdFromPath(path);
    if (id != null) speakerAliasesByFileId.remove(id);
  }

  /// Live BLE Opus frame → PCM16 → provider WS STT (when auto-transcribe on).
  void _onRealtimeOpusFrame(Uint8List frame) {
    if (_activeConfiguration.provider == SttProvider.moss ||
        !_activeAutoTranscribe ||
        !_activeSttConfigured ||
        _recordWireStatus == 2) {
      return;
    }
    if (!_preferStreamStt) return;
    if (!_opusPcm.ensureStarted()) {
      _preferStreamStt = false;
      if (sonioxTranslationModeActive) {
        transcriptError = '$_activeTranslationModeLabel无法启动实时音频解码';
        notifyListeners();
      }
      return;
    }
    final pcm = _opusPcm.decodeFrame(frame);
    if (pcm == null || pcm.isEmpty) return;
    pcmFramesDecoded = _opusPcm.framesDecoded;

    final session = _sttStream;
    if (session != null && session.isServerReady) {
      session.sendPcm(pcm);
      return;
    }
    // Buffer PCM while WS handshakes so early frames are not dropped.
    _pendingPcm.add(pcm);
    if (_pendingPcm.length > 16000 * 2 * 5) {
      // Cap ~5s pending to avoid RAM blow-up if WS never comes up.
      final all = _pendingPcm.toBytes();
      _pendingPcm.clear();
      _pendingPcm.add(Uint8List.sublistView(all, all.length ~/ 2));
    }
    unawaited(_ensureStreamStt());
  }

  /// Prefer PCM WS when decode works; false after hard stream failure → Ogg batch.
  bool get _streamSttPreferred =>
      _activeConfiguration.provider != SttProvider.moss &&
      _preferStreamStt &&
      _opusPcm.isReady &&
      _activeAutoTranscribe;

  Future<bool> _ensureStreamStt() async {
    if (_activeConfiguration.provider == SttProvider.moss ||
        !_activeAutoTranscribe ||
        !_activeSttConfigured ||
        !_preferStreamStt) {
      return false;
    }
    if (_sttStream != null && _sttStream!.isServerReady) {
      streamingSttActive = true;
      _flushPendingPcm();
      return true;
    }
    if (_streamSttStarting) return false;
    final config = _activeConfiguration;
    if (config.provider == SttProvider.apple &&
        config.mode == SttDisplayMode.translation &&
        !config.appleTranslationReady) {
      transcriptError = '请在设置中下载翻译语言';
      _snapshotLiveText();
      notifyListeners();
      // Recognition remains useful even if translation resources are missing.
    }
    if (!_opusPcm.ensureStarted()) {
      _preferStreamStt = false;
      if (sonioxTranslationModeActive) {
        transcriptError = '$_activeTranslationModeLabel无法启动实时音频解码';
        notifyListeners();
      }
      return false;
    }

    _streamSttStarting = true;
    final revision = ++_sttLifecycleRevision;
    SttStreamSession? session;
    StreamSubscription<SttStreamEvent>? subscription;
    try {
      final previousSession = _sttStream;
      final previousSubscription = _sttStreamSub;
      _sttStream = null;
      _sttStreamSub = null;
      await previousSubscription?.cancel();
      await previousSession?.close();
      await previousSession?.dispose();
      if (revision != _sttLifecycleRevision) return false;

      if (config.provider == SttProvider.apple) {
        await _fileCancellation;
        if (revision != _sttLifecycleRevision) return false;
      }

      session = _createStreamSession(config);
      subscription = session.events.listen((event) {
        if (revision == _sttLifecycleRevision) {
          _onSttStreamEvent(event);
        }
      });
      _sttStream = session;
      _sttStreamSub = subscription;
      await session.start();
      if (revision != _sttLifecycleRevision) return false;
      streamingSttActive = true;
      _preferStreamStt = true;
      transcriptError =
          config.provider == SttProvider.apple &&
              config.mode == SttDisplayMode.translation &&
              !config.appleTranslationReady
          ? '请在设置中下载翻译语言，下次录音生效'
          : null;
      statusMessage = '正在转写';
      _snapshotLiveText();
      _flushPendingPcm();
      notifyListeners();
      return true;
    } catch (e) {
      if (revision != _sttLifecycleRevision) return false;
      debugPrint('[STT] ${config.provider.name} stream start failed: $e');
      streamingSttActive = false;
      _preferStreamStt = false;
      _pendingPcm.clear();
      transcriptError = config.provider == SttProvider.apple
          ? _speechErrorMessage(e)
          : '实时转写失败，可在录音保存后重试';
      _snapshotLiveText();
      if (identical(_sttStream, session)) _sttStream = null;
      if (identical(_sttStreamSub, subscription)) _sttStreamSub = null;
      await subscription?.cancel();
      await session?.close();
      await session?.dispose();
      notifyListeners();
      return false;
    } finally {
      if (revision == _sttLifecycleRevision) {
        _streamSttStarting = false;
      }
    }
  }

  SttStreamSession _createStreamSession(_SpeechConfiguration config) {
    if (config.provider == SttProvider.apple) {
      return _appleSpeech.createStreamSession(
        sourceLanguage: config.sourceLanguage,
        targetLanguage:
            config.mode == SttDisplayMode.translation &&
                config.appleTranslationReady
            ? config.targetLanguage
            : null,
      );
    }
    final communication = config.mode == SttDisplayMode.conversation;
    final translationConfig = switch (config.mode) {
      SttDisplayMode.transcription => const SonioxTranslationConfig.none(),
      SttDisplayMode.translation => SonioxTranslationConfig.oneWay(
        config.targetLanguage,
      ),
      SttDisplayMode.conversation => SonioxTranslationConfig.twoWay(
        config.ownerLanguage,
        config.guestLanguage,
      ),
    };
    return SonioxSttStreamSession(
      apiKey: config.sonioxKey!,
      sampleRate: 16000,
      languageHints: communication
          ? [config.ownerLanguage, config.guestLanguage]
          : (config.sourceLanguage == 'auto'
                ? const []
                : [config.sourceLanguage]),
      translation: translationConfig,
    );
  }

  void _flushPendingPcm() {
    final session = _sttStream;
    if (session == null || !session.isServerReady) return;
    if (_pendingPcm.isEmpty) return;
    final buf = _pendingPcm.toBytes();
    _pendingPcm.clear();
    session.sendPcm(buf);
  }

  void _onSttStreamEvent(SttStreamEvent e) {
    final translationSnapshotUpdated =
        (translationModeActive || communicationModeActive) &&
        (e.type == 'partial' || e.type == 'done');
    if (translationSnapshotUpdated) {
      if (translationModeActive) {
        translationTurns = e.translationTurns
            .where(
              (turn) => turn.targetLanguage == activeTranslationTargetLanguage,
            )
            .toList(growable: false);
        pendingTranslationSource = e.pendingTranslationSource;
      } else if (communicationModeActive) {
        ownerTranslationTurns = e.translationTurns
            .where((turn) => turn.targetLanguage == activeOwnerLanguage)
            .toList(growable: false);
        guestTranslationTurns = e.translationTurns
            .where((turn) => turn.targetLanguage == activeGuestLanguage)
            .toList(growable: false);
      }
    }
    switch (e.type) {
      case 'partial':
        if (e.text.isEmpty) {
          if (translationSnapshotUpdated) {
            transcribing = true;
            _snapshotLiveText();
            notifyListeners();
          }
          return;
        }
        final incoming = normalizeSttText(e.text);
        if (incoming.isEmpty) return;
        if (_activeConfiguration.provider == SttProvider.apple) {
          if (e.speechFinal) {
            transcript = incoming;
            transcriptPartial = null;
          } else {
            transcriptPartial = incoming;
          }
        } else if (e.speechFinal) {
          final prev = transcript.trim();
          // Cumulative drafts (Soniox) already include prior text.
          if (prev.isNotEmpty && incoming.startsWith(prev)) {
            transcript = incoming;
          } else {
            transcript = prev.isEmpty ? incoming : '$prev $incoming'.trim();
          }
          transcriptPartial = null;
        } else {
          final base = transcript.trim();
          if (base.isEmpty || incoming.startsWith(base)) {
            transcriptPartial = incoming;
          } else {
            transcriptPartial = '$base $incoming'.trim();
          }
        }
        transcribing = true;
        _snapshotLiveText();
        notifyListeners();
      case 'done':
        if (e.text.isNotEmpty) {
          transcript = normalizeSttText(e.text);
          transcriptPartial = null;
        }
        transcribing = false;
        streamingSttActive = false;
        statusMessage = '转写完成';
        _snapshotLiveText();
        notifyListeners();
      case 'error':
        transcriptError = _activeConfiguration.provider == SttProvider.apple
            ? _speechErrorMessage(
                PlatformException(code: e.error ?? 'processing_failed'),
              )
            : '实时转写中断，可在录音保存后重试';
        streamingSttActive = false;
        _preferStreamStt = false;
        _snapshotLiveText();
        notifyListeners();
      case 'translationError':
        transcriptError = '翻译失败，原文已保留；可在录音保存后重试';
        _snapshotLiveText();
        notifyListeners();
      case 'closed':
        streamingSttActive = false;
        transcribing = false;
        _snapshotLiveText();
        notifyListeners();
      default:
        break;
    }
  }

  @visibleForTesting
  void attachSttStreamForTesting(SttStreamSession session) {
    final revision = ++_sttLifecycleRevision;
    _sttStream = session;
    _sttStreamSub = session.events.listen((event) {
      if (revision == _sttLifecycleRevision) {
        _onSttStreamEvent(event);
      }
    });
    streamingSttActive = true;
  }

  @visibleForTesting
  void handleRealtimeOpusFrameForTesting(Uint8List frame) =>
      _onRealtimeOpusFrame(frame);

  @visibleForTesting
  void handleRealtimeStateForTesting(RealtimeStreamState state) =>
      _onRealtimeState(state);

  Future<void> _finishStreamStt({String? bindPath}) async {
    final session = _sttStream;
    final recordingSession = _currentRecording;
    if (session == null && _pendingPcm.isEmpty) {
      if (recordingSession != null) {
        recordingSession.finalizing = false;
        _snapshotLiveText();
        _saveLiveRecording(recordingSession, path: bindPath);
      }
      return;
    }
    if (recordingSession != null) recordingSession.finalizing = true;
    final revision = _sttLifecycleRevision;
    final subscription = _sttStreamSub;
    _sttStream = null;
    _sttStreamSub = null;
    streamingSttActive = false;
    try {
      if (session != null) {
        _flushPendingPcmTo(session);
        final done = await session.finish();
        if (revision != _sttLifecycleRevision) return;
        if (done != null && done.text.isNotEmpty) {
          // Prefer stitched session text when longer / complete.
          if (done.text.length >= transcript.length) {
            transcript = done.text;
          }
          transcriptPartial = null;
        }
      }
      if (revision != _sttLifecycleRevision) return;
      _snapshotLiveText();
      if (recordingSession != null) {
        _saveLiveRecording(recordingSession, path: bindPath);
      }
    } catch (e) {
      debugPrint('[STT] stream finish: $e');
      if (revision == _sttLifecycleRevision && recordingSession != null) {
        transcriptError = '部分处理未完成，可在录音详情中重试';
        _snapshotLiveText();
        _saveLiveRecording(recordingSession, path: bindPath);
      }
    } finally {
      await subscription?.cancel();
      await session?.dispose();
      if (recordingSession != null) recordingSession.finalizing = false;
      if (revision == _sttLifecycleRevision) {
        _pendingPcm.clear();
        transcribing = _fileJobKey != null;
        notifyListeners();
      }
    }
  }

  void _cancelStreamSttAfterPause() {
    _snapshotLiveText();
    final recordingSession = _currentRecording;
    if (recordingSession != null) {
      recordingSession.active = false;
      recordingSession.paused = true;
      recordingSession.finalizing = false;
      _saveLiveRecording(recordingSession);
    }
    final session = _sttStream;
    final subscription = _sttStreamSub;
    _sttLifecycleRevision++;
    _sttStream = null;
    _sttStreamSub = null;
    _streamSttStarting = false;
    _pendingPcm.clear();
    streamingSttActive = false;
    if (transcribingPath == null) transcribing = false;
    transcriptError = null;

    Future<void>? closeFuture;
    try {
      // Soniox marks the socket closed synchronously before its first await.
      closeFuture = session?.close();
    } catch (e) {
      debugPrint('[STT] pause close: $e');
    }
    unawaited(() async {
      try {
        await subscription?.cancel();
        await closeFuture;
        await session?.dispose();
      } catch (e) {
        debugPrint('[STT] pause dispose: $e');
      }
    }());
  }

  void _flushPendingPcmTo(SttStreamSession session) {
    if (_pendingPcm.isEmpty) return;
    final buf = _pendingPcm.toBytes();
    _pendingPcm.clear();
    session.sendPcm(buf);
  }

  void setAutoTranscribe(bool v) {
    autoTranscribe = v;
    if (!v) {
      sttMode = SttDisplayMode.transcription;
      if (!_liveProcessing) _resetTranslationTurns();
    }
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setAutoRealtime(bool v) {
    autoRealtime = v;
    if (!v && _autoTransferRunning) _blePull.cancel();
    notifyListeners();
    unawaited(_persistSettings());
    if (v && connected) {
      if (recording || info?.recording == true) {
        unawaited(_maybeStartAutoRealtime(reason: 'setting_enabled'));
      } else {
        unawaited(refreshFilesOnTabEnter());
      }
    }
  }

  /// Background stream finalization can outlive a recorder disconnect after a
  /// long take; it must not keep the live page open once the device is gone.
  bool get isLiveSession =>
      connected && (recording || realtimeState.active || streamingSttActive);

  bool get sonioxTranslationModeAvailable =>
      autoTranscribe &&
      (speechProvider == SttProvider.soniox ||
          (speechProvider == SttProvider.apple && appleTranslationAvailable));

  bool get translationModeActive =>
      _activeConfiguration.enabled &&
      _activeConfiguration.mode == SttDisplayMode.translation;

  bool get communicationModeActive =>
      _activeConfiguration.enabled &&
      _activeConfiguration.provider == SttProvider.soniox &&
      _activeConfiguration.mode == SttDisplayMode.conversation;

  bool get sonioxTranslationModeActive =>
      _activeConfiguration.provider == SttProvider.soniox &&
      (translationModeActive || communicationModeActive);

  String get _activeTranslationModeLabel =>
      translationModeActive ? '翻译模式' : '交流模式';

  bool get isCommunicationLiveSession =>
      communicationModeActive && isLiveSession;

  void setTranscriptLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    transcriptLanguage = normalized.isEmpty ? 'auto' : normalized;
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setSonioxApiKey(String? key) {
    final t = key?.trim();
    _sonioxStt.apiKeyOverride = (t == null || t.isEmpty) ? null : t;
    notifyListeners();
    unawaited(_persistSettings());
  }

  /// Saved / override keys for Settings text fields (not env-only secrets).
  String? get sonioxApiKeyStored => _sonioxStt.apiKeyOverride;

  bool get sttConfigured =>
      _settingsReady && _isConfigured(_settingsConfiguration);

  bool get sonioxConfigured => _sonioxStt.isConfigured;

  void clearTranscript() {
    transcript = '';
    transcriptPartial = null;
    transcriptError = null;
    _resetTranslationTurns();
    notifyListeners();
  }

  void setSttMode(SttDisplayMode mode) {
    if (speechProvider == SttProvider.moss &&
        mode != SttDisplayMode.transcription) {
      return;
    }
    if (mode != SttDisplayMode.transcription &&
        (!autoTranscribe ||
            (mode == SttDisplayMode.conversation &&
                !conversationModeAvailable) ||
            (mode == SttDisplayMode.translation &&
                !sonioxTranslationModeAvailable))) {
      return;
    }
    if (sttMode == mode) return;
    sttMode = mode;
    if (!_liveProcessing) {
      _preferStreamStt = true;
      transcriptError = null;
      _resetTranslationTurns();
    }
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setTranslationTargetLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) return;
    if (translationTargetLanguage == normalized) return;
    translationTargetLanguage = normalized;
    if (!_liveProcessing) _resetTranslationTurns();
    unawaited(refreshAppleCapabilities());
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setOwnerLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    if (!isSonioxLanguage(normalized) || normalized == guestLanguage) return;
    if (ownerLanguage == normalized) return;
    ownerLanguage = normalized;
    if (!_liveProcessing) _resetTranslationTurns();
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setGuestLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    if (!isSonioxLanguage(normalized) || normalized == ownerLanguage) return;
    if (guestLanguage == normalized) return;
    guestLanguage = normalized;
    if (!_liveProcessing) _resetTranslationTurns();
    notifyListeners();
    unawaited(_persistSettings());
  }

  void swapCommunicationLanguages() {
    final previousOwner = ownerLanguage;
    ownerLanguage = guestLanguage;
    guestLanguage = previousOwner;
    if (!_liveProcessing) _resetTranslationTurns();
    notifyListeners();
    unawaited(_persistSettings());
  }

  void _resetTranslationTurns() {
    translationTurns = const [];
    pendingTranslationSource = null;
    ownerTranslationTurns = const [];
    guestTranslationTurns = const [];
  }

  /// Fresh recording session: clear live draft and STT stream (keep per-file history).
  Future<void> _beginNewLiveTranscriptSession() async {
    final previous = _currentRecording;
    if (previous != null) {
      _snapshotLiveText();
      previous.active = false;
      if (previous.configuration.provider == SttProvider.moss) {
        previous.paused = false;
        previous.ended = true;
      }
      previous.finalizing = false;
      _saveLiveRecording(previous);
      if (previous.path != null &&
          !realtimeState.active &&
          !_finalizingRecordings.contains(_recordingKey(path: previous.path))) {
        unawaited(_enqueueMossRecording(previous, previous.path!));
      }
    }
    final config = _settingsConfiguration;
    _currentSessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${++liveSessionRevision}';
    _recordingSessions[_currentSessionId!] = _RecordingSession(
      _currentSessionId!,
      config,
    );
    _liveConfiguration = config;
    if (appleLanguagePreparationBusy) {
      _fileCancellation = _appleSpeech.cancelFileProcessing();
    }
    if (_fileJobKey != null && _fileJobProvider == SttProvider.apple) {
      _fileJobRevision++;
      if (_fileJobKey != null) {
        _recordingErrors[_fileJobKey!] = '处理因录音暂停，可在录音结束后重试';
      }
      _fileCancellation = _appleSpeech.cancelFileProcessing();
      _fileJobKey = null;
      _fileJobProvider = null;
      transcribingPath = null;
      fileTranscriptionProgress = null;
    }
    _sttLifecycleRevision++;
    transcript = '';
    transcriptPartial = null;
    transcriptError = null;
    transcribing = _fileJobKey != null;
    if (config.enabled && !_isConfigured(config)) {
      transcriptError = config.provider == SttProvider.apple
          ? '请在设置中选择并下载录音语言，下次录音生效'
          : '请在设置中配置 ${config.provider.label}，下次录音生效';
      _currentRecording?.error = transcriptError;
    }
    _resetTranslationTurns();
    _lastSttBytes = 0;
    _lastSttAt = DateTime.fromMillisecondsSinceEpoch(0);
    pcmFramesDecoded = 0;
    streamingSttActive = false;
    _streamSttStarting = false;
    _pendingPcm.clear();
    final session = _sttStream;
    final subscription = _sttStreamSub;
    _sttStream = null;
    _sttStreamSub = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    if (session != null) {
      try {
        // Close without waiting for done — avoid pasting previous session text.
        await session.close();
        await session.dispose();
      } catch (e) {
        debugPrint('[STT] reset session: $e');
      }
    }
    notifyListeners();
  }

  Future<SpeechResourceStatus> recordingSpeechStatus(
    String sourceLanguage,
  ) async {
    final capabilities = await _appleSpeech.capabilities(
      sourceLanguage: sourceLanguage,
    );
    return capabilities.speechStatus;
  }

  Future<void> transcribeRecording(
    RecordingReference ref, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  }) async {
    final view = recordingView(ref);
    if (view.path == null) {
      _recordingErrors[_referenceKey(ref)] = '请先下载录音';
      notifyListeners();
      return;
    }
    await transcribeLocalFile(
      view.path!,
      sourceLanguage:
          sourceLanguage ??
          (speechProvider == SttProvider.apple && view.sourceLanguage != 'auto'
              ? view.sourceLanguage
              : null),
      prepareLanguages: prepareLanguages,
    );
  }

  /// File jobs never write the current live transcript.
  Future<void> transcribeLocalFile(
    String path, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  }) async {
    await _settingsLoaded;
    if (_disposed) return;
    final settings = _settingsConfiguration;
    final config =
        settings.provider == SttProvider.apple && sourceLanguage != null
        ? settings.withSourceLanguage(sourceLanguage.trim())
        : settings;
    final key = _recordingKey(path: path);
    if (fileProcessingBusy ||
        _isRecordingAudioLocked(fileIdFromPath(path), path)) {
      _recordingErrors[key] = '请在当前录音或处理结束后重试';
      notifyListeners();
      return;
    }
    if (config.provider == SttProvider.apple
        ? config.sourceLanguage.isEmpty
        : !_isConfigured(config)) {
      _recordingErrors[key] = config.provider == SttProvider.apple
          ? '请选择录音语言'
          : '请在设置中配置 ${config.provider.label}';
      notifyListeners();
      return;
    }
    if (config.provider == SttProvider.moss) {
      _recordingErrors.remove(key);
      try {
        await _mossJobs.enqueue(key, path, key: config.mossKey, retry: true);
      } catch (_) {
        _recordingErrors[key] = '无法保存转写任务，请检查存储空间后重试';
      }
      notifyListeners();
      return;
    }
    final revision = ++_fileJobRevision;
    _fileJobKey = key;
    _fileJobProvider = config.provider;
    transcribingPath = path;
    transcribing = true;
    fileTranscriptionProgress = const SttFileProgress(SttFileStage.preparing);
    _recordingErrors.remove(key);
    notifyListeners();
    try {
      if (config.provider == SttProvider.apple) {
        final capabilities = await _appleSpeech.capabilities(
          sourceLanguage: config.sourceLanguage,
        );
        if (_disposed || revision != _fileJobRevision) return;
        if (!capabilities.supported) {
          throw PlatformException(code: 'unsupported');
        }
        if (capabilities.speechStatus == SpeechResourceStatus.unsupported) {
          throw PlatformException(code: 'language_unsupported');
        }
        if (capabilities.speechStatus == SpeechResourceStatus.needsDownload) {
          if (!prepareLanguages) {
            throw PlatformException(code: 'resources_missing');
          }
          await _appleSpeech.prepareLanguages(
            sourceLanguage: config.sourceLanguage,
          );
          if (_disposed || revision != _fileJobRevision) return;
        }
      }
      final result = await _transcribePath(
        path,
        configuration: config,
        isCurrent: () => !_disposed && revision == _fileJobRevision,
        onProgress: (progress) {
          if (_disposed || revision != _fileJobRevision) return;
          fileTranscriptionProgress = progress;
          notifyListeners();
        },
      );
      if (_disposed || revision != _fileJobRevision) return;
      if (result.text.trim().isEmpty) {
        _recordingErrors[key] = '未识别到语音，可重试';
      } else {
        final currentPath =
            recordingView(RecordingReference(path: path)).path ?? path;
        rememberTranscript(
          currentPath,
          result.text,
          provider: config.provider,
          sourceLanguage: config.provider == SttProvider.apple
              ? config.sourceLanguage
              : result.language ?? config.sourceLanguage,
        );
        statusMessage = '转写已保存';
        // Refresh a closed live route without retaining an obsolete error.
        final session = _sessionForReference(
          RecordingReference(path: currentPath),
        );
        if (session != null && !session.active) session.error = null;
      }
    } catch (error) {
      if (!_disposed && revision == _fileJobRevision) {
        _recordingErrors[key] =
            error is PlatformException && error.code == 'resources_missing'
            ? '请下载所选录音语言后重试'
            : _speechErrorMessage(error);
      }
    } finally {
      if (!_disposed && revision == _fileJobRevision) {
        _fileJobKey = null;
        _fileJobProvider = null;
        transcribingPath = null;
        fileTranscriptionProgress = null;
        transcribing = streamingSttActive;
        notifyListeners();
      }
    }
  }

  Future<void> prepareRecordingTranslation(
    RecordingReference ref, {
    required String sourceLanguage,
    required String targetLanguage,
  }) => translateRecording(
    ref,
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    prepareLanguages: true,
  );

  Future<void> translateRecording(
    RecordingReference ref, {
    String? sourceLanguage,
    String? targetLanguage,
    bool prepareLanguages = false,
  }) async {
    final view = recordingView(ref);
    final key = _referenceKey(ref);
    if (fileProcessingBusy || view.audioLocked) {
      _recordingErrors[key] = '请在当前录音或处理结束后重试';
      notifyListeners();
      return;
    }
    if (view.text.trim().isEmpty) return;
    final source =
        sourceLanguage ??
        (view.sourceLanguage == null || view.sourceLanguage == 'auto'
            ? appleSourceLanguage
            : view.sourceLanguage!);
    final target = targetLanguage ?? translationTargetLanguage;
    if (source.isEmpty) {
      _recordingErrors[key] = '请在设置中选择录音语言';
      notifyListeners();
      return;
    }
    final revision = ++_fileJobRevision;
    final sourceRevision = _transcriptMetadata[key]?.revision ?? 0;
    _fileJobKey = key;
    _fileJobProvider = SttProvider.apple;
    _recordingErrors.remove(key);
    fileTranscriptionProgress = const SttFileProgress(SttFileStage.processing);
    notifyListeners();
    try {
      if (prepareLanguages) {
        await _appleSpeech.prepareTranslation(
          sourceLanguage: source,
          targetLanguage: target,
        );
        if (_disposed || revision != _fileJobRevision) return;
      }
      final translated = await _appleSpeech.translate(
        view.text,
        sourceLanguage: source,
        targetLanguage: target,
      );
      if (_disposed ||
          revision != _fileJobRevision ||
          sourceRevision != (_transcriptMetadata[key]?.revision ?? 0) ||
          recordingView(ref).text != view.text) {
        return;
      }
      if (translated.trim().isEmpty) throw StateError('empty_translation');
      _transcriptMetadata.putIfAbsent(
        key,
        () => TranscriptMetadata(
          provider: view.provider,
          sourceLanguage: source,
          revision: sourceRevision,
        ),
      );
      _recordingTranslations[key] = RecordingTranslation(
        text: translated,
        sourceLanguage: source,
        targetLanguage: target,
        provider: SttProvider.apple,
        sourceRevision: sourceRevision,
      );
      _sessionForReference(ref)?.error = null;
      await _persistTranscripts();
    } catch (error) {
      if (!_disposed && revision == _fileJobRevision) {
        _recordingErrors[key] = _speechErrorMessage(error);
      }
    } finally {
      if (!_disposed && revision == _fileJobRevision) {
        _fileJobKey = null;
        _fileJobProvider = null;
        fileTranscriptionProgress = null;
        notifyListeners();
      }
    }
  }

  Future<SttResult> _transcribePath(
    String path, {
    _SpeechConfiguration? configuration,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    final config = configuration ?? _activeConfiguration;
    if (config.provider == SttProvider.apple) {
      final wavPath = await _convertExportToWav(path);
      if (isCurrent != null && !isCurrent()) {
        throw PlatformException(code: 'cancelled');
      }
      if (!wavPath.endsWith('.wav')) {
        throw PlatformException(code: 'audio_invalid');
      }
      return _appleSpeech.transcribePath(
        wavPath,
        sourceLanguage: config.sourceLanguage,
        onProgress: onProgress,
      );
    }
    return _sonioxStt.transcribePath(
      path,
      language: config.sourceLanguage == 'auto' ? null : config.sourceLanguage,
      onProgress: onProgress,
    );
  }

  Future<void> _maybeTranscribeRolling(
    String path,
    int bytes, {
    required bool finalPass,
  }) async {
    if (_activeConfiguration.provider != SttProvider.soniox ||
        !_activeSttConfigured ||
        !_activeAutoTranscribe) {
      return;
    }
    if (_recordWireStatus == 2) return;
    if (transcribing && !finalPass) return;
    final revision = _sttLifecycleRevision;
    final now = DateTime.now();
    final minBytes = finalPass ? 1600 : 24 * 1024; // ~2.5s vs ~3s of frames
    final minInterval = finalPass ? Duration.zero : const Duration(seconds: 8);
    if (bytes < minBytes) return;
    if (!finalPass) {
      if (bytes - _lastSttBytes < 16 * 1024) return;
      if (now.difference(_lastSttAt) < minInterval) return;
    }
    _lastSttAt = now;
    _lastSttBytes = bytes;
    transcribing = true;
    transcriptError = null;
    notifyListeners();
    try {
      final r = await _transcribePath(path);
      if (revision != _sttLifecycleRevision || _recordWireStatus == 2) return;
      if (r.text.isNotEmpty) {
        if (finalPass) {
          transcript = r.text;
          transcriptPartial = null;
          rememberTranscript(
            path,
            r.text,
            provider: SttProvider.soniox,
            sourceLanguage: _activeConfiguration.sourceLanguage,
          );
        } else {
          // Keep growing draft; prefer longer / newer full-file STT.
          transcriptPartial = r.text;
          if (r.text.length >= transcript.length) {
            transcript = r.text;
          }
          rememberTranscript(
            path,
            r.text,
            provider: SttProvider.soniox,
            sourceLanguage: _activeConfiguration.sourceLanguage,
          );
        }
      }
      _snapshotLiveText();
    } catch (e) {
      if (revision != _sttLifecycleRevision || _recordWireStatus == 2) return;
      // Soft-fail during rolling; surface message.
      transcriptError = _speechErrorMessage(e);
      debugPrint('[STT] rolling failed: $e');
    } finally {
      if (revision == _sttLifecycleRevision) {
        transcribing = false;
        notifyListeners();
      }
    }
  }

  DateTime _lastPositionNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _wirePlayer() {
    _subs.add(
      _player.playerStateStream.listen((s) {
        isPlaying = s.playing;
        // Clear sticky "正在播放" header once audio is no longer playing.
        if (!s.playing) {
          _clearPlayingStatus();
        }
        notifyListeners();
      }),
    );
    // Throttle position UI updates (~8 Hz) to avoid rebuilding the whole tree.
    _subs.add(
      _player.positionStream.listen((pos) {
        position = pos;
        final now = DateTime.now();
        if (now.difference(_lastPositionNotify) >=
            const Duration(milliseconds: 120)) {
          _lastPositionNotify = now;
          notifyListeners();
        }
      }),
    );
    _subs.add(
      _player.durationStream.listen((d) {
        duration = d ?? Duration.zero;
        notifyListeners();
      }),
    );
    _subs.add(
      _player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) {
          isPlaying = false;
          // Leave file loaded so user can scrub / replay from start.
          position = Duration.zero;
          _clearPlayingStatus();
          unawaited(_player.seek(Duration.zero));
          unawaited(_player.pause());
          notifyListeners();
        }
      }),
    );
  }

  /// Drop playback-only status so Home header does not stick on "正在播放".
  void _clearPlayingStatus() {
    final m = statusMessage;
    if (m == null) return;
    if (m.startsWith('正在播放') || m.startsWith('正在准备播放')) {
      statusMessage = null;
    }
  }

  final BleService _ble;
  final PersistedDeviceLoader _persistedDeviceLoader;
  final Duration recordingShortcutScanTimeout;
  late final Future<void> _settingsLoaded;
  bool _settingsReady = false;
  late final Future<void> _persistedDeviceLoaded;
  final DeviceCrypto _crypto = DeviceCrypto();
  late final WifiExportService _wifi;
  late final RealtimeBleStream _realtime;
  late final BleFilePull _blePull;
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  /// Auto BLE realtime transfer while device is recording (no SoftAP).
  bool autoRealtime = true;
  bool _autoTransferRunning = false;
  bool get autoTransferActive => _autoTransferRunning;
  bool get blocksRecordingControl =>
      phase == AppPhase.busy && !_autoTransferRunning;
  RealtimeStreamState realtimeState = const RealtimeStreamState();

  /// Near-realtime AI transcription (PCM WS stream + Ogg batch fallback).
  bool autoTranscribe = true;

  String transcriptLanguage = 'auto';
  SttDisplayMode sttMode = SttDisplayMode.transcription;
  String translationTargetLanguage = 'zh';
  String ownerLanguage = 'zh';
  String guestLanguage = 'en';
  List<SttTranslationTurn> translationTurns = const [];
  SttSourceChunk? pendingTranslationSource;
  List<SttTranslationTurn> ownerTranslationTurns = const [];
  List<SttTranslationTurn> guestTranslationTurns = const [];
  String transcript = '';
  String? transcriptPartial;
  bool transcribing = false;
  String? transcribingPath;
  SttFileProgress? fileTranscriptionProgress;
  String? transcriptError;

  /// Live streaming STT session active after Opus→PCM decode.
  bool streamingSttActive = false;

  /// Decoded Opus frames in the current session (diagnostics).
  int pcmFramesDecoded = 0;
  final SonioxSttService _sonioxStt;
  final MossSttService _mossStt;
  late final MossJobQueue _mossJobs;
  final AppleSpeechService _appleSpeech;
  SttProvider speechProvider = SttProvider.soniox;
  String appleSourceLanguage = '';
  AppleSpeechCapabilities appleCapabilities =
      const AppleSpeechCapabilities.unsupported();
  bool appleCapabilitiesLoading = false;
  bool appleLanguagePreparationBusy = false;
  String? appleSetupError;
  int _capabilityRevision = 0;
  bool _disposed = false;
  int liveSessionRevision = 0;
  String? _currentSessionId;
  final Map<String, _RecordingSession> _recordingSessions = {};
  _SpeechConfiguration? _liveConfiguration;
  final Map<String, TranscriptMetadata> _transcriptMetadata = {};
  final Map<String, RecordingTranslation> _recordingTranslations = {};
  final Map<String, String> _recordingErrors = {};
  final Set<String> _finalizingRecordings = {};
  int _fileJobRevision = 0;
  String? _fileJobKey;
  SttProvider? _fileJobProvider;
  Future<void> _fileCancellation = Future<void>.value();
  final OpusPcmDecoder _opusPcm = OpusPcmDecoder(outputSampleRate: 16000);
  SttStreamSession? _sttStream;
  StreamSubscription? _sttStreamSub;
  bool _streamSttStarting = false;
  int _sttLifecycleRevision = 0;

  /// When false, use rolling Ogg batch STT (stream failed or Opus unavailable).
  bool _preferStreamStt = true;
  final BytesBuilder _pendingPcm = BytesBuilder(copy: false);
  DateTime _lastSttAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSttBytes = 0;

  Completer<bool>? _encryptCompleter;
  AppPhase phase = AppPhase.idle;
  bool connected = false;
  List<ScannedDevice> devices = [];
  DeviceInfoModel? info;
  List<OfflineFileEntry> files = [];
  List<String> logs = [];
  String? statusMessage;
  String? errorMessage;
  bool recording = false;
  bool bound = false;
  ScannedDevice? activeDevice;

  /// Incremented for each shortcut invocation so AppShell can select Home.
  int shortcutNavigationRevision = 0;
  bool _recordingShortcutPending = false;
  bool _recordingShortcutConnecting = false;
  bool _recordingShortcutStarting = false;
  Timer? _recordingShortcutTimer;
  Timer? _scanTimeoutTimer;
  Timer? _boundReconnectTimer;
  int _boundReconnectAttempt = 0;
  bool get recordingShortcutPending => _recordingShortcutPending;

  /// Set right before a user-initiated disconnect() so the connection-state
  /// listener doesn't immediately try to auto-reconnect a bound device.
  bool _explicitDisconnect = false;

  /// Survives disconnect so the Device tab can still show a known/bound unit.
  ScannedDevice? lastKnownDevice;
  DeviceInfoModel? lastKnownInfo;

  /// Multi-select for batch export.
  bool selecting = false;
  final Set<int> selectedFileIds = {};

  /// ECDH session established (needed to decrypt exports).
  bool encryptReady = false;

  /// Local exported paths (standard WAV when decryption succeeds).
  List<String> exportedPaths = [];
  final Map<String, Future<String>> _wavConversions = {};
  bool _catalogConversionRunning = false;
  final Map<String, Duration> _localDurations = {};
  final Set<String> _durationLoads = {};

  /// fileId → local path after Wi‑Fi export.
  final Map<int, String> localPathsByFileId = {};

  /// Device file currently being downloaded on demand over BLE.
  int? downloadingFileId;

  /// path → last STT text for that local export.
  final Map<String, String> transcriptsByPath = {};

  /// fileId → STT text (device list + local).
  final Map<int, String> transcriptsByFileId = {};

  /// Local recording path → provider speaker id → custom display name.
  final Map<String, Map<String, String>> speakerAliasesByPath = {};

  /// Device file id → provider speaker id → custom display name.
  final Map<int, Map<String, String>> speakerAliasesByFileId = {};
  Future<void> _transcriptsLoaded = Future<void>.value();

  /// Legacy expand id (device list no longer expands for playback).
  int? expandedFileId;

  String? playingPath;

  /// File id of the currently loaded local track (if parseable from path).
  int? playingFileId;
  bool isPlaying = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double playbackSpeed = 1.0;

  /// Available playback rates for the speed dropdown.
  static const List<double> playbackSpeeds = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  bool get hasLoadedTrack => playingPath != null;

  String get playingTitle {
    final path = playingPath;
    if (path == null) return '';
    return path.split('/').last;
  }

  double get playbackProgress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  ExportProgress exportProgress = ExportProgress();
  bool get isExporting =>
      exportProgress.phase != ExportPhase.idle &&
      exportProgress.phase != ExportPhase.done &&
      exportProgress.phase != ExportPhase.error &&
      exportProgress.phase != ExportPhase.awaitJoin;

  /// SoftAP open succeeded; waiting for user to join network.
  bool get needsWifiJoin => exportProgress.phase == ExportPhase.awaitJoin;

  /// Any active Wi‑Fi export session (opening SoftAP → transfer → closing).
  /// Used to avoid yanking the user back to Scan when BLE drops mid-export.
  bool get isWifiExportSession {
    final p = exportProgress.phase;
    return p == ExportPhase.openingSoftAp ||
        p == ExportPhase.awaitJoin ||
        p == ExportPhase.connectingWs ||
        p == ExportPhase.transferring ||
        p == ExportPhase.closing;
  }

  /// Check whether a local interface joined the device's SoftAP subnet.
  /// This intentionally does not touch the device's WebSocket port.
  Future<bool> isOnSoftApNetwork() async {
    final ep = exportProgress.endpoint;
    if (ep == null) return false;
    return WifiExportService.isOnSoftApNetwork(ep);
  }

  int get adsSeen => _ble.adsSeen;

  void toggleSelecting() {
    selecting = !selecting;
    if (!selecting) selectedFileIds.clear();
    notifyListeners();
  }

  void toggleFileSelected(int fileId) {
    if (_isRecordingAudioLocked(fileId, localPathFor(fileId))) return;
    if (selectedFileIds.contains(fileId)) {
      selectedFileIds.remove(fileId);
    } else {
      selectedFileIds.add(fileId);
    }
    notifyListeners();
  }

  void selectAllFiles() {
    selectedFileIds
      ..clear()
      ..addAll(
        files
            .where(
              (f) => !_isRecordingAudioLocked(f.fileId, localPathFor(f.fileId)),
            )
            .map((f) => f.fileId),
      );
    selecting = true;
    notifyListeners();
  }

  void clearSelection() {
    selectedFileIds.clear();
    notifyListeners();
  }

  /// Select a single file and enter selection mode (for one-tap export).
  void selectOnly(int fileId) {
    if (_isRecordingAudioLocked(fileId, localPathFor(fileId))) return;
    selecting = true;
    selectedFileIds
      ..clear()
      ..add(fileId);
    notifyListeners();
  }

  List<OfflineFileEntry> get selectedFiles =>
      files.where((f) => selectedFileIds.contains(f.fileId)).toList();

  List<OfflineFileEntry> get unexportedFiles =>
      files.where((f) => localPathFor(f.fileId) == null).toList();

  List<OfflineFileEntry> get selectedUnexportedFiles =>
      selectedFiles.where((f) => localPathFor(f.fileId) == null).toList();

  Future<void> startScan() async {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _scanTimeoutTimer?.cancel();
    errorMessage = null;
    phase = AppPhase.scanning;
    statusMessage = '正在检查蓝牙…';
    notifyListeners();
    try {
      final saved = bound ? lastKnownDevice : null;
      if (saved != null && await _ble.isD3200ConnectedToSystem(saved.id)) {
        statusMessage = '正在恢复 ${saved.displayName} 的连接…';
        notifyListeners();
        await connect(saved);
        if (connected) return;

        // The restored link went stale while being adopted. Fall back to a
        // normal scan without leaving the failed direct-connect error visible.
        errorMessage = null;
        phase = AppPhase.scanning;
        statusMessage = '正在检查蓝牙…';
        notifyListeners();
      }
      await _ble.startScan(timeout: _bleScanTimeout);
      statusMessage = '正在扫描 soundcore Work（D3200）…';
      notifyListeners();
      if (!connected && phase == AppPhase.scanning) {
        // FlutterBluePlus stops its native scan when the timeout elapses, but
        // startScan() returns as soon as scanning begins. Mirror that timeout
        // in controller state so the UI cannot remain stuck on a dead scan.
        _scanTimeoutTimer = Timer(_bleScanTimeout, () {
          if (!connected && phase == AppPhase.scanning) {
            unawaited(_finishTimedOutScan());
          }
        });
      }
    } catch (e) {
      _scanTimeoutTimer?.cancel();
      errorMessage = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError):\s*'),
        '',
      );
      phase = AppPhase.idle;
      statusMessage = null;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _scanTimeoutTimer?.cancel();
    await _ble.stopScan();
    if (!connected) phase = AppPhase.idle;
    statusMessage = devices.isEmpty && adsSeen > 0
        ? '已见 $adsSeen 条 BLE 广播，无匹配 D3200 — 请重启录音豆后重试'
        : null;
    notifyListeners();
  }

  Future<void> _finishTimedOutScan() async {
    await stopScan();
    _scheduleBoundReconnect();
  }

  bool get _canRetryBoundConnection =>
      bound &&
      lastKnownDevice != null &&
      !connected &&
      phase == AppPhase.idle &&
      !_ble.isConnecting &&
      !isWifiExportSession &&
      !isExporting &&
      !needsWifiJoin;

  void _scheduleBoundReconnect() {
    if (!_canRetryBoundConnection || _boundReconnectTimer != null) return;
    final index = _boundReconnectAttempt < _boundReconnectDelays.length
        ? _boundReconnectAttempt
        : _boundReconnectDelays.length - 1;
    final delay = _boundReconnectDelays[index];
    _boundReconnectAttempt++;
    statusMessage = '未找到已绑定设备，${delay.inSeconds} 秒后自动重试…';
    notifyListeners();
    _boundReconnectTimer = Timer(delay, () {
      _boundReconnectTimer = null;
      if (_canRetryBoundConnection) {
        unawaited(startScan());
      }
    });
  }

  void _resetBoundReconnectBackoff() {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _boundReconnectAttempt = 0;
  }

  Future<void> connect(ScannedDevice d) async {
    // Single-flight: ignore extra taps while connecting (or BLE layer busy).
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      statusMessage = '正在连接…';
      notifyListeners();
      return;
    }

    if (_recordingShortcutPending) {
      _recordingShortcutConnecting = true;
      _recordingShortcutTimer?.cancel();
      _recordingShortcutTimer = null;
    }

    _scanTimeoutTimer?.cancel();
    errorMessage = null;
    activeDevice = d;
    phase = AppPhase.connecting;
    statusMessage = '正在连接 ${d.displayName}…';
    connected = false;
    notifyListeners();
    // Start while the activity is visible. Android 12+ restricts launching a
    // foreground service after the app has already entered the background.
    await BackgroundSyncService.start();
    bool? shortcutResult;
    String? shortcutFailure;
    try {
      await _ble.connect(d.id, serviceUuidHint: d.serviceUuid);
      // Retry after GATT is ready in case Android initially rejected the
      // connected-device service before Bluetooth permission settled.
      await BackgroundSyncService.start();
      connected = true;
      phase = AppPhase.ready;
      statusMessage = '已连接';
      lastKnownDevice = d;
      // D3200 treats the first successful GATT connection as ownership: after
      // connecting it stops discoverable advertising to other hosts even when
      // no separate bind command was sent. Persist that observed device state
      // so only this exact recorder is eligible for automatic reconnection.
      bound = true;
      unawaited(_persistDevice());
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await refreshInfo();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await syncTime();
      // ECDH encrypt handshake so file exports can be decrypted.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await establishEncryptSession();
      shortcutResult = await _runPendingRecordingShortcutIfReady();
      if (shortcutResult == false) shortcutFailure = errorMessage;
      _startBatteryPoll();
      // Home may already be visible before an iOS connection completes, so its
      // initial tab refresh has already returned while disconnected. Always
      // request the device inventory once the GATT session is fully ready.
      await listFiles();
      // If the bean is already recording, start BLE realtime pull automatically.
      if (recording || info?.recording == true) {
        await _maybeStartAutoRealtime(reason: 'connected');
      }
      if (shortcutResult == false) {
        statusMessage = '快捷录音未开始';
        errorMessage = shortcutFailure ?? '无法开始录音';
        notifyListeners();
      } else if (shortcutResult == true && recording) {
        statusMessage = '录音中';
        notifyListeners();
      }
    } catch (e) {
      // Prefer cleaned message from BleService / strip noisy prefixes.
      final connectionError = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError|TimeoutException):\s*'),
        '',
      );
      errorMessage = connectionError;
      phase = AppPhase.idle;
      statusMessage = null;
      // Keep lastKnownDevice if we had one from a prior session.
      activeDevice = lastKnownDevice;
      connected = false;
      if (!_ble.isConnected) {
        await BackgroundSyncService.stop();
      }
      _scheduleBoundReconnect();
      if (_recordingShortcutPending) {
        _failRecordingShortcut(connectionError);
      } else {
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() async {
    _explicitDisconnect = true;
    _resetBoundReconnectBackoff();
    _scanTimeoutTimer?.cancel();
    _postBindFileRefreshTimer?.cancel();
    _stopBatteryPoll();
    await _wifi.cancel();
    await stopPlayback();
    if (info != null) lastKnownInfo = info;
    if (activeDevice != null) lastKnownDevice = activeDevice;
    await _ble.disconnect();
    // Keep lastKnownDevice / bound for offline Device tab; clear live session only.
    activeDevice = lastKnownDevice;
    info = null;
    files = [];
    selectedFileIds.clear();
    selecting = false;
    recording = false;
    _snapshotLiveText();
    _currentRecording?.active = false;
    _recordWireStatus = 0;
    encryptReady = false;
    _crypto.resetSession();
    phase = AppPhase.idle;
    statusMessage = null;
    connected = false;
    await BackgroundSyncService.stop();
    unawaited(_persistDevice());
    notifyListeners();
  }

  /// Display name for Device tab (live or last known).
  String get displayDeviceName =>
      activeDevice?.displayName ?? lastKnownDevice?.displayName ?? '设备';

  /// Snapshot used when offline.
  ScannedDevice? get displayDevice => activeDevice ?? lastKnownDevice;

  /// BLE `0x2E/0x01` ECDH handshake (Feishu `notifyEncryptFileData`).
  Future<bool> establishEncryptSession({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!_ble.isConnected) return false;
    if (encryptReady && _crypto.hasSession) return true;

    final mac =
        activeDevice?.macAddress ??
        info?.boxMac ??
        activeDevice?.id ??
        'unknown';
    statusMessage = '正在准备设备…';
    phase = AppPhase.busy;
    notifyListeners();

    _encryptCompleter = Completer<bool>();
    try {
      final pub = _crypto.ensureKeyPair();
      // Feishu stores MAC on EncryptMessageDispatch for session storage key.
      logs = [
        'ENCRYPT TX pub ${pub.length}B mac=$mac',
        ...logs,
      ].take(80).toList();
      await _ble.writeCommand(DeviceCommands.notifyEncryptPublicKey(pub));
      final ok = await _encryptCompleter!.future.timeout(timeout);
      encryptReady = ok;
      statusMessage = ok ? '设备已就绪' : '设备准备失败，请重新连接';
      phase = AppPhase.ready;
      notifyListeners();
      return ok;
    } on TimeoutException {
      encryptReady = false;
      errorMessage = '设备准备超时，请重新连接';
      statusMessage = '设备准备超时，请重新连接';
      phase = AppPhase.ready;
      notifyListeners();
      return false;
    } catch (e) {
      encryptReady = false;
      errorMessage = e.toString();
      phase = AppPhase.ready;
      notifyListeners();
      return false;
    } finally {
      _encryptCompleter = null;
    }
  }

  Future<bool> _sendChecked(List<int> frame, {String? label}) async {
    if (!_ble.isConnected) {
      errorMessage = '未连接';
      notifyListeners();
      return false;
    }
    phase = AppPhase.busy;
    if (label != null) statusMessage = label;
    notifyListeners();
    try {
      await _ble.writeCommand(frame);
      // A command just went through — any earlier error (e.g. a stale
      // "未连接" from a command that raced a disconnect) is no longer true.
      errorMessage = null;
      return true;
    } catch (e) {
      errorMessage = e.toString();
      return false;
    } finally {
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
  }

  Future<void> _send(List<int> frame, {String? label}) async {
    await _sendChecked(frame, label: label);
  }

  Future<void> refreshInfo({bool silent = false}) =>
      _send(DeviceCommands.getDeviceInfo(), label: silent ? null : '正在获取设备信息…');

  Timer? _batteryPollTimer;

  /// Poll device info while connected so mic/case battery stay fresh.
  /// Live 0x01/0x03 pushes are also handled, but many firmwares only update on query.
  void _startBatteryPoll() {
    _batteryPollTimer?.cancel();
    if (!connected) return;
    _batteryPollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!connected || !_ble.isConnected) return;
      if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
      if (isWifiExportSession || isExporting) return;
      unawaited(refreshInfo(silent: true));
    });
  }

  void _stopBatteryPoll() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = null;
  }

  /// Called when Device tab is shown — force a fresh battery snapshot.
  Future<void> refreshInfoOnDeviceTabEnter() async {
    if (!connected || !_ble.isConnected) return;
    if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
    if (isWifiExportSession || isExporting) return;
    await refreshInfo(silent: true);
  }

  Future<void> syncTime() => _send(DeviceCommands.syncTime(), label: '正在同步时钟…');

  Future<void> startRecord() async {
    await _startRecordChecked();
  }

  Future<bool> _startRecordChecked() async {
    await _settingsLoaded;
    if (_disposed) return false;
    await _yieldBacklogToCurrentRecording();
    final sent = await _sendChecked(
      DeviceCommands.startRecord(),
      label: '正在开始录音…',
    );
    if (!sent) return false;
    // Optimistic; device will confirm via 0x18/0x82 or 1A06.
    _applyRecordStatus(1, source: 'app_start');
    return true;
  }

  Future<void> pauseRecord() async {
    final sent = await _sendChecked(
      DeviceCommands.pauseRecord(),
      label: '正在暂停录音…',
    );
    if (!sent) return;
    // Optimistic; device will confirm via 0x18/0x82 status 0/2.
    _applyRecordStatus(2, source: 'app_pause');
  }

  /// Feishu `onAudioStatusChanged` / device-info recording bit:
  /// status `0` stop, `1` recording, `2` pause.
  /// Last wire status: 0=stop, 1=recording, 2=pause (for resume vs new take).
  int _recordWireStatus = 0;

  void _applyRecordStatus(
    int status, {
    int? fileId,
    int? durationSec,
    String source = '',
  }) {
    if (!_settingsReady) {
      unawaited(
        _settingsLoaded.then((_) {
          if (!_disposed) {
            _applyRecordStatus(
              status,
              fileId: fileId,
              durationSec: durationSec,
              source: source,
            );
          }
        }),
      );
      return;
    }
    final wasRecording = recording;
    final prevWire = _recordWireStatus;
    final active = status == 1;
    final retargetFile = active && fileId != null && fileId > 0;
    // Skip no-ops; still apply when a new live file id must retarget realtime.
    if (recording == active && !retargetFile && status == prevWire) {
      return;
    }
    recording = active;
    _recordWireStatus = status;
    // Keep DeviceInfoModel bit aligned so later device-info packets don't re-stick UI.
    if (info != null && info!.recording != active) {
      info = info!.copyWith(recording: active);
      lastKnownInfo = info;
    }

    if (active) {
      // New take after a full stop (not pause→resume): wipe live draft UI.
      final mossResume =
          prevWire == 2 &&
          _currentRecording?.configuration.provider == SttProvider.moss &&
          (fileId == null ||
              _currentRecording?.fileId == null ||
              _currentRecording?.fileId == fileId);
      final mossNewFile =
          _currentRecording?.configuration.provider == SttProvider.moss &&
          fileId != null &&
          _currentRecording?.fileId != null &&
          _currentRecording?.fileId != fileId;
      if (prevWire == 0 ||
          mossNewFile ||
          (source == 'app_start' && !mossResume)) {
        unawaited(_beginNewLiveTranscriptSession());
      }
      _bindCurrentRecording(fileId: fileId);
      _currentRecording?.active = true;
      _currentRecording?.paused = false;
      // New take: re-enable PCM stream STT (may have fallen back last session).
      _preferStreamStt = true;
      pcmFramesDecoded = 0;
      statusMessage = fileId != null && fileId > 0 ? '录音中 · 文件 $fileId' : '录音中';
      // The current recording always streams live over BLE — transcription
      // depends on it. `autoRealtime` ("自动传输") only gates catching up on
      // already-finished, un-exported recordings (see _autoTransferMissingFiles).
      if (!isWifiExportSession) {
        if (fileId != null && fileId > 0) {
          unawaited(_startCurrentRecordingTransfer(fileId));
        } else {
          unawaited(
            _maybeStartAutoRealtime(
              reason: source.isEmpty ? 'record_status' : source,
            ),
          );
        }
      }
    } else {
      _snapshotLiveText();
      _currentRecording?.active = false;
      _currentRecording?.paused = status == 2;
      if (status == 0) _currentRecording?.ended = true;
      _currentRecording?.finalizing =
          status == 0 && (realtimeState.active || _sttStream != null);
      final label = status == 2 ? '已暂停' : '已停止录音';
      if (durationSec != null && durationSec > 0) {
        statusMessage = '$label（${durationSec}s）';
      } else {
        statusMessage = label;
      }
      if (wasRecording || realtimeState.active) {
        _realtime.onRecordingStopped();
      }
      if (status == 2) {
        // Pause is a hard boundary: disconnect Soniox immediately and reject
        // queued callbacks or a batch fallback from the paused take.
        _cancelStreamSttAfterPause();
      } else {
        // A full stop may finish gracefully while realtime audio settles.
        try {
          _sttStream?.finalizeUtterance();
        } catch (_) {}
      }
      if (status == 0 && !realtimeState.active) {
        final owner = _currentRecording;
        if (owner?.path != null) {
          unawaited(_enqueueMossRecording(owner!, owner.path!));
        }
      }
      // Refresh inventory after hardware/app stop so Files tab shows the clip.
      if (status == 0 && connected) {
        unawaited(listFiles());
      }
    }
    debugPrint(
      '[Record] status=$status active=$active src=$source '
      'fileId=$fileId was=$wasRecording',
    );
    notifyListeners();
  }

  /// Resolve current recording file id and start BLE realtime stream.
  /// Not gated by `autoRealtime` — the current recording always streams live
  /// so transcription keeps working regardless of the backlog-transfer setting.
  Future<void> _maybeStartAutoRealtime({required String reason}) async {
    if (!connected || !_ble.isConnected) return;
    if (isWifiExportSession) return;
    final recordingNow = recording || info?.recording == true;
    if (recordingNow) await _yieldBacklogToCurrentRecording();

    if (!encryptReady) {
      await establishEncryptSession();
    }

    // Prefer list-with-end-time: includes currentTransportTimestamp.
    try {
      await _ble.writeCommand(DeviceCommands.listFilesWithEndTime());
    } catch (_) {
      try {
        await _ble.writeCommand(DeviceCommands.listFiles());
      } catch (e) {
        debugPrint('[Realtime] listFiles failed: $e');
      }
    }
    // Packet handler will call _kickRealtimeFromFileList when list arrives.
    statusMessage = recordingNow ? '实时传输：等待当前录音文件…' : '正在检查未导出录音…';
    notifyListeners();
    debugPrint('[Realtime] arm auto stream ($reason)');
  }

  void _kickRealtimeFromFileList(OfflineFileList list) {
    if (!connected) return;
    if (isWifiExportSession) return;
    if (!recording && info?.recording != true) return;

    final curr = list.currentTransportTimestamp;
    int? fileId;
    if (curr != null && curr > 0) {
      fileId = curr;
    } else if (recording || info?.recording == true) {
      // Fall back to newest offline entry (often the live file once listed).
      if (list.files.isNotEmpty) {
        fileId = list.files.first.fileId; // already sorted newest-first
      }
    }

    if (fileId == null || fileId <= 0) {
      if (recording || info?.recording == true) {
        statusMessage = '等待录音开始…';
        notifyListeners();
      }
      return;
    }

    if (realtimeState.active && realtimeState.fileId == fileId) return;

    unawaited(() async {
      try {
        await _startCurrentRecordingTransfer(fileId!);
        statusMessage = '正在接收录音…';
        notifyListeners();
      } catch (e) {
        errorMessage = '无法接收录音，请重新连接设备';
        notifyListeners();
      }
    }());
  }

  Future<void> _startCurrentRecordingTransfer(int fileId) async {
    _bindCurrentRecording(fileId: fileId);
    await _yieldBacklogToCurrentRecording();
    if (!connected || !_ble.isConnected) return;
    if (!recording && info?.recording != true) return;
    await _realtime.startForFile(fileId);
  }

  Future<void> _yieldBacklogToCurrentRecording() async {
    if (!_autoTransferRunning) return;
    _blePull.cancel();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (_autoTransferRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  var _fileListPage = 0;
  var _loadingFileListPages = false;
  final List<OfflineFileEntry> _fileListPages = [];
  Timer? _fileListPageTimeout;
  Completer<void>? _fileRefreshDone;
  Timer? _fileRefreshTimeout;

  Future<void> refreshLocalFiles() async {
    if (_liveProcessing ||
        isExporting ||
        needsWifiJoin ||
        _catalogConversionRunning) {
      return;
    }
    await _loadLocalExports();
  }

  /// Pull-to-refresh remains active until the device inventory has arrived.
  Future<void> refreshDeviceFiles() {
    final pending = _fileRefreshDone;
    if (pending != null) return pending.future;
    if (!connected ||
        isExporting ||
        needsWifiJoin ||
        downloadingFileId != null ||
        phase == AppPhase.busy ||
        phase == AppPhase.connecting) {
      return Future<void>.value();
    }
    final done = _fileRefreshDone = Completer<void>();
    _fileRefreshTimeout = Timer(const Duration(seconds: 20), () {
      _loadingFileListPages = false;
      _fileListPageTimeout?.cancel();
      errorMessage = '刷新超时，请下拉重试';
      _completeFileRefresh();
      notifyListeners();
    });
    unawaited(() async {
      try {
        if (!_loadingFileListPages) await listFiles();
        if (!identical(_fileRefreshDone, done)) return;
        if (!connected || errorMessage != null) {
          _loadingFileListPages = false;
          _completeFileRefresh();
        }
      } catch (_) {
        if (!identical(_fileRefreshDone, done)) return;
        errorMessage = '刷新失败，请下拉重试';
        _loadingFileListPages = false;
        _completeFileRefresh();
        notifyListeners();
      }
    }());
    return done.future;
  }

  void _completeFileRefresh() {
    _fileRefreshTimeout?.cancel();
    _fileRefreshTimeout = null;
    final done = _fileRefreshDone;
    _fileRefreshDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> listFiles() {
    _fileListPageTimeout?.cancel();
    _fileListPage = 0;
    _fileListPages.clear();
    _loadingFileListPages = true;
    // The D3200 SDK's public getAllAudioRecordFiles() uses 1B/0E and fetches
    // subsequent pages whenever a response contains the full 10 entries.
    return _send(
      DeviceCommands.listFilesWithEndTime(page: _fileListPage),
      label: '正在获取录音列表…',
    );
  }

  void _handleFileListPage(OfflineFileList list) {
    _fileListPageTimeout?.cancel();
    if (!_loadingFileListPages) {
      files = _sortFilesNewestFirst(list.files);
      statusMessage = '${files.length} 条录音';
      _kickRealtimeFromFileList(list);
      _scheduleAutoTransferMissing();
      return;
    }

    final byId = <int, OfflineFileEntry>{
      for (final file in _fileListPages) file.fileId: file,
      for (final file in list.files) file.fileId: file,
    };
    _fileListPages
      ..clear()
      ..addAll(byId.values);
    files = _sortFilesNewestFirst(_fileListPages);

    if (list.fileCount == 10) {
      _fileListPage++;
      final requestedPage = _fileListPage;
      statusMessage = '正在获取录音列表…（${files.length} 条）';
      notifyListeners();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 50), () async {
          if (!connected || !_loadingFileListPages) return;
          try {
            await _ble.writeCommand(
              DeviceCommands.listFilesWithEndTime(page: _fileListPage),
            );
            // The device may silently never answer this page (BLE hiccup,
            // busy firmware) — without a timeout _loadingFileListPages would
            // stay stuck true and this partial list would never finalize.
            _fileListPageTimeout = Timer(const Duration(seconds: 8), () {
              if (!_loadingFileListPages || _fileListPage != requestedPage) {
                return;
              }
              _loadingFileListPages = false;
              statusMessage =
                  '${files.length} 条录音（第 ${requestedPage + 1} 页无响应）';
              _completeFileRefresh();
              notifyListeners();
            });
          } catch (error) {
            _loadingFileListPages = false;
            errorMessage = '无法获取全部录音，请刷新重试';
            _completeFileRefresh();
            notifyListeners();
          }
        }),
      );
      return;
    }

    _loadingFileListPages = false;
    statusMessage = '${files.length} 条录音';
    _completeFileRefresh();
    _kickRealtimeFromFileList(list);
    _scheduleAutoTransferMissing();
  }

  /// Auto-refresh offline file inventory when the Files tab is shown.
  /// Skips if disconnected, mid-export, or already busy on the wire.
  Future<void> refreshFilesOnTabEnter() async {
    if (!connected) return;
    if (isExporting || needsWifiJoin) return;
    if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
    await listFiles();
  }

  void _scheduleAutoTransferMissing() {
    if (!autoRealtime || _autoTransferRunning) return;
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 200),
        _autoTransferMissingFiles,
      ),
    );
  }

  /// Catch up completed recordings over BLE without interrupting the current
  /// recording/realtime stream. Device and local lists remain newest-first.
  Future<void> _autoTransferMissingFiles() async {
    if (_autoTransferRunning || !autoRealtime) return;
    if (!connected || !_ble.isConnected || files.isEmpty) return;
    if (recording || info?.recording == true || realtimeState.active) return;
    if (isWifiExportSession || isExporting) return;
    if (phase == AppPhase.connecting || phase == AppPhase.busy) return;

    _autoTransferRunning = true;
    notifyListeners();
    var exported = 0;
    final failed = <int>[];
    try {
      await _loadLocalExports(notify: false);
      final completeIds = await _completeLocalExportIds(files);
      final missing = ExportCatalog.unexportedNewestFirst(files, completeIds);
      if (missing.isEmpty) {
        statusMessage = '已导出录音已是最新';
        return;
      }

      if (!encryptReady) await establishEncryptSession();
      if (!connected || !_ble.isConnected) return;
      phase = AppPhase.busy;

      for (var i = 0; i < missing.length; i++) {
        if (!autoRealtime || !connected || !_ble.isConnected) break;
        // A recording that starts while catching up cancels this backlog pull.
        if (recording || info?.recording == true || realtimeState.active) break;
        final file = missing[i];
        var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
        try {
          statusMessage = '自动传输 ${i + 1}/${missing.length} · ${file.title}';
          notifyListeners();
          final rawPath = await _blePull.pullFile(
            file,
            onProgress: (received, expected) {
              final now = DateTime.now();
              if (now.difference(lastProgressAt) <
                  const Duration(milliseconds: 250)) {
                return;
              }
              lastProgressAt = now;
              final progress = expected > 0
                  ? ' ${(received * 100 / expected).clamp(0, 100).floor()}%'
                  : '';
              statusMessage =
                  '自动传输 ${i + 1}/${missing.length}$progress · ${file.title}';
              notifyListeners();
            },
          );
          final path = await _convertExportToWav(rawPath, register: false);
          _registerExportedPaths([path]);
          exported++;
          notifyListeners();
        } on BleFilePullCancelled {
          break;
        } catch (error) {
          failed.add(file.fileId);
          logs = [
            'AUTO EXPORT ${file.fileId} failed: $error',
            ...logs,
          ].take(80).toList();
          if (!connected || !_ble.isConnected) break;
        }
      }

      if (failed.isNotEmpty) {
        errorMessage = '有 ${failed.length} 条录音自动传输失败，刷新后将重试';
      }
      statusMessage = exported > 0
          ? '已自动传输 $exported 条录音'
          : failed.isEmpty
          ? statusMessage
          : '自动传输未完成';
    } finally {
      _autoTransferRunning = false;
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
  }

  /// On-demand single-file download over BLE — no Wi‑Fi SoftAP setup needed.
  /// Wi‑Fi export is only worth the join dance for multiple files at once.
  Future<void> downloadFileOverBle(OfflineFileEntry file) async {
    if (_liveProcessing ||
        _isRecordingAudioLocked(file.fileId, localPathFor(file.fileId))) {
      errorMessage = '录音保存后再下载';
      notifyListeners();
      return;
    }
    if (!connected || !_ble.isConnected) {
      errorMessage = '请先通过 BLE 连接';
      notifyListeners();
      return;
    }
    if (isWifiExportSession || isExporting) return;
    if (phase == AppPhase.connecting || phase == AppPhase.busy) return;

    downloadingFileId = file.fileId;
    errorMessage = null;
    statusMessage = '正在下载 ${file.title}…';
    notifyListeners();
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _yieldBacklogToCurrentRecording();
      if (!encryptReady) await establishEncryptSession();
      if (!connected || !_ble.isConnected) return;

      phase = AppPhase.busy;
      notifyListeners();
      final rawPath = await _blePull.pullFile(
        file,
        onProgress: (received, expected) {
          final now = DateTime.now();
          if (now.difference(lastProgressAt) <
              const Duration(milliseconds: 250)) {
            return;
          }
          lastProgressAt = now;
          final progress = expected > 0
              ? ' ${(received * 100 / expected).clamp(0, 100).floor()}%'
              : '';
          statusMessage = '正在下载$progress · ${file.title}';
          notifyListeners();
        },
      );
      final path = await _convertExportToWav(rawPath, register: false);
      _registerExportedPaths([path]);
      statusMessage = '已下载 ${file.title}';
    } on BleFilePullCancelled {
      statusMessage = '已取消下载';
    } catch (e) {
      errorMessage = '下载失败，请重新连接设备后重试';
      statusMessage = '下载失败';
    } finally {
      downloadingFileId = null;
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
  }

  Future<Set<int>> _completeLocalExportIds(
    Iterable<OfflineFileEntry> deviceFiles,
  ) async {
    final complete = <int>{};
    for (final file in deviceFiles) {
      final path = localPathsByFileId[file.fileId];
      if (path == null) continue;
      try {
        final local = File(path);
        if (!await local.exists()) continue;
        final size = await local.length();
        final minimum = (file.sizeBytes * 0.95).floor();
        if (size > 0 && (file.sizeBytes <= 0 || size >= minimum)) {
          complete.add(file.fileId);
        }
      } catch (_) {}
    }
    return complete;
  }

  Future<Directory> _localExportDirectory() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    return Directory(p.join(base.path, 'AnkerRecorder', 'exports'));
  }

  Future<void> _loadLocalExports({bool notify = true}) async {
    try {
      final dir = await _localExportDirectory();
      if (!await dir.exists()) {
        if (notify) notifyListeners();
        return;
      }
      final paths = <String>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (ExportCatalog.isSupportedExportPath(name)) {
          paths.add(entity.path);
        }
      }
      _registerExportedPaths([...exportedPaths, ...paths]);
      final wavIds = paths
          .where((path) => path.endsWith('.wav'))
          .map(ExportCatalog.fileIdFromPath)
          .whereType<int>()
          .toSet();
      unawaited(_convertRawOnlyExports(paths, wavIds));
      if (notify) notifyListeners();
    } catch (error) {
      debugPrint('[Exports] load local catalog failed: $error');
    }
  }

  Future<void> _convertRawOnlyExports(
    Iterable<String> paths,
    Set<int> wavIds,
  ) async {
    if (_catalogConversionRunning) return;
    _catalogConversionRunning = true;
    try {
      for (final path in paths.where((path) => path.endsWith('.opus'))) {
        final id = ExportCatalog.fileIdFromPath(path);
        if (id == null || !wavIds.contains(id)) {
          await _convertExportToWav(path);
        }
      }
    } finally {
      _catalogConversionRunning = false;
    }
  }

  /// Copy local recordings and their transcripts to a user-selected folder.
  Future<({int audios, int transcripts, List<String> failed})> saveLocalCopies(
    Iterable<String> paths,
    String destinationPath,
  ) async {
    final destination = Directory(destinationPath);
    var audios = 0;
    var transcripts = 0;
    final failed = <String>[];

    try {
      if (!await destination.exists()) {
        await destination.create(recursive: true);
      }
    } catch (e) {
      return (audios: 0, transcripts: 0, failed: ['无法写入所选文件夹，请更换位置后重试']);
    }

    for (final path in paths.toSet()) {
      final source = File(path);
      final name = p.basename(path);
      try {
        _requireFinishedRecording(path);
        if (!await source.exists()) throw StateError('录音文件不存在');
        final audioTarget = p.join(destination.path, name);
        if (!p.equals(p.absolute(path), p.absolute(audioTarget))) {
          await source.copy(audioTarget);
        }
        audios++;

        final transcript = transcriptForPath(path)?.trim();
        if (transcript != null && transcript.isNotEmpty) {
          final stem = name.replaceFirst(
            RegExp(r'\.(?:wav|opus(?:\.bin)?)$'),
            '',
          );
          final textTarget = File(p.join(destination.path, '$stem.txt'));
          await textTarget.writeAsString(
            normalizeSttText(transcript),
            flush: true,
          );
          transcripts++;
        }
      } catch (e) {
        failed.add('$name：无法保存，请重试');
      }
    }

    statusMessage = failed.isEmpty
        ? '已另存 $audios 个录音、$transcripts 份转写'
        : '另存完成：$audios 个录音，${failed.length} 个失败';
    errorMessage = failed.isEmpty ? null : failed.join('\n');
    notifyListeners();
    return (audios: audios, transcripts: transcripts, failed: failed);
  }

  /// Materialize the selected recordings and transcript sidecars for the
  /// platform share sheet (AirDrop, Save to Files, and other apps on iOS).
  Future<List<String>> prepareLocalSharePaths(Iterable<String> paths) async {
    final result = <String>[];
    final sidecarDir = Directory(
      p.join(Directory.systemTemp.path, 'AnkerRecorder', 'share'),
    );
    await sidecarDir.create(recursive: true);

    for (final path in paths.toSet()) {
      _requireFinishedRecording(path);
      final audio = File(path);
      if (!await audio.exists()) continue;
      result.add(path);

      final transcript = transcriptForPath(path)?.trim();
      if (transcript == null || transcript.isEmpty) continue;
      final name = p.basename(path);
      final stem = name.replaceFirst(RegExp(r'\.(?:wav|opus(?:\.bin)?)$'), '');
      final sidecar = File(p.join(sidecarDir.path, '$stem.txt'));
      await sidecar.writeAsString(normalizeSttText(transcript), flush: true);
      result.add(sidecar.path);
    }
    return result;
  }

  Future<({int deleted, List<String> failed})> deleteLocalExports(
    Iterable<String> paths,
  ) async {
    final selected = paths.toSet();
    final removed = <String>{};
    var deleted = 0;
    final failed = <String>[];

    for (final path in selected) {
      final id = ExportCatalog.fileIdFromPath(path);
      final logicalPaths = id == null
          ? <String>{path}
          : <String>{
              path,
              p.join(p.dirname(path), '$id.wav'),
              p.join(p.dirname(path), '$id.opus'),
              p.join(p.dirname(path), '$id.ogg'),
              p.join(p.dirname(path), '$id.opus.bin'),
            };
      try {
        _requireFinishedRecording(path);
        if (_fileJobKey == _recordingKey(path: path)) {
          throw StateError('处理完成后再删除');
        }
        if (playingPath == path || (id != null && playingFileId == id)) {
          await stopPlayback();
        }
        for (final candidate in logicalPaths) {
          final file = File(candidate);
          if (await file.exists()) await file.delete();
          transcriptsByPath.remove(candidate);
          speakerAliasesByPath.remove(candidate);
          _localDurations.remove(candidate);
        }
        if (id != null) {
          transcriptsByFileId.remove(id);
          speakerAliasesByFileId.remove(id);
        }
        final key = _recordingKey(path: path);
        await _mossJobs.discard(key);
        _transcriptMetadata.remove(key);
        _recordingTranslations.remove(key);
        _recordingErrors.remove(key);
        _recordingSessions.removeWhere(
          (_, session) =>
              id != null && session.fileId == id || session.path == path,
        );
        removed.add(path);
        deleted++;
      } catch (error) {
        failed.add('${p.basename(path)}：无法删除，请稍后重试');
      }
    }

    exportedPaths.removeWhere((path) {
      final id = ExportCatalog.fileIdFromPath(path);
      return removed.contains(path) ||
          (id != null &&
              removed.any((item) => ExportCatalog.fileIdFromPath(item) == id));
    });
    _registerExportedPaths(exportedPaths);
    if (expandedLocalPath != null && selected.contains(expandedLocalPath)) {
      expandedLocalPath = null;
    }
    await _persistTranscripts();
    statusMessage = failed.isEmpty
        ? '已删除 $deleted 个本地录音'
        : '已删除 $deleted 个录音，${failed.length} 个失败';
    errorMessage = failed.isEmpty ? null : failed.join('\n');
    notifyListeners();
    return (deleted: deleted, failed: failed);
  }

  Future<String> renameLocalExport(String path, String label) async {
    _requireFinishedRecording(path);
    if (_fileJobKey == _recordingKey(path: path)) throw StateError('处理完成后再重命名');
    final mossJob = _mossJobs.active;
    if (mossJob?.recordingKey == _recordingKey(path: path) &&
        (mossJob?.stage == MossJobStage.queued ||
            mossJob?.stage == MossJobStage.uploadUnknown)) {
      throw StateError('上传完成后再重命名');
    }
    final source = File(path);
    if (!await source.exists()) throw StateError('文件不存在');

    final targetName = ExportCatalog.renamedFileName(path, label);
    final targetPath = p.join(p.dirname(path), targetName);
    if (targetPath == path) return path;
    final target = File(targetPath);
    if (await target.exists()) throw StateError('同名文件已存在');

    final id = ExportCatalog.fileIdFromPath(path);
    if (playingPath == path || (id != null && playingFileId == id)) {
      await stopPlayback();
    }

    await source.rename(targetPath);
    await _mossJobs.rename(
      _recordingKey(path: path),
      _recordingKey(path: targetPath),
      targetPath,
    );

    final transcript = transcriptsByPath.remove(path);
    if (transcript != null) transcriptsByPath[targetPath] = transcript;
    final aliases = speakerAliasesByPath.remove(path);
    if (aliases != null) speakerAliasesByPath[targetPath] = aliases;
    for (final session in _recordingSessions.values) {
      if (session.path == path) session.path = targetPath;
    }
    final cachedDuration = _localDurations.remove(path);
    if (cachedDuration != null) _localDurations[targetPath] = cachedDuration;
    final renamedPaths = exportedPaths
        .map((item) => item == path ? targetPath : item)
        .toList();
    exportedPaths = [];
    _registerExportedPaths(renamedPaths);
    if (expandedLocalPath == path) expandedLocalPath = targetPath;
    await _persistTranscripts();

    statusMessage = '已重命名为 $targetName';
    errorMessage = null;
    notifyListeners();
    return targetPath;
  }

  void _registerExportedPaths(Iterable<String> paths) {
    exportedPaths = ExportCatalog.newestPathsFirst([
      ...exportedPaths,
      ...paths,
    ]);
    localPathsByFileId.clear();
    for (final path in exportedPaths) {
      final id = ExportCatalog.fileIdFromPath(path);
      if (id != null) localPathsByFileId[id] = path;
    }
    _localDurations.removeWhere((path, _) => !exportedPaths.contains(path));
  }

  Duration? localDurationForPath(String path) {
    final cached = _localDurations[path];
    if (cached != null) return cached;
    if (_durationLoads.add(path)) unawaited(_loadLocalDuration(path));
    return null;
  }

  Future<void> _loadLocalDuration(String path) async {
    try {
      final value = await AudioDuration.read(path);
      if (value != null && exportedPaths.contains(path)) {
        _localDurations[path] = value;
        notifyListeners();
      }
    } finally {
      _durationLoads.remove(path);
    }
  }

  Future<String> _convertExportToWav(
    String path, {
    bool register = true,
    List<String>? conversionFailures,
  }) async {
    if (!path.endsWith('.opus')) return path;
    final existing = _wavConversions[path];
    final ownsConversion = existing == null;
    final conversion = existing ?? OpusWave.convertRawFile(path);
    if (ownsConversion) {
      _wavConversions[path] = conversion;
    }
    try {
      final wavPath = await conversion;
      if (register) {
        _registerExportedPaths([wavPath]);
        if (errorMessage == '无法准备播放，录音已保留，请重试') {
          errorMessage = null;
        }
        notifyListeners();
      }
      return wavPath;
    } catch (error) {
      debugPrint('[Exports] WAV conversion failed for $path: $error');
      final failure = '${p.basename(path)}: $error';
      if (conversionFailures != null) {
        conversionFailures.add(failure);
      } else {
        errorMessage = '无法准备播放，录音已保留，请重试';
        notifyListeners();
      }
      return path;
    } finally {
      if (ownsConversion && identical(_wavConversions[path], conversion)) {
        _wavConversions.remove(path);
      }
    }
  }

  Future<void> deleteFile(int fileId) async {
    if (_isRecordingAudioLocked(fileId, localPathFor(fileId))) {
      errorMessage = '录音保存后再删除';
      notifyListeners();
      return;
    }
    await _send(DeviceCommands.deleteFile(fileId), label: '正在删除文件…');
  }

  Future<int> deleteSelectedDeviceFiles() async {
    if (!_ble.isConnected || selectedFileIds.isEmpty) return 0;
    final ids = selectedFileIds
        .where((id) => !_isRecordingAudioLocked(id, localPathFor(id)))
        .toList();
    if (ids.isEmpty) return 0;
    phase = AppPhase.busy;
    errorMessage = null;
    var deleted = 0;
    notifyListeners();
    try {
      for (var i = 0; i < ids.length; i++) {
        statusMessage = '正在删除 ${i + 1}/${ids.length}…';
        notifyListeners();
        await _ble.writeCommand(DeviceCommands.deleteFile(ids[i]));
        deleted++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      files.removeWhere((file) => ids.contains(file.fileId));
      selectedFileIds.clear();
      selecting = false;
      statusMessage = '已删除 $deleted 个设备端录音';
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _ble.writeCommand(DeviceCommands.listFiles());
    } catch (error) {
      errorMessage = '部分录音未删除，请刷新后重试';
    } finally {
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
    return deleted;
  }

  /// Last bind/unbind we sent: true=bind, false=unbind, null=unknown.
  /// Feishu uses the same RX id (0x87) for both; we need this to interpret ACKs.
  bool? _pendingBindRequest;
  Timer? _postBindFileRefreshTimer;

  void _schedulePostBindFileRefresh() {
    _postBindFileRefreshTimer?.cancel();
    _postBindFileRefreshTimer = Timer(const Duration(milliseconds: 700), () {
      if (!connected || !bound || isExporting || needsWifiJoin) return;
      unawaited(listFiles());
    });
  }

  Future<void> bindDevice() async {
    _pendingBindRequest = true;
    await _send(DeviceCommands.bind(), label: '正在绑定…');
  }

  /// Unbind with the stock Feishu payload. This preserves recordings and
  /// disconnects BLE after a successful ACK.
  Future<void> unbindDevice() async {
    _postBindFileRefreshTimer?.cancel();
    _pendingBindRequest = false;
    await _send(DeviceCommands.unbind(), label: '正在解绑…');
  }

  Future<void> resetDevice() =>
      _send(DeviceCommands.resetDevice(), label: '正在恢复出厂…');

  Future<void> setFindMy(bool on) =>
      _send(DeviceCommands.setFindMy(on), label: on ? '正在开启查找…' : '正在关闭查找…');

  // ── Wi‑Fi batch export ────────────────────────────────────────────────

  /// Snapshot of files to transfer, taken while still BLE-connected. Joining
  /// the device's SoftAP for the actual transfer causes a natural BLE drop,
  /// which wipes `files`/`selectedFileIds` — continueWifiExport() must not
  /// re-derive its target list from those afterwards or it sees nothing.
  List<OfflineFileEntry> _pendingExportTargets = [];
  int _wifiExportRun = 0;

  /// Open device SoftAP and wait for IP:port. UI should then prompt join.
  Future<WifiEndpoint?> beginWifiExport() async {
    if (_liveProcessing) {
      errorMessage = '录音保存后再导出';
      notifyListeners();
      return null;
    }
    _wifiExportRun++;
    if (!_ble.isConnected) {
      errorMessage = '请先通过 BLE 连接';
      notifyListeners();
      return null;
    }
    final targets =
        (selectedFileIds.isNotEmpty ? selectedUnexportedFiles : unexportedFiles)
            .where(
              (file) => !_isRecordingAudioLocked(
                file.fileId,
                localPathFor(file.fileId),
              ),
            )
            .toList();
    if (targets.isEmpty) {
      errorMessage = selectedFileIds.isNotEmpty ? '所选录音均已导出' : '所有录音均已导出';
      notifyListeners();
      return null;
    }
    _pendingExportTargets = List.of(targets);

    errorMessage = null;
    phase = AppPhase.busy;
    statusMessage = '正在准备下载…';
    notifyListeners();

    // Ensure ECDH session before SoftAP so file keys can be unwrapped.
    if (!encryptReady) {
      final ok = await establishEncryptSession();
      if (!ok) {
        statusMessage = '录音暂时无法解密，请重新连接设备后重试';
        notifyListeners();
      }
    }

    statusMessage = '正在开启设备 Wi‑Fi…';
    notifyListeners();

    try {
      final ep = await _wifi.openSoftAp(
        onConfigured: () async {
          // Match Soundcore SDK handleConfigSuccess(): preserve the encryption
          // session, disconnect BLE, then let the recorder finish SoftAP startup.
          _stopBatteryPoll();
          await _ble.disconnect();
        },
      );
      statusMessage = '请连接 Wi‑Fi「${ep.ssid}」，然后点「继续导出」';
      // Stay "busy" while awaiting join so other ops don't collide.
      notifyListeners();
      return ep;
    } catch (e) {
      errorMessage = e.toString();
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = null;
      notifyListeners();
      return null;
    }
  }

  /// After user joined SoftAP, run WebSocket transfer for selection (or all).
  Future<List<String>> continueWifiExport() async {
    final run = _wifiExportRun;
    final ep = exportProgress.endpoint;
    if (ep == null) {
      const msg = '设备 Wi‑Fi 未就绪，请重新开始导出';
      errorMessage = msg;
      // The join sheet only reads exportProgress.error, not errorMessage —
      // without this it silently resets with no visible feedback.
      exportProgress = exportProgress.copyWith(
        phase: ExportPhase.error,
        error: msg,
      );
      notifyListeners();
      return const [];
    }
    final targets = _pendingExportTargets;
    if (targets.isEmpty) {
      const msg = '未选择文件';
      errorMessage = msg;
      exportProgress = exportProgress.copyWith(
        phase: ExportPhase.error,
        error: msg,
      );
      notifyListeners();
      return const [];
    }

    phase = AppPhase.busy;
    statusMessage = encryptReady ? '正在通过 Wi‑Fi 传输并解密…' : '正在通过 Wi‑Fi 传输（原始密文）…';
    notifyListeners();

    try {
      final rawPaths = await _wifi.transferFiles(endpoint: ep, files: targets);
      if (run != _wifiExportRun) return const [];
      final paths = <String>[];
      final conversionFailures = <String>[];
      for (final path in rawPaths) {
        paths.add(
          await _convertExportToWav(
            path,
            register: false,
            conversionFailures: conversionFailures,
          ),
        );
      }
      _registerExportedPaths(paths);
      _pendingExportTargets = [];
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = paths.isEmpty
          ? '导出完成但无数据'
          : '已导出 ${paths.length} 个文件'
                '${encryptReady ? "（已解密）" : "（原始密文 — 无会话）"}';
      // WAV conversion runs per file after the transfer; surface failures
      // instead of silently leaving the raw .opus frame stream behind.
      errorMessage = conversionFailures.isEmpty
          ? null
          : 'WAV 转码失败，已保留原始 Opus 帧：${conversionFailures.join("; ")}';
      selecting = false;
      selectedFileIds.clear();
      notifyListeners();
      _reconnectBleAfterWifiExport();
      return paths;
    } catch (e) {
      if (run != _wifiExportRun) return const [];
      errorMessage = e.toString();
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = '导出失败';
      notifyListeners();
      _reconnectBleAfterWifiExport();
      return const [];
    }
  }

  // ── Playback (local exported files only) ──────────────────────────────

  /// Which local export row shows inline transport (path key).
  String? expandedLocalPath;

  void toggleLocalExpanded(String path) {
    expandedLocalPath = expandedLocalPath == path ? null : path;
    notifyListeners();
  }

  void toggleFileExpanded(int fileId) {
    if (selecting) {
      toggleFileSelected(fileId);
      return;
    }
    expandedFileId = expandedFileId == fileId ? null : fileId;
    notifyListeners();
  }

  String? localPathFor(int fileId) => localPathsByFileId[fileId];

  int? fileIdFromPath(String path) => _fileIdFromPath(path);

  bool isFilePlaying(int fileId) => playingFileId == fileId && isPlaying;

  bool isFileLoaded(int fileId) => playingFileId == fileId;

  /// Load local [path] and start playback. Tapping the same track pauses.
  ///
  /// Completed exports are standard WAV. Legacy raw Opus files are still muxed
  /// to Ogg on demand for playback compatibility.
  Future<void> playExported(String path, {int? fileId}) async {
    if (_isRecordingAudioLocked(fileId ?? fileIdFromPath(path), path)) {
      errorMessage = '录音保存后即可播放';
      notifyListeners();
      return;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        errorMessage = '找不到录音，请重新下载';
        statusMessage = '无法播放';
        notifyListeners();
        return;
      }
      if (await file.length() == 0) {
        errorMessage = '文件为空，无法播放';
        statusMessage = '无法播放';
        notifyListeners();
        return;
      }

      // Keep the local row expanded so transport controls stay visible.
      expandedLocalPath = path;

      // Same logical track (raw .opus or its .ogg sidecar).
      final logicalId = fileId ?? _fileIdFromPath(path);
      if (playingPath != null &&
          (playingPath == path ||
              playingFileId == logicalId && logicalId != null)) {
        await togglePlayPause();
        return;
      }
      errorMessage = null;
      statusMessage = '正在准备播放 ${path.split('/').last}…';
      notifyListeners();

      final playPath = await OggOpus.ensurePlayable(path);
      final len = await File(playPath).length();
      if (len < 64) {
        throw StateError('封装后的音频无效（${len}B）');
      }

      await _player.stop();
      final durationFromFile = await _player.setFilePath(playPath);
      await _player.setSpeed(playbackSpeed);
      playingPath = path; // keep UI key on original export path
      playingFileId = logicalId;
      position = Duration.zero;
      duration = durationFromFile ?? _player.duration ?? Duration.zero;
      // Duration may arrive async on some platforms.
      if (duration <= Duration.zero) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        duration = _player.duration ?? Duration.zero;
      }
      await _player.play();
      final sec = duration.inMilliseconds / 1000.0;
      statusMessage = duration > Duration.zero
          ? '正在播放 · ${sec.toStringAsFixed(1)}s'
          : '正在播放 ${path.split('/').last}';
      notifyListeners();
    } catch (e) {
      errorMessage = '无法播放录音，请重新下载后重试';
      statusMessage = '无法播放';
      playingPath = null;
      playingFileId = null;
      isPlaying = false;
      duration = Duration.zero;
      notifyListeners();
    }
  }

  int? _fileIdFromPath(String path) => ExportCatalog.fileIdFromPath(path);

  Future<void> togglePlayPause() async {
    if (playingPath == null) return;
    try {
      if (isPlaying) {
        await _player.pause();
        _clearPlayingStatus();
      } else {
        // Restart if finished.
        if (duration > Duration.zero &&
            position >= duration - const Duration(milliseconds: 200)) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
        final sec = duration.inMilliseconds / 1000.0;
        statusMessage = duration > Duration.zero
            ? '正在播放 · ${sec.toStringAsFixed(1)}s'
            : '正在播放';
      }
      notifyListeners();
    } catch (e) {
      errorMessage = '无法控制播放，请重新打开录音';
      notifyListeners();
    }
  }

  Future<void> seekBy(Duration delta) async {
    if (playingPath == null) return;
    final total = duration > Duration.zero ? duration : position + delta;
    var target = position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    await seekTo(target);
  }

  Future<void> seekTo(Duration target) async {
    if (playingPath == null) return;
    try {
      await _player.seek(target);
      position = target;
      notifyListeners();
    } catch (e) {
      errorMessage = '无法跳转，请重试';
      notifyListeners();
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeed = speed;
    try {
      await _player.setSpeed(speed);
    } catch (e) {
      errorMessage = '无法更改播放速度，请重试';
    }
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    try {
      await _player.stop();
    } catch (_) {}
    playingPath = null;
    playingFileId = null;
    isPlaying = false;
    position = Duration.zero;
    duration = Duration.zero;
    _clearPlayingStatus();
    notifyListeners();
  }

  Future<void> cancelWifiExport() async {
    _wifiExportRun++;
    await _wifi.cancel();
    _pendingExportTargets = [];
    phase = connected ? AppPhase.ready : AppPhase.idle;
    statusMessage = '已取消导出';
    notifyListeners();
    _reconnectBleAfterWifiExport();
  }

  void _reconnectBleAfterWifiExport() {
    if (!connected && bound && !_explicitDisconnect && !_ble.isConnecting) {
      unawaited(startScan());
    }
  }

  Future<void> copyWifiCredentials() async {
    final s = exportProgress.ssid;
    final pw = exportProgress.password;
    if (s == null || pw == null) return;
    await Clipboard.setData(ClipboardData(text: 'SSID：$s\n密码：$pw'));
    statusMessage = '凭证已复制';
    notifyListeners();
  }

  void clearExportState() {
    exportProgress = ExportProgress();
    notifyListeners();
  }

  /// Newest first. Prefer [OfflineFileEntry.endTime], else [fileId] (unix ts).
  List<OfflineFileEntry> _sortFilesNewestFirst(List<OfflineFileEntry> list) {
    final copy = List<OfflineFileEntry>.from(list);
    copy.sort((a, b) {
      final ta = a.endTime ?? a.fileId;
      final tb = b.endTime ?? b.fileId;
      return tb.compareTo(ta);
    });
    return copy;
  }

  void _onPacket(DecodedPacket p) {
    // Device info family (type 0x01)
    if (p.cmdType == RxCmd.deviceInfoType) {
      if (p.cmdId == RxCmd.deviceInfoId) {
        info = DeviceInfoModel.parsePacket(p.raw);
        lastKnownInfo = info;
        if (activeDevice != null) lastKnownDevice = activeDevice;
        unawaited(_persistDevice());
        statusMessage =
            '麦克风 ${info?.battery ?? "—"}% · 充电盒 ${info?.boxBattery ?? "—"}%';
        final hex = info?.rawHex ?? '';
        if (hex.isNotEmpty) {
          logs = [
            'DEVINFO ${hex.length > 120 ? '${hex.substring(0, 120)}…' : hex}',
            ...logs,
          ].take(80).toList();
        }
      } else if (p.cmdId == RxCmd.batteryId && p.payload.length >= 2) {
        // Convert D3200's 0–9 battery buckets to display percentages.
        final micRaw = p.payload[0] & 0xFF;
        final boxRaw = p.payload[1] & 0xFF;
        final mic = DeviceInfoModel.batteryRemaining(micRaw) ?? 0;
        final box = DeviceInfoModel.batteryRemaining(boxRaw) ?? 0;
        info = (info ?? DeviceInfoModel()).copyWith(
          battery: mic,
          boxBattery: box,
        );
        lastKnownInfo = info;
        statusMessage = '麦克风 $mic% · 充电盒 $box%';
        logs = [
          'BATT mic=$mic% (raw $micRaw) box=$box% (raw $boxRaw)',
          ...logs,
        ].take(80).toList();
        debugPrint('[Battery] mic=$mic% raw=$micRaw box=$box% raw=$boxRaw');
      } else if (p.cmdId == RxCmd.chargingId && p.payload.length >= 2) {
        final micChg = (p.payload[0] & 0xFF) == 1;
        final boxChg = (p.payload[1] & 0xFF) == 1;
        info = (info ?? DeviceInfoModel()).copyWith(
          charging: micChg,
          boxCharging: boxChg,
        );
        lastKnownInfo = info;
        statusMessage = micChg || boxChg ? '充电中…' : '未充电';
        // Charging transitions often don't include % — refresh full device info.
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 400),
            () => refreshInfo(silent: true),
          ),
        );
      } else if (p.cmdId == RxCmd.resetId) {
        statusMessage = p.isSuccess ? '设备已重置' : '重置失败';
      } else if (p.cmdId == RxCmd.syncTimeId) {
        statusMessage = p.isSuccess ? '时钟已同步' : '时钟同步失败';
      }
    }

    // File list (newest first — fileId is a unix timestamp for D3200).
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.fileListId) {
      final list = OfflineFileList.parse(p.payload);
      files = _sortFilesNewestFirst(list.files);
      statusMessage = '${files.length} 条录音';
      _kickRealtimeFromFileList(list);
      _scheduleAutoTransferMissing();
    }
    if (p.cmdType == RxCmd.transportTypeAlt && p.cmdId == RxCmd.fileListId) {
      final list = OfflineFileList.parse(p.payload, withEndTime: true);
      _handleFileListPage(list);
    }

    // 1A06 — new file while recording (Feishu: always status=recording + fileId LE @payload[0]).
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.recordStatusId) {
      if (p.payload.length >= 4) {
        final fileId = readU32Le(p.payload, 0);
        if (fileId > 0) {
          _applyRecordStatus(1, fileId: fileId, source: '1A06');
        }
      }
    }

    // Delete
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.deleteId) {
      statusMessage = p.isSuccess ? '文件已删除' : '删除失败';
      if (p.isSuccess) {
        listFiles();
      }
    }

    // 0x18/0x82 — Feishu onReceiveAudioStatusChanged (not cmdId 6 path):
    // payload[0]: 0=stop, 1=resume/record, 2=pause; stop may include duration u32 @1.
    if (p.cmdType == RxCmd.audioType && p.cmdId == RxCmd.audioControlId) {
      if (p.payload.isNotEmpty) {
        final status = p.payload[0] & 0xFF;
        int? durationSec;
        if (status == 0 && p.payload.length >= 5) {
          durationSec = readU32Le(p.payload, 1);
        }
        // Only apply known statuses; ignore empty ACKs without a status byte meaning.
        if (status == 0 || status == 1 || status == 2) {
          _applyRecordStatus(
            status,
            durationSec: durationSec,
            source: '0x18/0x82',
          );
        }
      }
    }

    // Device info recording bit (0/1/2; we store bool as status==1 only).
    // Always sync UI so hardware mic-off clears the sticky 「录音中」 pill.
    if (p.cmdType == RxCmd.deviceInfoType && p.cmdId == RxCmd.deviceInfoId) {
      final deviceRecording = info?.recording == true;
      if (deviceRecording != recording) {
        _applyRecordStatus(deviceRecording ? 1 : 0, source: 'device_info');
      } else if (deviceRecording &&
          !realtimeState.active &&
          !isWifiExportSession) {
        unawaited(_maybeStartAutoRealtime(reason: 'device_info_recording'));
      }
    }

    // Binding — Feishu BindingMessageDispatch:
    //  0x87 = bind/unbind command result (successFlag low nibble of status)
    //  0x88 = device confirm after bind (not used for unbind)
    if (p.cmdType == RxCmd.bindType) {
      if (p.cmdId == RxCmd.bindResultId) {
        final ok = p.isSuccess;
        if (_pendingBindRequest == false) {
          // Unbind ACK
          if (ok) {
            bound = false;
            statusMessage = '已解绑（可重新扫描连接）';
            unawaited(_persistDevice());
            // Match Feishu: drop link after successful unbind.
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 400),
                () => disconnect(),
              ),
            );
          } else {
            statusMessage = '解绑失败';
            errorMessage = '解绑失败，请重新连接后重试';
          }
        } else {
          // Bind ACK (or unknown — treat as bind)
          if (ok) {
            bound = true;
            if (activeDevice != null) lastKnownDevice = activeDevice;
            unawaited(_persistDevice());
            statusMessage = '正在绑定…';
            _schedulePostBindFileRefresh();
          } else {
            statusMessage = '绑定失败';
            errorMessage = '绑定失败，请重新连接后重试';
          }
        }
      } else if (p.cmdId == RxCmd.bindConfirmId) {
        if (p.isSuccess) {
          bound = true;
          if (activeDevice != null) lastKnownDevice = activeDevice;
          unawaited(_persistDevice());
          statusMessage = '已绑定';
          _schedulePostBindFileRefresh();
        } else {
          statusMessage = '绑定确认失败';
          errorMessage = '绑定失败，请重新连接后重试';
        }
      }
    }

    // Encrypt handshake RX (type 0x2E id 0x01)
    if (p.cmdType == RxCmd.encryptType && p.cmdId == RxCmd.encryptHandshakeId) {
      _onEncryptResponse(p);
    }

    notifyListeners();
  }

  void _onEncryptResponse(DecodedPacket p) {
    // Feishu EncryptMessageDispatch: need full frame ≥ 106
    // device pubkey @9 (65B), shared @74 (32B)
    final raw = p.raw;
    logs = [
      'ENCRYPT RX ok=${p.isSuccess} len=${raw.length}',
      ...logs,
    ].take(80).toList();
    if (raw.length < 106) {
      if (!(_encryptCompleter?.isCompleted ?? true)) {
        _encryptCompleter!.complete(false);
      }
      return;
    }
    final devPub = Uint8List.fromList(raw.sublist(9, 74));
    final devShared = Uint8List.fromList(raw.sublist(74, 106));
    final ok = _crypto.completeHandshake(
      devicePublicKey: devPub,
      deviceSharedKey: devShared,
    );
    encryptReady = ok;
    if (!(_encryptCompleter?.isCompleted ?? true)) {
      _encryptCompleter!.complete(ok);
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
      _mossJobs.wake();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _completeFileRefresh();
    _fileJobRevision++;
    _capabilityRevision++;
    _sttLifecycleRevision++;
    _postBindFileRefreshTimer?.cancel();
    _fileListPageTimeout?.cancel();
    _recordingShortcutTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    _boundReconnectTimer?.cancel();
    _stopBatteryPoll();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_sttStreamSub?.cancel());
    unawaited(_sttStream?.dispose());
    _opusPcm.dispose();
    unawaited(_player.dispose());
    unawaited(_realtime.dispose());
    _sonioxStt.dispose();
    _mossJobs.dispose();
    unawaited(_appleSpeech.dispose());
    _wifi.dispose();
    _ble.dispose();
    super.dispose();
  }
}

class _SpeechConfiguration {
  const _SpeechConfiguration({
    required this.provider,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.ownerLanguage,
    required this.guestLanguage,
    required this.mode,
    required this.enabled,
    required this.appleReady,
    required this.appleTranslationReady,
    this.sonioxKey,
    this.mossKey,
  });
  final SttProvider provider;
  final String sourceLanguage;
  final String targetLanguage;
  final String ownerLanguage;
  final String guestLanguage;
  final SttDisplayMode mode;
  final bool enabled;
  final bool appleReady;
  final bool appleTranslationReady;
  final String? sonioxKey;
  final String? mossKey;

  _SpeechConfiguration withSourceLanguage(String source) =>
      _SpeechConfiguration(
        provider: provider,
        sourceLanguage: source,
        targetLanguage: targetLanguage,
        ownerLanguage: ownerLanguage,
        guestLanguage: guestLanguage,
        mode: mode,
        enabled: enabled,
        appleReady: appleReady,
        appleTranslationReady: appleTranslationReady,
        sonioxKey: sonioxKey,
        mossKey: mossKey,
      );
}

class _RecordingSession {
  _RecordingSession(this.id, this.configuration);
  final String id;
  final _SpeechConfiguration configuration;
  int? fileId;
  String? path;
  String text = '';
  RecordingTranslation? translation;
  String? error;
  bool ended = false;
  bool active = true;
  bool paused = false;
  bool finalizing = false;
}
