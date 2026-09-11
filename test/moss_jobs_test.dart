import 'dart:async';
import 'dart:io';

import 'package:anker_recorder/ai/moss_stt.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/state/moss_jobs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/moss_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeMoss service;
  late MossJobStore store;
  late MossJobQueue queue;
  late List<String> results;
  bool allowed = true;
  MossJobQueue makeQueue({Future<void> Function(MossJob, SttResult)? save}) =>
      MossJobQueue(
        service: service,
        store: store,
        apiKey: () => 'stored-key',
        canStart: () => allowed,
        onResult:
            save ??
            (job, result) async {
              results.add('${job.path}:${result.text}');
            },
        onChanged: () {},
      );
  setUp(() {
    service = FakeMoss();
    store = MossJobStore(inMemory: true);
    results = [];
    allowed = true;
  });
  tearDown(() => queue.dispose());

  test(
    'serial queue deduplicates automatic completion and preserves snapshot key',
    () async {
      service.pendingUpload = Completer<String>();
      queue = makeQueue();
      final first = queue.enqueue('recording-1', '/1.wav', key: 'snapshot-key');
      await settleUntil(() => service.uploads == 1);
      await queue.enqueue('recording-1', '/1.wav');
      final second = queue.enqueue('recording-2', '/2.wav');
      expect(service.uploads, 1);
      service.pendingUpload!.complete('file');
      await first;
      await second;
      expect(service.uploads, 2);
      expect(results, ['/1.wav:Transcript', '/2.wav:Transcript']);
      expect(service.keys.take(4), everyElement('snapshot-key'));
      final json = (await store.load()).map((job) => job.toJson()).toString();
      expect(json, isNot(contains('snapshot-key')));
    },
  );

  test(
    'restores known task without reupload and persists result before cleanup',
    () async {
      await store.save([
        MossJob(
          id: '1',
          recordingKey: 'r',
          path: '/a.wav',
          stage: MossJobStage.polling,
          fileId: 'file',
          taskId: 'task',
        ),
      ]);
      queue = makeQueue(
        save: (job, result) async {
          expect(service.deletes, 0);
          expect((await store.load()).single.stage, MossJobStage.result);
          results.add(result.text);
        },
      );
      await queue.load();
      await settleUntil(() => queue.jobs.single.stage == MossJobStage.complete);
      expect(service.uploads, 0);
      expect(service.submissions, 0);
      expect(results, ['Transcript']);
      expect(service.deletes, 1);
    },
  );

  for (final stage in [
    MossJobStage.uploadUnknown,
    MossJobStage.submissionUnknown,
  ]) {
    test('does not resubmit restored ${stage.name}', () async {
      await store.save([
        MossJob(id: '1', recordingKey: 'r', path: '/a.wav', stage: stage),
      ]);
      queue = makeQueue();
      await queue.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.uploads, 0);
      expect(service.submissions, 0);
      expect(queue.jobs.single.error, contains('可能重复计费'));
      await queue.enqueue('r', '/a.wav', retry: true);
      expect(service.uploads, 1);
      expect(results, hasLength(1));
    });
  }

  test(
    'unknown submission response is retained without an automatic retry',
    () async {
      service.submitError = const MossException('network');
      queue = makeQueue();
      await queue.enqueue('r', '/a.wav');
      expect(queue.jobs.single.stage, MossJobStage.submissionUnknown);
      queue.wake();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.submissions, 1);
      expect(service.deletes, 0);
    },
  );

  test('failed upload can be explicitly retried', () async {
    service.uploadError = const MossException('credentials', statusCode: 401);
    queue = makeQueue();
    await queue.enqueue('r', '/a.wav');
    expect(queue.jobs.single.stage, MossJobStage.failed);
    expect(results, isEmpty);
    service.uploadError = null;
    await queue.enqueue('r', '/a.wav', retry: true);
    expect(results, hasLength(1));
  });

  test(
    'deleted recording rejects late task result and cleans uploaded audio',
    () async {
      service.pendingTask = Completer<Map<String, dynamic>>();
      queue = makeQueue();
      final work = queue.enqueue('r', '/a.wav');
      await settleUntil(() => service.polls == 1);
      await queue.discard('r');
      service.pendingTask!.complete({'status': 'SUCCESS', 'text': 'Late'});
      await work;
      await settleUntil(() => service.deletes == 1);
      expect(results, isEmpty);
    },
  );

  test('rename during remote work delivers to the renamed recording', () async {
    service.pendingTask = Completer<Map<String, dynamic>>();
    queue = makeQueue();
    final work = queue.enqueue('r', '/a.wav');
    await settleUntil(() => service.polls == 1);
    await queue.rename('r', 'renamed', '/renamed.wav');
    service.pendingTask!.complete({'status': 'SUCCESS', 'text': 'Done'});
    await work;
    expect(results, ['/renamed.wav:Done']);
  });

  test('saving failure retains fetched result for restart and retry', () async {
    queue = makeQueue(save: (_, _) async => throw FileSystemException('full'));
    await queue.enqueue('r', '/a.wav');
    expect(service.deletes, 0);
    expect((await store.load()).single.text, 'Transcript');
    queue.dispose();
    queue = makeQueue();
    await queue.load();
    await queue.enqueue('r', '/a.wav', retry: true);
    expect(service.uploads, 1);
    expect(service.polls, 1);
    expect(results, ['/a.wav:Transcript']);
  });

  test(
    'cleanup failure is recovered without repeating result delivery',
    () async {
      service.cleanupError = const MossException('network');
      queue = makeQueue();
      await queue.enqueue('r', '/a.wav');
      expect(queue.jobs.single.stage, MossJobStage.cleanup);
      queue.dispose();
      service.cleanupError = null;
      queue = makeQueue();
      await queue.load();
      await settleUntil(() => queue.jobs.single.stage == MossJobStage.complete);
      expect(results, hasLength(1));
      expect(service.uploads, 1);
    },
  );

  test(
    'terminal empty results clean up but never replace saved text',
    () async {
      service.response = {'status': 'SUCCESS', 'text': ''};
      queue = makeQueue();
      await queue.enqueue('r', '/a.wav');
      expect(results, isEmpty);
      expect(service.deletes, 1);
      expect(queue.jobs.single.error, contains('未识别到语音'));
    },
  );

  test(
    'polling honors retry_after and waits for file-processing availability',
    () async {
      allowed = false;
      service.response = {'status': 'PENDING', 'retry_after': 1};
      queue = makeQueue();
      final work = queue.enqueue('r', '/a.wav');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.uploads, 0);
      allowed = true;
      queue.wake();
      await settleUntil(() => service.polls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.polls, 1);
      service.response = {'status': 'SUCCESS', 'text': 'Done'};
      await work.timeout(const Duration(seconds: 3));
      expect(service.polls, 2);
      expect(results, ['/a.wav:Done']);
    },
  );

  test(
    'journal writes atomically and restores entries without secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp('moss-journal-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/jobs.json');
      store = MossJobStore(file: file);
      queue = makeQueue();
      await queue.enqueue('r', '/a.wav', key: 'private-key');
      expect(await file.readAsString(), isNot(contains('private-key')));
      expect(
        (await MossJobStore(file: file).load()).single.stage,
        MossJobStage.complete,
      );
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );
}
