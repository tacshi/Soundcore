import 'dart:convert';
import 'dart:io';

import 'package:anker_recorder/ai/moss_stt.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'validates candidate credentials and requires Pro model access',
    () async {
      final service = MossSttService(
        client: MockClient((request) async {
          expect(request.url.path, '/v1/models');
          expect(request.headers['Authorization'], 'Bearer candidate');
          return http.Response(
            jsonEncode({
              'data': [
                {'id': MossSttService.model},
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      await service.validateKey('candidate');
      final missing = MossSttService(
        client: MockClient((_) async => http.Response('{"data":[]}', 200)),
      );
      addTearDown(missing.dispose);
      await expectLater(
        missing.validateKey('candidate'),
        throwsA(isA<MossException>().having((e) => e.code, 'code', 'model')),
      );
    },
  );

  test(
    'uploads audio with purpose and progress, submits current API payload',
    () async {
      final directory = await Directory.systemTemp.createTemp('moss-api-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/audio.wav');
      await file.writeAsBytes(List.filled(128, 1));
      final stages = <SttFileProgress>[];
      final service = MossSttService(
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer original-key');
          if (request.url.path.endsWith('/files')) {
            expect(request.body, contains('name="purpose"'));
            expect(request.body, contains('audio'));
            expect(request.body, contains('filename="audio.wav"'));
            return http.Response('{"id":"file-1"}', 200);
          }
          expect(request.url.path, '/v1/audio/transcriptions');
          expect(jsonDecode(request.body), {
            'model': 'moss-transcribe-diarize-pro',
            'file_id': 'file-1',
            'diarize': true,
            'response_format': 'json',
            'async': true,
          });
          return http.Response('{"task_id":"task-1"}', 200);
        }),
      );
      addTearDown(service.dispose);
      expect(await service.prepareAudio(file.path), file.path);
      expect(
        await service.upload(file.path, 'original-key', onProgress: stages.add),
        'file-1',
      );
      expect(stages.last.fraction, 1);
      expect(await service.submit('file-1', 'original-key'), 'task-1');
    },
  );

  test('rejects oversized audio before reading or uploading', () async {
    final directory = await Directory.systemTemp.createTemp('moss-limit-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/large.opus');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(MossSttService.maxUploadBytes + 1);
    await handle.close();
    final service = MossSttService();
    addTearDown(service.dispose);
    await expectLater(
      service.prepareAudio(file.path),
      throwsA(isA<MossException>().having((e) => e.code, 'code', 'too_large')),
    );
  });

  test('speaker segments preserve identity and text fallback', () {
    final service = MossSttService();
    addTearDown(service.dispose);
    final result = service.parse({
      'segments': [
        {'speaker': 'S01', 'text': 'Hello'},
        {'speaker': 'S01', 'text': 'again'},
        {'speaker': 'S02', 'text': 'Hi'},
        {'text': 'Unassigned'},
      ],
    });
    expect(result.text, '说话人 S01：Hello again\n说话人 S02：Hi\nUnassigned');
    expect(extractTranscriptSpeakers(result.text).map((s) => s.id), [
      'S01',
      'S02',
    ]);
    expect(
      service.parse({'segments': [], 'text': 'Fallback'}).text,
      'Fallback',
    );
    expect(
      () => service.parse({'segments': [], 'text': ''}),
      throwsA(isA<MossException>()),
    );
  });

  for (final (status, code) in [
    (401, 'credentials'),
    (402, 'balance'),
    (429, 'rate_limit'),
    (503, 'server'),
  ]) {
    test('maps HTTP $status without exposing server text', () async {
      final service = MossSttService(
        client: MockClient(
          (_) async => http.Response('SECRET_RESPONSE', status),
        ),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.task('task', 'key'),
        throwsA(
          isA<MossException>()
              .having((e) => e.code, 'code', code)
              .having(
                (e) => e.toString(),
                'sanitized',
                isNot(contains('SECRET_RESPONSE')),
              ),
        ),
      );
    });
  }
  test('rejects malformed responses and missing task identifiers', () async {
    for (final body in ['not-json', '[]', '{}']) {
      final service = MossSttService(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.submit('file', 'key'),
        throwsA(isA<MossException>()),
      );
    }
  });
  test('task requests encode IDs and cleanup accepts absent files', () async {
    final service = MossSttService(
      client: MockClient((request) async {
        expect(request.url.path, contains('a%2Fb'));
        if (request.method == 'DELETE') return http.Response('', 404);
        return http.Response('{"status":"SUCCESS","text":"done"}', 200);
      }),
    );
    addTearDown(service.dispose);
    expect((await service.task('a/b', 'key'))['status'], 'SUCCESS');
    await service.deleteFile('a/b', 'key');
  });
}
