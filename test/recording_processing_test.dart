import 'dart:async';
import 'support/moss_fakes.dart';
import 'package:anker_recorder/ai/moss_stt.dart';
import 'package:anker_recorder/state/moss_jobs.dart';
import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:anker_recorder/ai/apple_speech.dart';
import 'package:anker_recorder/ai/soniox_stt.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/ble/ble_service.dart';
import 'package:anker_recorder/ble/realtime_stream.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RecorderController controller(_Apple apple, {_Ble? ble, _Soniox? soniox}) {
    final result =
        RecorderController(
            loadPersistedState: false,
            ble: ble,
            appleSpeech: apple,
            sonioxSpeech: soniox,
          )
          ..speechProvider = SttProvider.apple
          ..appleSourceLanguage = 'en-US';
    addTearDown(() async {
      result.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    return result;
  }

  test(
    'MOSS manual transcription retains provider and permits Apple translation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'moss-controller-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/201.wav');
      await file.writeAsBytes([1, 2, 3]);
      final moss = FakeMoss()..apiKeyOverride = 'moss-key';
      final apple = _Apple();
      final soniox = _Soniox();
      final c = RecorderController(
        loadPersistedState: false,
        mossSpeech: moss,
        appleSpeech: apple,
        sonioxSpeech: soniox,
      )..speechProvider = SttProvider.moss;
      addTearDown(c.dispose);
      await c.transcribeLocalFile(file.path);
      final ref = RecordingReference(path: file.path);
      expect(c.recordingView(ref).text, 'Transcript');
      expect(c.recordingView(ref).provider, SttProvider.moss);
      expect(soniox.fileCalls, 0);
      await c.translateRecording(ref, sourceLanguage: 'en-US');
      expect(c.recordingView(ref).translation?.text, '译文');
      moss.response = {'status': 'FAILED'};
      await c.transcribeLocalFile(file.path);
      expect(c.recordingView(ref).text, 'Transcript');
      expect(c.recordingView(ref).translation?.text, '译文');
    },
  );

  test(
    'MOSS auto transcription waits for stop, deduplicates completion, and snapshots provider',
    () async {
      final directory = await Directory.systemTemp.createTemp('moss-stop-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/202.wav');
      await file.writeAsBytes([1, 2, 3]);
      final moss = FakeMoss()..apiKeyOverride = 'initial-key';
      final ble = _Ble();
      final c = RecorderController(
        loadPersistedState: false,
        ble: ble,
        mossSpeech: moss,
        appleSpeech: _Apple(),
      )..speechProvider = SttProvider.moss;
      addTearDown(c.dispose);
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: 202,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      expect(moss.uploads, 0);
      c.setSpeechProvider(SttProvider.apple);
      moss.apiKeyOverride = 'new-key';
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      final stopped = RealtimeStreamState(
        fileId: 202,
        path: file.path,
        bytesReceived: 320,
      );
      c.handleRealtimeStateForTesting(stopped);
      c.handleRealtimeStateForTesting(stopped);
      await settleUntil(() => moss.deletes == 1);
      expect(moss.uploads, 1);
      expect(moss.keys, everyElement('initial-key'));
      expect(c.pcmFramesDecoded, 0);
      expect(c.streamingSttActive, isFalse);
      expect(
        c.recordingView(RecordingReference(path: file.path)).provider,
        SttProvider.moss,
      );
    },
  );

  test('MOSS paused take is not submitted until a full stop', () async {
    final directory = await Directory.systemTemp.createTemp('moss-pause-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/203.wav');
    await file.writeAsBytes([1, 2, 3]);
    final moss = FakeMoss()..apiKeyOverride = 'key';
    final ble = _Ble();
    final c = RecorderController(
      loadPersistedState: false,
      ble: ble,
      mossSpeech: moss,
      appleSpeech: _Apple(),
    )..speechProvider = SttProvider.moss;
    addTearDown(c.dispose);
    await c.startRecord();
    c.handleRealtimeStateForTesting(
      RealtimeStreamState(
        active: true,
        fileId: 203,
        path: file.path,
        bytesReceived: 320,
      ),
    );
    await c.pauseRecord();
    c.handleRealtimeStateForTesting(
      RealtimeStreamState(fileId: 203, path: file.path, bytesReceived: 320),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(moss.uploads, 0);
    c.setSpeechProvider(SttProvider.apple);
    final pausedRef = c.currentRecordingReference!;
    await c.startRecord();
    expect(c.currentRecordingReference!.sessionId, pausedRef.sessionId);
    expect(c.recordingView(pausedRef).provider, SttProvider.moss);
    expect(moss.uploads, 0);
    ble.stopRecording();
    await settleUntil(() => moss.deletes == 1);
    expect(moss.uploads, 1);
  });

  test(
    'MOSS result survives a new recording and belongs to the original take',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'moss-concurrent-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/204.wav');
      await file.writeAsBytes([1, 2, 3]);
      final moss = FakeMoss()
        ..apiKeyOverride = 'key'
        ..pendingTask = Completer();
      final c = RecorderController(
        loadPersistedState: false,
        ble: _Ble(),
        mossSpeech: moss,
        appleSpeech: _Apple(),
      )..speechProvider = SttProvider.moss;
      addTearDown(c.dispose);
      final work = c.transcribeLocalFile(file.path);
      await settleUntil(() => moss.polls == 1);
      await c.startRecord();
      final newTake = c.currentRecordingReference!;
      moss.pendingTask!.complete({
        'status': 'SUCCESS',
        'text': 'Original take',
      });
      await work;
      expect(
        c.recordingView(RecordingReference(path: file.path)).text,
        'Original take',
      );
      expect(c.recordingView(newTake).text, isEmpty);
    },
  );

  test('MOSS recovery loads existing task with no new upload', () async {
    final directory = await Directory.systemTemp.createTemp('moss-resume-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/205.wav');
    await file.writeAsBytes([1, 2, 3]);
    final store = MossJobStore(inMemory: true);
    await store.save([
      MossJob(
        id: 'saved',
        recordingKey: 'file:205',
        path: file.path,
        stage: MossJobStage.polling,
        fileId: 'file',
        taskId: 'task',
      ),
    ]);
    final moss = FakeMoss()..apiKeyOverride = 'key';
    final c = RecorderController(
      loadPersistedState: false,
      mossSpeech: moss,
      mossJobStore: store,
      appleSpeech: _Apple(),
    )..speechProvider = SttProvider.moss;
    addTearDown(c.dispose);
    await c.transcribeLocalFile(file.path);
    await settleUntil(() => moss.deletes == 1);
    expect(moss.uploads, 0);
    expect(
      c.recordingView(RecordingReference(path: file.path)).text,
      'Transcript',
    );
  });

  test(
    'MOSS validation failure preserves saved credentials and modes are transcription only',
    () async {
      final moss = FakeMoss()..apiKeyOverride = 'previous';
      final c = RecorderController(
        loadPersistedState: false,
        mossSpeech: moss,
        appleSpeech: _Apple(),
      )..sttMode = SttDisplayMode.conversation;
      addTearDown(c.dispose);
      c.setSpeechProvider(SttProvider.moss);
      expect(c.sttMode, SttDisplayMode.transcription);
      c.setSttMode(SttDisplayMode.translation);
      expect(c.sttMode, SttDisplayMode.transcription);
      moss.validationError = const MossException('credentials');
      await expectLater(
        c.validateAndSaveMossApiKey('bad'),
        throwsA(isA<MossException>()),
      );
      expect(c.mossApiKeyStored, 'previous');
      moss.validationError = null;
      await c.validateAndSaveMossApiKey('valid');
      expect(c.mossApiKeyStored, 'valid');
    },
  );

  test('provider defaults preserve explicit choices and configured cloud', () {
    expect(
      initialSpeechProvider(
        saved: null,
        appleSupported: true,
        sonioxConfigured: false,
      ),
      SttProvider.apple,
    );
    expect(
      initialSpeechProvider(
        saved: null,
        appleSupported: true,
        sonioxConfigured: true,
      ),
      SttProvider.soniox,
    );
    expect(
      initialSpeechProvider(
        saved: SttProvider.soniox,
        appleSupported: true,
        sonioxConfigured: false,
      ),
      SttProvider.soniox,
    );
    expect(
      initialSpeechProvider(
        saved: SttProvider.apple,
        appleSupported: false,
        sonioxConfigured: true,
      ),
      SttProvider.apple,
    );
  });

  test(
    'device refresh waits for the final inventory page and coalesces pulls',
    () async {
      final ble = _Ble();
      final c = controller(_Apple(), ble: ble)
        ..connected = true
        ..autoRealtime = false;
      var completed = false;
      final refresh = c.refreshDeviceFiles().then((_) => completed = true);
      final repeated = c.refreshDeviceFiles();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      ble.filePage(List.generate(10, (i) => 100 + i));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(c.files, hasLength(10));
      expect(completed, isFalse);
      ble.filePage([110]);
      await refresh.timeout(const Duration(seconds: 1));
      await repeated;
      expect(c.files, hasLength(11));
    },
  );

  testWidgets('device refresh times out without removing existing recordings', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false, ble: _Ble())
      ..connected = true
      ..autoRealtime = false
      ..files = [OfflineFileEntry(fileId: 100, sizeBytes: 160)];
    addTearDown(c.dispose);
    final refresh = c.refreshDeviceFiles();
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await refresh;
    expect(c.errorMessage, '刷新超时，请下拉重试');
    expect(c.files.single.fileId, 100);
  });

  test('suggested source is checked before exposing Apple readiness', () async {
    final apple = _Apple();
    final c = controller(apple)..appleSourceLanguage = '';
    await c.refreshAppleCapabilities();
    expect(apple.queries, [null, 'en-US']);
    expect(c.appleSourceLanguage, 'en-US');
    expect(c.sttConfigured, isTrue);
    c.setSttMode(SttDisplayMode.conversation);
    expect(c.conversationModeAvailable, isFalse);
    expect(c.sttMode, SttDisplayMode.transcription);
  });

  test('Apple file failure preserves text and never calls Soniox', () async {
    final apple = _Apple()
      ..failure = PlatformException(code: 'resources_missing');
    final soniox = _Soniox();
    final c = controller(apple, soniox: soniox);
    await c.refreshAppleCapabilities();
    const ref = RecordingReference(path: '/tmp/123.wav');
    c.rememberTranscript(ref.path!, 'Existing transcript');
    await c.transcribeRecording(ref);
    expect(c.recordingView(ref).text, 'Existing transcript');
    expect(c.recordingView(ref).error, contains('下载'));
    expect(apple.fileCalls, 1);
    expect(soniox.fileCalls, 0);
  });

  test('saved-file transcription does not replace the live draft', () async {
    final apple = _Apple();
    final c = controller(apple)..transcript = 'Unrelated draft';
    await c.refreshAppleCapabilities();
    const ref = RecordingReference(path: '/tmp/124.wav');
    await c.transcribeRecording(ref);
    expect(c.transcript, 'Unrelated draft');
    expect(c.recordingView(ref).text, 'Apple result');
    expect(c.recordingView(ref).provider, SttProvider.apple);
    expect(c.recordingView(ref).sourceLanguage, 'en-US');
  });

  test(
    'recording language overrides an unavailable global language and is remembered',
    () async {
      final apple = _Apple()
        ..statuses['en-US'] = SpeechResourceStatus.needsDownload;
      final c = controller(apple);
      await c.refreshAppleCapabilities();
      expect(c.sttConfigured, isFalse);
      const ref = RecordingReference(path: '/tmp/130.wav');
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(apple.fileLanguages, ['zh-CN']);
      expect(c.recordingView(ref).sourceLanguage, 'zh-CN');
      expect(c.appleSourceLanguage, 'en-US');
      expect(c.sttConfigured, isFalse);
      await c.transcribeRecording(ref);
      expect(apple.fileLanguages, ['zh-CN', 'zh-CN']);
    },
  );

  test(
    'only an explicit download action prepares the selected speech language',
    () async {
      final apple = _Apple()
        ..statuses['zh-CN'] = SpeechResourceStatus.needsDownload;
      final c = controller(apple);
      const ref = RecordingReference(path: '/tmp/131.wav');
      c.rememberTranscript(
        ref.path!,
        'Previous result',
        sourceLanguage: 'en-US',
      );
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(apple.preparedLanguages, isEmpty);
      expect(apple.fileCalls, 0);
      expect(c.recordingView(ref).text, 'Previous result');
      await c.transcribeRecording(
        ref,
        sourceLanguage: 'zh-CN',
        prepareLanguages: true,
      );
      expect(apple.preparedLanguages, [('zh-CN', null)]);
      expect(apple.fileLanguages, ['zh-CN']);
      expect(c.appleSourceLanguage, 'en-US');
    },
  );

  test(
    'a failed language change retains the original language and translation',
    () async {
      final apple = _Apple();
      final c = controller(apple);
      const ref = RecordingReference(path: '/tmp/132.wav');
      c.rememberTranscript(ref.path!, 'Apple result', sourceLanguage: 'en-US');
      await c.translateRecording(ref);
      apple.failure = PlatformException(code: 'processing_failed');
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(c.recordingView(ref).sourceLanguage, 'en-US');
      expect(c.recordingView(ref).translation?.text, '译文');
      apple.failure = null;
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(c.recordingView(ref).text, 'Apple result');
      expect(c.recordingView(ref).sourceLanguage, 'zh-CN');
      expect(c.recordingView(ref).translation, isNull);
    },
  );

  test(
    'unsupported recording language never reaches transcription or the cloud',
    () async {
      final apple = _Apple()
        ..statuses['unsupported'] = SpeechResourceStatus.unsupported;
      final soniox = _Soniox();
      final c = controller(apple, soniox: soniox);
      const ref = RecordingReference(path: '/tmp/133.wav');
      await c.transcribeRecording(
        ref,
        sourceLanguage: 'unsupported',
        prepareLanguages: true,
      );
      expect(apple.fileCalls, 0);
      expect(soniox.fileCalls, 0);
      expect(apple.preparedLanguages, isEmpty);
      expect(c.recordingView(ref).error, contains('更换语言'));
    },
  );

  test('late translation cannot attach to a replaced source', () async {
    final pending = Completer<String>();
    final apple = _Apple()..pendingTranslation = pending;
    final c = controller(apple);
    const ref = RecordingReference(path: '/tmp/125.wav');
    c.rememberTranscript(ref.path!, 'First source');
    final translating = c.translateRecording(ref);
    await Future<void>.delayed(Duration.zero);
    c.rememberTranscript(ref.path!, 'Replacement source');
    pending.complete('Old translation');
    await translating;
    expect(c.recordingView(ref).translation, isNull);
    expect(c.recordingView(ref).text, 'Replacement source');
  });

  test('translation survives failed retranscription and file rename', () async {
    final directory = await Directory.systemTemp.createTemp(
      'soundcore-translation-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/126.wav');
    await file.writeAsBytes([1, 2, 3]);
    final apple = _Apple();
    final c = controller(apple)..exportedPaths = [file.path];
    await c.refreshAppleCapabilities();
    final ref = RecordingReference(fileId: 126, path: file.path);
    c.rememberTranscript(file.path, 'Original');
    await c.translateRecording(ref);
    expect(c.recordingView(ref).translation?.text, '译文');
    apple.failure = PlatformException(code: 'processing_failed');
    await c.transcribeRecording(ref);
    expect(c.recordingView(ref).translation?.text, '译文');
    final renamed = await c.renameLocalExport(file.path, 'Interview');
    expect(c.recordingView(ref).path, renamed);
    expect(c.recordingView(ref).translation?.text, '译文');
    c.rememberTranscript(renamed, 'New source');
    expect(c.recordingView(ref).translation, isNull);
  });

  test(
    'Apple live revisions replace partial text and pause rejects late events',
    () async {
      final c = controller(_Apple(), ble: _Ble());
      await c.refreshAppleCapabilities();
      await c.startRecord();
      final ref = c.currentRecordingReference!;
      final stream = _Stream();
      c.attachSttStreamForTesting(stream);
      stream.emit('I scream');
      await Future<void>.delayed(Duration.zero);
      stream.emit('Ice cream');
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).text, 'Ice cream');
      await c.pauseRecord();
      stream.emit('Late callback');
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).text, 'Ice cream');
      expect(c.recordingView(ref).paused, isTrue);
      expect(stream.closed, isTrue);
      await c.startRecord();
      final next = _Stream();
      c.attachSttStreamForTesting(next);
      next.emit('Different take');
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).text, 'Ice cream');
      expect(
        c.recordingView(c.currentRecordingReference!).text,
        'Different take',
      );
    },
  );

  test(
    'provider and language changes take effect only for the next take',
    () async {
      final c = controller(_Apple(), ble: _Ble());
      await c.refreshAppleCapabilities();
      await c.startRecord();
      final ref = c.currentRecordingReference!;
      c.setSpeechProvider(SttProvider.soniox);
      c.setTranscriptLanguage('ja');
      expect(c.recordingView(ref).provider, SttProvider.apple);
      expect(c.recordingView(ref).sourceLanguage, 'en-US');
      await c.pauseRecord();
      await c.startRecord();
      final next = c.recordingView(c.currentRecordingReference!);
      expect(next.provider, SttProvider.soniox);
      expect(next.sourceLanguage, 'ja');
    },
  );

  test(
    'starting recording cancels Apple file work and rejects its result',
    () async {
      final pending = Completer<SttResult>();
      final apple = _Apple()..pendingFile = pending;
      final c = controller(apple, ble: _Ble());
      await c.refreshAppleCapabilities();
      const ref = RecordingReference(path: '/tmp/127.wav');
      c.rememberTranscript(ref.path!, 'Original');
      final processing = c.transcribeRecording(ref);
      await Future<void>.delayed(Duration.zero);
      await c.startRecord();
      pending.complete(const SttResult(text: 'Cancelled result'));
      await processing;
      expect(apple.cancelCalls, 1);
      expect(c.recordingView(ref).text, 'Original');
      expect(c.recordingView(ref).error, contains('重试'));
    },
  );

  test(
    'late Apple recording completion never adopts the next cloud provider',
    () async {
      final ble = _Ble();
      final soniox = _Soniox()..apiKeyOverride = 'configured-test-key';
      final c = controller(_Apple(), ble: ble, soniox: soniox);
      await c.refreshAppleCapabilities();
      await c.startRecord();
      c.setSpeechProvider(SttProvider.soniox);
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      expect(c.recording, isFalse);
      c.handleRealtimeStateForTesting(
        const RealtimeStreamState(
          fileId: 129,
          path: '/tmp/129.wav',
          bytesReceived: 32000,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(soniox.fileCalls, 0);
      expect(
        c.recordingView(c.currentRecordingReference!).provider,
        SttProvider.apple,
      );
    },
  );

  test(
    'active recording cannot be renamed shared or removed from the catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'soundcore-active-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/128.wav');
      await file.writeAsBytes([1, 2, 3]);
      final c = controller(_Apple())
        ..recording = true
        ..realtimeState = RealtimeStreamState(
          active: true,
          fileId: 128,
          path: file.path,
        )
        ..exportedPaths = [file.path];
      expect(() => c.renameLocalExport(file.path, 'Busy'), throwsStateError);
      expect(() => c.prepareLocalSharePaths([file.path]), throwsStateError);
      final deleted = await c.deleteLocalExports([file.path]);
      expect(deleted.deleted, 0);
      expect(c.exportedPaths, [file.path]);
      expect(await file.exists(), isTrue);
    },
  );
}

class _Apple extends AppleSpeechService {
  Object? failure;
  Completer<SttResult>? pendingFile;
  Completer<String>? pendingTranslation;
  final queries = <String?>[];
  final statuses = <String, SpeechResourceStatus>{};
  final fileLanguages = <String>[];
  final preparedLanguages = <(String, String?)>[];
  int fileCalls = 0;
  int cancelCalls = 0;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async {
    queries.add(sourceLanguage);
    return AppleSpeechCapabilities(
      supported: true,
      speechStatus: sourceLanguage == null
          ? SpeechResourceStatus.unsupported
          : statuses[sourceLanguage] ?? SpeechResourceStatus.ready,
      translationStatus: SpeechResourceStatus.ready,
      suggestedSourceLanguage: 'en-US',
    );
  }

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    fileCalls++;
    fileLanguages.add(sourceLanguage);
    if (failure != null) throw failure!;
    return pendingFile?.future ??
        SttResult(text: 'Apple result', language: sourceLanguage);
  }

  @override
  Future<void> prepareLanguages({
    required String sourceLanguage,
    String? targetLanguage,
  }) async {
    preparedLanguages.add((sourceLanguage, targetLanguage));
    statuses[sourceLanguage] = SpeechResourceStatus.ready;
  }

  @override
  Future<String> translate(
    String text, {
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (failure != null) throw failure!;
    return pendingTranslation?.future ?? '译文';
  }

  @override
  Future<void> cancelFileProcessing() async {
    cancelCalls++;
  }
}

class _Soniox extends SonioxSttService {
  int fileCalls = 0;
  @override
  Future<SttResult> transcribePath(
    String path, {
    String? language,
    SttFileProgressCallback? onProgress,
  }) async {
    fileCalls++;
    return const SttResult(text: 'Cloud result');
  }
}

class _Ble extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  void filePage(List<int> ids) {
    final data = ByteData(2 + ids.length * 12)
      ..setUint16(0, ids.length, Endian.little);
    for (var i = 0; i < ids.length; i++) {
      data.setUint32(2 + i * 12, ids[i], Endian.little);
      data.setUint32(6 + i * 12, ids[i] + 5, Endian.little);
      data.setUint32(10 + i * 12, 160, Endian.little);
    }
    _packets.add(
      DecodedPacket(
        raw: Uint8List(0),
        statusByte: 1,
        cmdType: 0x1B,
        cmdId: 0x0E,
        payload: data.buffer.asUint8List(),
      ),
    );
  }

  void stopRecording() => _packets.add(
    DecodedPacket(
      raw: Uint8List(0),
      statusByte: 1,
      cmdType: 0x18,
      cmdId: 0x82,
      payload: Uint8List.fromList([0]),
    ),
  );
  @override
  Stream<DecodedPacket> get packets => _packets.stream;
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {}
  @override
  Future<void> dispose() => _packets.close();
}

class _Stream implements SttStreamSession {
  final _events = StreamController<SttStreamEvent>.broadcast();
  bool closed = false;
  void emit(String text) {
    if (!_events.isClosed) {
      _events.add(SttStreamEvent(type: 'partial', text: text));
    }
  }

  @override
  Stream<SttStreamEvent> get events => _events.stream;
  @override
  bool get isOpen => !closed;
  @override
  bool get isServerReady => !closed;
  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {}
  @override
  void sendPcm(Uint8List pcm16le) {}
  @override
  void finalizeUtterance() {}
  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async => null;
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}
