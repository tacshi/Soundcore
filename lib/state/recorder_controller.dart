import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/soniox_stt.dart';
import '../ai/soniox_stt_stream.dart';
import '../ai/stt_types.dart';
import '../ai/xai_stt.dart';
import '../ai/xai_stt_stream.dart';
import '../audio/ogg_opus.dart';
import '../audio/opus_pcm_decoder.dart';
import '../audio/opus_wave.dart';
import '../ble/ble_service.dart';
import '../ble/ble_file_pull.dart';
import '../ble/realtime_stream.dart';
import '../crypto/device_crypto.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../wifi/wifi_export_service.dart';
import 'app_settings_store.dart';
import 'device_store.dart';
import 'export_catalog.dart';
import 'transcript_store.dart';

enum AppPhase { idle, scanning, connecting, ready, busy }

class RecorderController extends ChangeNotifier {
  RecorderController({BleService? ble}) : _ble = ble ?? BleService() {
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
          _recordWireStatus = 0;
          if (!wifiHandoff) {
            encryptReady = false;
            _crypto.resetSession();
            _encryptCompleter = null;
          }
          _stopBatteryPoll();
          _fileListPageTimeout?.cancel();
          _loadingFileListPages = false;
          unawaited(_realtime.stop());
          realtimeState = const RealtimeStreamState();
          unawaited(_finishStreamStt());
          unawaited(stopPlayback());
          // Reconnect unexpected drops immediately, except for the expected
          // BLE→Wi-Fi handoff; that reconnect starts after transfer cleanup.
          if (bound && !_explicitDisconnect && !wifiHandoff) {
            unawaited(startScan());
          }
          _explicitDisconnect = false;
        } else {
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
    unawaited(_loadPersistedSettings());
    unawaited(_loadPersistedDevice());
    unawaited(_loadLocalExports());
    _transcriptsLoaded = _loadPersistedTranscripts();
  }

  Future<void> _loadPersistedSettings() async {
    final s = await AppSettingsStore.load();
    if (s.xaiApiKey != null) _xaiStt.apiKeyOverride = s.xaiApiKey;
    if (s.sonioxApiKey != null) _sonioxStt.apiKeyOverride = s.sonioxApiKey;
    autoTranscribe = s.autoTranscribe;
    autoRealtime = s.autoRealtime;
    transcriptLanguage = s.transcriptLanguage;
    // Prefer saved provider when its key is available; else pick configured one.
    final xai = _xaiStt.isConfigured;
    final soniox = _sonioxStt.isConfigured;
    if (s.sttProvider == SttProvider.soniox && soniox) {
      sttProvider = SttProvider.soniox;
    } else if (s.sttProvider == SttProvider.xai && xai) {
      sttProvider = SttProvider.xai;
    } else if (soniox && !xai) {
      sttProvider = SttProvider.soniox;
    } else if (xai && !soniox) {
      sttProvider = SttProvider.xai;
    } else {
      sttProvider = SttProvider.soniox;
    }
    notifyListeners();
  }

  Future<void> _persistSettings() async {
    await AppSettingsStore.save(
      AppSettings(
        xaiApiKey: _xaiStt.apiKeyOverride,
        sonioxApiKey: _sonioxStt.apiKeyOverride,
        sttProvider: sttProvider,
        autoTranscribe: autoTranscribe,
        autoRealtime: autoRealtime,
        transcriptLanguage: transcriptLanguage,
      ),
    );
  }

  Future<void> _loadPersistedDevice() async {
    final saved = await DeviceStore.load();
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
    if (connected || phase == AppPhase.connecting || _ble.isConnecting) return;
    statusMessage = '正在自动连接已绑定设备…';
    await startScan();
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
    notifyListeners();
  }

  Future<void> _persistTranscripts() async {
    await _transcriptsLoaded;
    await TranscriptStore.save(
      byPath: transcriptsByPath,
      byFileId: transcriptsByFileId,
    );
  }

  void _onRealtimeState(RealtimeStreamState s) {
    final wasActive = realtimeState.active;
    realtimeState = s;
    if (s.path != null && s.bytesReceived > 0) {
      final path = s.path!;
      _registerExportedPaths([path]);
      // Prefer low-latency PCM stream STT; fall back to rolling Ogg batch.
      if (s.active && autoTranscribe && !_streamSttPreferred) {
        unawaited(
          _maybeTranscribeRolling(path, s.bytesReceived, finalPass: false),
        );
      }
    }
    // When a session finishes with data, keep path listed for playback + final STT.
    if (!s.active && s.path != null && s.bytesReceived > 0) {
      unawaited(_convertExportToWav(s.path!));
      statusMessage =
          '实时录音已保存 ${s.path!.split('/').last}（${(s.bytesReceived / 1024).toStringAsFixed(1)} KB）';
      // Attach any live transcript we already have to this file card.
      final liveText = transcript.trim().isNotEmpty
          ? transcript.trim()
          : (transcriptPartial?.trim() ?? '');
      if (liveText.isNotEmpty) {
        rememberTranscript(s.path!, liveText);
      }
      if (autoTranscribe) {
        if (_streamSttPreferred) {
          unawaited(_finishStreamStt(bindPath: s.path));
        } else {
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
  void rememberTranscript(String path, String text) {
    final t = normalizeSttText(text);
    if (path.isEmpty || t.isEmpty) return;
    transcriptsByPath[path] = t;
    // Also index by file id when known.
    final id = fileIdFromPath(path);
    if (id != null) transcriptsByFileId[id] = t;
    unawaited(_persistTranscripts());
  }

  String? transcriptForPath(String path) {
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
        exportedPaths.isNotEmpty &&
        exportedPaths.first == path) {
      final live = transcript.trim();
      if (live.isNotEmpty) return live;
      final partial = transcriptPartial?.trim();
      if (partial != null && partial.isNotEmpty) return partial;
    }
    return null;
  }

  String? transcriptForFileId(int fileId) => transcriptsByFileId[fileId];

  /// Live BLE Opus frame → PCM16 → provider WS STT (when auto-transcribe on).
  void _onRealtimeOpusFrame(Uint8List frame) {
    if (!autoTranscribe || !sttConfigured) return;
    if (!_preferStreamStt) return;
    if (!_opusPcm.ensureStarted()) {
      _preferStreamStt = false;
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
      _preferStreamStt && _opusPcm.isReady && autoTranscribe;

  Future<bool> _ensureStreamStt() async {
    if (!autoTranscribe || !sttConfigured || !_preferStreamStt) return false;
    if (_sttStream != null && _sttStream!.isServerReady) {
      streamingSttActive = true;
      _flushPendingPcm();
      return true;
    }
    if (_streamSttStarting) return false;
    final key = _activeSttApiKey;
    if (key == null) return false;
    if (!_opusPcm.ensureStarted()) {
      _preferStreamStt = false;
      return false;
    }

    _streamSttStarting = true;
    try {
      await _sttStream?.close();
      final session = _createStreamSession(key);
      await _sttStreamSub?.cancel();
      _sttStreamSub = session.events.listen(_onSttStreamEvent);
      await session.start();
      _sttStream = session;
      streamingSttActive = true;
      _preferStreamStt = true;
      transcriptError = null;
      statusMessage = '实时转写已连接（${sttProvider.label} PCM 流）';
      _flushPendingPcm();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[STT] stream start failed (${sttProvider.label}): $e');
      streamingSttActive = false;
      _preferStreamStt = false;
      _pendingPcm.clear();
      transcriptError = '实时转写连接失败（${sttProvider.label}），将回退批量转写：$e';
      _sttStream = null;
      notifyListeners();
      return false;
    } finally {
      _streamSttStarting = false;
    }
  }

  SttStreamSession _createStreamSession(String key) {
    switch (sttProvider) {
      case SttProvider.soniox:
        return SonioxSttStreamSession(
          apiKey: key,
          sampleRate: 16000,
          language: _sttLanguageParam,
          languageHints: _sonioxLanguageHints,
        );
      case SttProvider.xai:
        return XaiSttStreamSession(
          apiKey: key,
          sampleRate: 16000,
          language: _sttLanguageParam,
          interimResults: true,
        );
    }
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
    switch (e.type) {
      case 'partial':
        if (e.text.isEmpty) return;
        final incoming = normalizeSttText(e.text);
        if (incoming.isEmpty) return;
        if (e.speechFinal) {
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
        notifyListeners();
      case 'done':
        if (e.text.isNotEmpty) {
          transcript = normalizeSttText(e.text);
          transcriptPartial = null;
        }
        transcribing = false;
        streamingSttActive = false;
        statusMessage = e.durationSec != null
            ? '实时转写完成（${sttProvider.label} · ${e.durationSec!.toStringAsFixed(1)}s）'
            : '实时转写完成（${sttProvider.label}）';
        notifyListeners();
      case 'error':
        transcriptError = e.error ?? 'STT stream error';
        streamingSttActive = false;
        _preferStreamStt = false;
        notifyListeners();
      case 'closed':
        streamingSttActive = false;
        transcribing = false;
        notifyListeners();
      default:
        break;
    }
  }

  Future<void> _finishStreamStt({String? bindPath}) async {
    final session = _sttStream;
    if (session == null && _pendingPcm.isEmpty) return;
    _sttStream = null;
    streamingSttActive = false;
    try {
      if (session != null) {
        _flushPendingPcmTo(session);
        final done = await session.finish();
        if (done != null && done.text.isNotEmpty) {
          // Prefer stitched session text when longer / complete.
          if (done.text.length >= transcript.length) {
            transcript = done.text;
          }
          transcriptPartial = null;
        }
      }
      final text = transcript.trim();
      final path = bindPath ?? realtimeState.path;
      if (text.isNotEmpty && path != null) {
        rememberTranscript(path, text);
      }
    } catch (e) {
      debugPrint('[STT] stream finish: $e');
    } finally {
      _pendingPcm.clear();
      await _sttStreamSub?.cancel();
      _sttStreamSub = null;
      await session?.dispose();
      transcribing = false;
      notifyListeners();
    }
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
      unawaited(_finishStreamStt());
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

  /// True while hardware recording, BLE realtime pull, or live STT is active.
  bool get isLiveSession =>
      recording || realtimeState.active || streamingSttActive;

  void setTranscriptLanguage(String code) {
    transcriptLanguage = code;
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setSttProvider(SttProvider p) {
    if (sttProvider == p) return;
    // Tear down live stream when switching backends mid-session.
    unawaited(_finishStreamStt());
    sttProvider = p;
    _preferStreamStt = true;
    transcriptError = null;
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setXaiApiKey(String? key) {
    final t = key?.trim();
    _xaiStt.apiKeyOverride = (t == null || t.isEmpty) ? null : t;
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
  String? get xaiApiKeyStored => _xaiStt.apiKeyOverride;
  String? get sonioxApiKeyStored => _sonioxStt.apiKeyOverride;

  bool get sttConfigured {
    switch (sttProvider) {
      case SttProvider.xai:
        return _xaiStt.isConfigured;
      case SttProvider.soniox:
        return _sonioxStt.isConfigured;
    }
  }

  bool get xaiConfigured => _xaiStt.isConfigured;
  bool get sonioxConfigured => _sonioxStt.isConfigured;

  String? get _activeSttApiKey {
    switch (sttProvider) {
      case SttProvider.xai:
        return _xaiStt.apiKey;
      case SttProvider.soniox:
        return _sonioxStt.apiKey;
    }
  }

  void clearTranscript() {
    transcript = '';
    transcriptPartial = null;
    transcriptError = null;
    notifyListeners();
  }

  /// Fresh recording session: clear live draft and STT stream (keep per-file history).
  Future<void> _beginNewLiveTranscriptSession() async {
    transcript = '';
    transcriptPartial = null;
    transcriptError = null;
    _lastSttBytes = 0;
    _lastSttAt = DateTime.fromMillisecondsSinceEpoch(0);
    pcmFramesDecoded = 0;
    streamingSttActive = false;
    _streamSttStarting = false;
    _pendingPcm.clear();
    final session = _sttStream;
    _sttStream = null;
    try {
      await _sttStreamSub?.cancel();
    } catch (_) {}
    _sttStreamSub = null;
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

  /// Transcribe a finished local export (manual).
  Future<void> transcribeLocalFile(String path) async {
    if (!sttConfigured) {
      transcriptError =
          '未配置 ${sttProvider.envKeyName}（export ${sttProvider.envKeyName}=…）';
      notifyListeners();
      return;
    }
    transcribing = true;
    transcriptError = null;
    notifyListeners();
    try {
      final r = await _transcribePath(path);
      transcript = r.text;
      transcriptPartial = null;
      if (r.text.trim().isNotEmpty) {
        rememberTranscript(path, r.text);
      }
      statusMessage =
          '转写完成（${sttProvider.label} · ${r.durationSec?.toStringAsFixed(1) ?? "?"}s）';
    } catch (e) {
      transcriptError = '$e';
    } finally {
      transcribing = false;
      notifyListeners();
    }
  }

  Future<SttResult> _transcribePath(String path) {
    switch (sttProvider) {
      case SttProvider.xai:
        return _xaiStt.transcribePath(path, language: _sttLanguageParam);
      case SttProvider.soniox:
        return _sonioxStt.transcribePath(
          path,
          language: transcriptLanguage.toLowerCase(),
        );
    }
  }

  String? get _sttLanguageParam {
    // xAI format=true requires a supported code; zh not listed — omit format.
    const supported = {
      'ar',
      'cs',
      'da',
      'nl',
      'en',
      'fil',
      'fr',
      'de',
      'hi',
      'id',
      'it',
      'ja',
      'ko',
      'mk',
      'ms',
      'fa',
      'pl',
      'pt',
      'ro',
      'ru',
      'es',
      'sv',
      'th',
      'tr',
      'vi',
    };
    final c = transcriptLanguage.toLowerCase();
    if (supported.contains(c)) return c;
    // Chinese / others: still send file without format flag (model detects speech).
    return null;
  }

  List<String> get _sonioxLanguageHints {
    final c = transcriptLanguage.toLowerCase();
    if (c == 'zh' || c.startsWith('zh')) return const ['zh', 'en'];
    if (c.isEmpty) return const ['zh', 'en'];
    return [c, 'en'];
  }

  Future<void> _maybeTranscribeRolling(
    String path,
    int bytes, {
    required bool finalPass,
  }) async {
    if (!sttConfigured || !autoTranscribe) return;
    if (transcribing && !finalPass) return;
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
      if (r.text.isNotEmpty) {
        if (finalPass) {
          transcript = r.text;
          transcriptPartial = null;
          rememberTranscript(path, r.text);
        } else {
          // Keep growing draft; prefer longer / newer full-file STT.
          transcriptPartial = r.text;
          if (r.text.length >= transcript.length) {
            transcript = r.text;
          }
          rememberTranscript(path, r.text);
        }
      }
    } catch (e) {
      // Soft-fail during rolling; surface message.
      transcriptError = '$e';
      debugPrint('[STT] rolling failed: $e');
    } finally {
      transcribing = false;
      notifyListeners();
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

  /// Active STT backend (xAI or Soniox).
  SttProvider sttProvider = SttProvider.soniox;
  String transcriptLanguage =
      'zh'; // formatting hint; zh may fall back if unsupported
  String transcript = '';
  String? transcriptPartial;
  bool transcribing = false;
  String? transcriptError;

  /// Live streaming STT session active after Opus→PCM decode.
  bool streamingSttActive = false;

  /// Decoded Opus frames in the current session (diagnostics).
  int pcmFramesDecoded = 0;
  final XaiSttService _xaiStt = XaiSttService();
  final SonioxSttService _sonioxStt = SonioxSttService();
  final OpusPcmDecoder _opusPcm = OpusPcmDecoder(outputSampleRate: 16000);
  SttStreamSession? _sttStream;
  StreamSubscription? _sttStreamSub;
  bool _streamSttStarting = false;

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

  /// fileId → local path after Wi‑Fi export.
  final Map<int, String> localPathsByFileId = {};

  /// path → last STT text for that local export.
  final Map<String, String> transcriptsByPath = {};

  /// fileId → STT text (device list + local).
  final Map<int, String> transcriptsByFileId = {};
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
      ..addAll(files.map((f) => f.fileId));
    selecting = true;
    notifyListeners();
  }

  void clearSelection() {
    selectedFileIds.clear();
    notifyListeners();
  }

  /// Select a single file and enter selection mode (for one-tap export).
  void selectOnly(int fileId) {
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
    errorMessage = null;
    phase = AppPhase.scanning;
    statusMessage = '正在检查蓝牙…';
    notifyListeners();
    try {
      await _ble.startScan(timeout: const Duration(seconds: 30));
      statusMessage = '正在扫描 soundcore Work（D3200）…';
      notifyListeners();
    } catch (e) {
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
    await _ble.stopScan();
    if (!connected) phase = AppPhase.idle;
    statusMessage = devices.isEmpty && adsSeen > 0
        ? '已见 $adsSeen 条 BLE 广播，无匹配 D3200 — 请重启录音豆后重试'
        : null;
    notifyListeners();
  }

  Future<void> connect(ScannedDevice d) async {
    // Single-flight: ignore extra taps while connecting (or BLE layer busy).
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      statusMessage = '正在连接，请稍候…';
      notifyListeners();
      return;
    }

    errorMessage = null;
    activeDevice = d;
    phase = AppPhase.connecting;
    statusMessage = '正在连接 ${d.displayName}…';
    connected = false;
    notifyListeners();
    try {
      await _ble.connect(d.id, serviceUuidHint: d.serviceUuid);
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
      _startBatteryPoll();
      // Home may already be visible before an iOS connection completes, so its
      // initial tab refresh has already returned while disconnected. Always
      // request the device inventory once the GATT session is fully ready.
      await listFiles();
      // If the bean is already recording, start BLE realtime pull automatically.
      if (recording || info?.recording == true) {
        await _maybeStartAutoRealtime(reason: 'connected');
      }
    } catch (e) {
      // Prefer cleaned message from BleService / strip noisy prefixes.
      errorMessage = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError|TimeoutException):\s*'),
        '',
      );
      phase = AppPhase.idle;
      statusMessage = null;
      // Keep lastKnownDevice if we had one from a prior session.
      activeDevice = lastKnownDevice;
      connected = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _explicitDisconnect = true;
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
    _recordWireStatus = 0;
    encryptReady = false;
    _crypto.resetSession();
    phase = AppPhase.idle;
    statusMessage = null;
    connected = false;
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
    statusMessage = '加密握手中…';
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
      statusMessage = ok ? '加密会话就绪' : '加密握手失败（导出可能为密文）';
      phase = AppPhase.ready;
      notifyListeners();
      return ok;
    } on TimeoutException {
      encryptReady = false;
      errorMessage = '加密握手超时';
      statusMessage = '加密超时 — 导出可能仍为密文';
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

  Future<void> _send(List<int> frame, {String? label}) async {
    if (!_ble.isConnected) {
      errorMessage = '未连接';
      notifyListeners();
      return;
    }
    phase = AppPhase.busy;
    if (label != null) statusMessage = label;
    notifyListeners();
    try {
      await _ble.writeCommand(frame);
      // A command just went through — any earlier error (e.g. a stale
      // "未连接" from a command that raced a disconnect) is no longer true.
      errorMessage = null;
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
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
    await _yieldBacklogToCurrentRecording();
    await _send(DeviceCommands.startRecord(), label: '正在开始录音…');
    // Optimistic; device will confirm via 0x18/0x82 or 1A06.
    _applyRecordStatus(1, source: 'app_start');
  }

  Future<void> pauseRecord() async {
    await _send(DeviceCommands.pauseRecord(), label: '正在暂停录音…');
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
      if (prevWire == 0 || source == 'app_start') {
        unawaited(_beginNewLiveTranscriptSession());
      }
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
      final label = status == 2 ? '已暂停' : '已停止录音';
      if (durationSec != null && durationSec > 0) {
        statusMessage = '$label（${durationSec}s）';
      } else {
        statusMessage = label;
      }
      if (wasRecording || realtimeState.active) {
        _realtime.onRecordingStopped();
      }
      // End-of-utterance hint for live STT; full finish comes with realtime settle.
      try {
        _sttStream?.finalizeUtterance();
      } catch (_) {}
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
        statusMessage = '实时传输：尚未解析到录音 id，将在 1A06 时自动开始';
        notifyListeners();
      }
      return;
    }

    if (realtimeState.active && realtimeState.fileId == fileId) return;

    unawaited(() async {
      try {
        await _startCurrentRecordingTransfer(fileId!);
        statusMessage = '实时传输中 · 文件 $fileId（BLE，无需 SoftAP）';
        notifyListeners();
      } catch (e) {
        errorMessage = '实时传输启动失败：$e';
        notifyListeners();
      }
    }());
  }

  Future<void> _startCurrentRecordingTransfer(int fileId) async {
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
              notifyListeners();
            });
          } catch (error) {
            _loadingFileListPages = false;
            errorMessage = '获取录音列表第 ${_fileListPage + 1} 页失败：$error';
            notifyListeners();
          }
        }),
      );
      return;
    }

    _loadingFileListPages = false;
    statusMessage = '${files.length} 条录音';
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
    if (!connected || !_ble.isConnected) {
      errorMessage = '请先通过 BLE 连接';
      notifyListeners();
      return;
    }
    if (isWifiExportSession || isExporting) return;
    if (phase == AppPhase.connecting || phase == AppPhase.busy) return;

    await _yieldBacklogToCurrentRecording();
    if (!encryptReady) await establishEncryptSession();
    if (!connected || !_ble.isConnected) return;

    phase = AppPhase.busy;
    errorMessage = null;
    statusMessage = '正在下载 ${file.title}…';
    notifyListeners();
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
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
      errorMessage = '下载失败：$e';
      statusMessage = '下载失败';
    } finally {
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
        if (RegExp(r'^\d+\.(?:wav|opus(?:\.bin)?)$').hasMatch(name)) {
          paths.add(entity.path);
        }
      }
      _registerExportedPaths([...exportedPaths, ...paths]);
      if (notify) notifyListeners();
    } catch (error) {
      debugPrint('[Exports] load local catalog failed: $error');
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
      return (audios: 0, transcripts: 0, failed: ['$destinationPath: $e']);
    }

    for (final path in paths.toSet()) {
      final source = File(path);
      final name = p.basename(path);
      try {
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
        failed.add('$name: $e');
      }
    }

    statusMessage = failed.isEmpty
        ? '已另存 $audios 个录音、$transcripts 份转写'
        : '另存完成：$audios 个录音，${failed.length} 个失败';
    errorMessage = failed.isEmpty ? null : failed.join('\n');
    notifyListeners();
    return (audios: audios, transcripts: transcripts, failed: failed);
  }

  Future<({int deleted, List<String> failed})> deleteLocalExports(
    Iterable<String> paths,
  ) async {
    final selected = paths.toSet();
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
        if (playingPath == path || (id != null && playingFileId == id)) {
          await stopPlayback();
        }
        for (final candidate in logicalPaths) {
          final file = File(candidate);
          if (await file.exists()) await file.delete();
          transcriptsByPath.remove(candidate);
        }
        if (id != null) transcriptsByFileId.remove(id);
        deleted++;
      } catch (error) {
        failed.add('${p.basename(path)}: $error');
      }
    }

    exportedPaths.removeWhere((path) {
      final id = ExportCatalog.fileIdFromPath(path);
      return selected.contains(path) ||
          (id != null &&
              selected.any((item) => ExportCatalog.fileIdFromPath(item) == id));
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
  }

  Future<String> _convertExportToWav(
    String path, {
    bool register = true,
  }) async {
    if (!path.endsWith('.opus')) return path;
    try {
      final wavPath = await OpusWave.convertRawFile(path);
      if (register) {
        _registerExportedPaths([wavPath]);
        notifyListeners();
      }
      return wavPath;
    } catch (error) {
      debugPrint('[Exports] WAV conversion failed for $path: $error');
      return path;
    }
  }

  Future<void> deleteFile(int fileId) =>
      _send(DeviceCommands.deleteFile(fileId), label: '正在删除文件…');

  Future<int> deleteSelectedDeviceFiles() async {
    if (!_ble.isConnected || selectedFileIds.isEmpty) return 0;
    final ids = selectedFileIds.toList();
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
      errorMessage = '批量删除失败：$error';
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

  /// Unbind is the inverse of bind (same cmd 0x0B/0x87, payload 0x00).
  /// Safe: does not factory-reset or wipe recordings. Feishu disconnects BLE
  /// after a successful unbind ACK; you can scan + connect + bind again.
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
    _wifiExportRun++;
    if (!_ble.isConnected) {
      errorMessage = '请先通过 BLE 连接';
      notifyListeners();
      return null;
    }
    final targets = selectedFileIds.isNotEmpty
        ? selectedUnexportedFiles
        : unexportedFiles;
    if (targets.isEmpty) {
      errorMessage = selectedFileIds.isNotEmpty ? '所选录音均已导出' : '所有录音均已导出';
      notifyListeners();
      return null;
    }
    _pendingExportTargets = List.of(targets);

    errorMessage = null;
    phase = AppPhase.busy;
    statusMessage = '正在准备解密会话…';
    notifyListeners();

    // Ensure ECDH session before SoftAP so file keys can be unwrapped.
    if (!encryptReady) {
      final ok = await establishEncryptSession();
      if (!ok) {
        statusMessage = '无解密会话，继续导出…';
        notifyListeners();
      }
    }

    statusMessage = '正在开启 Wi‑Fi SoftAP…';
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
      statusMessage = '请加入 SoftAP「${ep.ssid}」，然后点「继续导出」';
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
      const msg = '无 SoftAP 端点 — 请重新开始导出';
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
      for (final path in rawPaths) {
        paths.add(await _convertExportToWav(path, register: false));
      }
      _registerExportedPaths(paths);
      _pendingExportTargets = [];
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = paths.isEmpty
          ? '导出完成但无数据'
          : '已导出 ${paths.length} 个文件'
                '${encryptReady ? "（已解密）" : "（原始密文 — 无会话）"}';
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
    try {
      final file = File(path);
      if (!await file.exists()) {
        errorMessage = '本地文件不存在：$path';
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
      errorMessage = '播放失败：$e\n（设备导出为裸 Opus 帧，需封装为 Ogg；若仍失败请确认已解密）';
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
      errorMessage = '播放控制失败：$e';
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
      errorMessage = '跳转失败：$e';
      notifyListeners();
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeed = speed;
    try {
      await _player.setSpeed(speed);
    } catch (e) {
      errorMessage = '倍速设置失败：$e';
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
        statusMessage = '电量 · 麦克风 $mic% · 充电盒 $box%（原始 $micRaw/$boxRaw）';
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
            errorMessage = '设备拒绝解绑（flag=${p.successFlag}）';
          }
        } else {
          // Bind ACK (or unknown — treat as bind)
          if (ok) {
            bound = true;
            if (activeDevice != null) lastKnownDevice = activeDevice;
            unawaited(_persistDevice());
            statusMessage = '绑定指令已接受，等待设备确认…';
            _schedulePostBindFileRefresh();
          } else {
            statusMessage = '绑定失败';
            errorMessage = '设备拒绝绑定（flag=${p.successFlag}）';
          }
        }
      } else if (p.cmdId == RxCmd.bindConfirmId) {
        if (p.isSuccess) {
          bound = true;
          if (activeDevice != null) lastKnownDevice = activeDevice;
          unawaited(_persistDevice());
          statusMessage = '已绑定（设备已确认）';
          _schedulePostBindFileRefresh();
        } else {
          statusMessage = '绑定确认失败';
          errorMessage = '设备确认绑定失败（flag=${p.successFlag}）';
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
  void dispose() {
    _postBindFileRefreshTimer?.cancel();
    _fileListPageTimeout?.cancel();
    _stopBatteryPoll();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_sttStreamSub?.cancel());
    unawaited(_sttStream?.dispose());
    _opusPcm.dispose();
    unawaited(_player.dispose());
    unawaited(_realtime.dispose());
    _xaiStt.dispose();
    _sonioxStt.dispose();
    _wifi.dispose();
    _ble.dispose();
    super.dispose();
  }
}
