import 'dart:async';

import 'package:anker_recorder/ai/apple_speech.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('soundcore/apple_speech');
  const events = MethodChannel('soundcore/apple_speech/events');
  final calls = <MethodCall>[];
  late AppleSpeechService service;
  Future<Object?> Function(MethodCall)? handler;

  Future<void> emit(Map<String, Object?> event) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    handler = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return handler?.call(call);
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    service = AppleSpeechService();
  });

  tearDown(() async {
    await service.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('unsupported platforms do not invoke any processing bridge', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect((await service.capabilities()).supported, isFalse);
    await expectLater(
      service.transcribePath('/saved.wav', sourceLanguage: 'en-US'),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'unsupported'),
      ),
    );
    expect(calls, isEmpty);
  });

  test('missing iOS bridge safely reports unsupported', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    expect((await service.capabilities()).supported, isFalse);
  });

  test(
    'capability reads never implicitly prepare or select a language',
    () async {
      handler = (call) async => {
        'supported': true,
        'speechStatus': 'needsDownload',
        'translationStatus': 'ready',
        'speechLanguages': [
          {'code': 'en-US', 'name': 'English (US)'},
        ],
        'translationLanguages': [
          {'code': 'zh-Hans', 'name': '简体中文'},
        ],
        'suggestedSourceLanguage': 'en-US',
      };
      final capability = await service.capabilities(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      expect(capability.speechStatus, SpeechResourceStatus.needsDownload);
      expect(capability.translationStatus, SpeechResourceStatus.ready);
      expect(capability.speechLanguages.single.code, 'en-US');
      expect(capability.suggestedSourceLanguage, 'en-US');
      expect(calls.map((call) => call.method), ['capabilities']);
      await service.prepareLanguages(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      expect(calls.last.method, 'prepareLanguages');
      expect(calls.last.arguments, containsPair('sourceLanguage', 'en-US'));
      expect(calls.last.arguments, containsPair('targetLanguage', 'zh-Hans'));
      expect(calls.last.arguments['jobId'], isA<String>());
    },
  );

  test(
    'saved translation preparation does not invoke speech preparation',
    () async {
      await service.prepareTranslation(
        sourceLanguage: 'pl',
        targetLanguage: 'zh-Hans',
      );
      expect(calls.map((call) => call.method), ['prepareTranslation']);
      expect(calls.single.arguments, containsPair('sourceLanguage', 'pl'));
      expect(calls.single.arguments, containsPair('targetLanguage', 'zh-Hans'));
      expect(calls.single.arguments['jobId'], isA<String>());
      handler = (_) async => throw PlatformException(code: 'cancelled');
      await expectLater(
        service.prepareTranslation(
          sourceLanguage: 'pl',
          targetLanguage: 'zh-Hans',
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(calls.any((call) => call.method == 'prepareLanguages'), isFalse);
    },
  );

  for (final prepareSpeech in [true, false]) {
    test(
      'live stream cancels ${prepareSpeech ? 'speech' : 'translation'} preparation and rejects its late result',
      () async {
        final prepared = Completer<Object?>();
        handler = (call) async =>
            call.method.startsWith('prepare') ? prepared.future : null;
        final preparation = prepareSpeech
            ? service.prepareLanguages(sourceLanguage: 'en-US')
            : service.prepareTranslation(
                sourceLanguage: 'pl',
                targetLanguage: 'zh-Hans',
              );
        final rejected = expectLater(
          preparation,
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final preparationID = calls.single.arguments['jobId'];
        final session = service.createStreamSession(sourceLanguage: 'en-US');
        await session.start();
        expect(calls[1].method, 'cancelFile');
        expect(calls[1].arguments['jobId'], preparationID);
        expect(calls[2].method, 'startStream');
        prepared.complete(null);
        await rejected;
        expect(session.isServerReady, isTrue);
        await session.dispose();
      },
    );
  }

  test(
    'explicit cancellation includes preparation without a transcription job',
    () async {
      final prepared = Completer<Object?>();
      handler = (call) async =>
          call.method == 'prepareTranslation' ? prepared.future : null;
      final preparation = service.prepareTranslation(
        sourceLanguage: 'pl',
        targetLanguage: 'zh-Hans',
      );
      final rejected = expectLater(
        preparation,
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await service.cancelFileProcessing();
      expect(calls.last.method, 'cancelFile');
      expect(calls.last.arguments['jobId'], calls.first.arguments['jobId']);
      prepared.complete(null);
      await rejected;
    },
  );

  test(
    'graceful finish keeps late finalized translation before closing',
    () async {
      final completed = Completer<Object?>();
      handler = (call) async =>
          call.method == 'finishStream' ? completed.future : null;
      final session = service.createStreamSession(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      await session.start();
      final id = calls.last.arguments['sessionId'];
      final finishing = session.finish();
      await Future<void>.delayed(Duration.zero);
      final finalized = {
        'sessionId': id,
        'type': 'partial',
        'text': 'Last words.',
        'isFinal': true,
        'translationTurns': [
          {
            'sourceLanguage': 'en-US',
            'targetLanguage': 'zh-Hans',
            'sourceText': 'Last words.',
            'text': '最后的话。',
            'isFinal': true,
          },
        ],
      };
      await emit(finalized);
      expect(calls.any((call) => call.method == 'closeStream'), isFalse);
      completed.complete({...finalized, 'type': 'done'});
      final result = await finishing;
      expect(result?.text, 'Last words.');
      expect(result?.translationTurns.single.text, '最后的话。');
      expect(calls.last.method, 'closeStream');
      await session.dispose();
    },
  );

  test(
    'finish timeout closes native work and ignores late translations',
    () async {
      final completed = Completer<Object?>();
      handler = (call) async =>
          call.method == 'finishStream' ? completed.future : null;
      final session = service.createStreamSession(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      final received = <SttStreamEvent>[];
      final subscription = session.events.listen(received.add);
      await session.start();
      final id = calls.last.arguments['sessionId'];
      await emit({'sessionId': id, 'type': 'partial', 'text': 'Kept source.'});
      await expectLater(
        session.finish(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls.last.method, 'closeStream');
      await emit({'sessionId': id, 'type': 'partial', 'text': 'late'});
      completed.complete({'type': 'done', 'text': 'late'});
      await Future<void>.delayed(Duration.zero);
      expect(received.map((event) => event.text), ['Kept source.']);
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'cancelled file output is rejected and a new job has its own ID',
    () async {
      final result = Completer<Object?>();
      handler = (call) async =>
          call.method == 'transcribeFile' ? result.future : null;
      final first = service.transcribePath(
        '/saved.wav',
        sourceLanguage: 'en-US',
      );
      final failed = expectLater(
        first,
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final firstID = calls.single.arguments['jobId'];
      await expectLater(
        service.translate('hello', sourceLanguage: 'en', targetLanguage: 'zh'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'busy')),
      );
      await service.cancelFileProcessing();
      result.complete({'text': 'late result'});
      await failed;
      handler = (call) async => '你好';
      expect(
        await service.translate(
          'hello',
          sourceLanguage: 'en',
          targetLanguage: 'zh',
        ),
        '你好',
      );
      expect(calls.last.arguments['jobId'], isNot(firstID));
      expect(calls.map((call) => call.method), [
        'transcribeFile',
        'cancelFile',
        'translate',
      ]);
    },
  );

  test(
    'stream filters old sessions and keeps source after translation errors',
    () async {
      final session = service.createStreamSession(
        sourceLanguage: 'en-US',
        targetLanguage: 'zh-Hans',
      );
      final received = <SttStreamEvent>[];
      final subscription = session.events.listen(received.add);
      await session.start();
      final id = calls.last.arguments['sessionId'];
      await emit({
        'sessionId': 'old',
        'type': 'partial',
        'text': 'old recording',
      });
      await emit({'sessionId': id, 'type': 'partial', 'text': 'current words'});
      await emit({
        'sessionId': id,
        'type': 'translationError',
        'text': 'current words',
        'error': 'resources_missing',
      });
      expect(received.map((event) => event.text), [
        'current words',
        'current words',
      ]);
      expect(session.isServerReady, isTrue);
      await session.close();
      await emit({'sessionId': id, 'type': 'partial', 'text': 'too late'});
      expect(received, hasLength(2));
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'finish drains accepted PCM before finalizing and emits done once',
    () async {
      final firstPacket = Completer<Object?>();
      var pcmCount = 0;
      handler = (call) async {
        if (call.method == 'appendPcm' && pcmCount++ == 0) {
          return firstPacket.future;
        }
        if (call.method == 'finishStream') {
          return {'type': 'done', 'text': 'final', 'isFinal': true};
        }
        return null;
      };
      final session = service.createStreamSession(sourceLanguage: 'en-US');
      final received = <SttStreamEvent>[];
      final subscription = session.events.listen(received.add);
      await session.start();
      session.sendPcm(Uint8List.fromList([1, 2]));
      session.sendPcm(Uint8List.fromList([3, 4]));
      final finish = session.finish();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['startStream', 'appendPcm']);
      firstPacket.complete(null);
      expect((await finish)?.text, 'final');
      expect(calls.map((c) => c.method), [
        'startStream',
        'appendPcm',
        'appendPcm',
        'finishStream',
        'closeStream',
      ]);
      expect(received.where((event) => event.type == 'done'), hasLength(1));
      await subscription.cancel();
      await session.dispose();
    },
  );
}
