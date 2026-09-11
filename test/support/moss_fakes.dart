import 'dart:async';
import 'package:anker_recorder/ai/moss_stt.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMoss extends MossSttService {
  Object? validationError;
  @override
  Future<void> validateKey(String key) async {
    if (validationError != null) throw validationError!;
  }

  int uploads = 0, submissions = 0, polls = 0, deletes = 0;
  final keys = <String>[];
  Completer<String>? pendingUpload;
  Completer<Map<String, dynamic>>? pendingTask;
  Object? uploadError, submitError, cleanupError;
  Map<String, dynamic> response = {'status': 'SUCCESS', 'text': 'Transcript'};
  @override
  Future<String> prepareAudio(String path) async => path;
  @override
  Future<String> upload(
    String path,
    String key, {
    SttFileProgressCallback? onProgress,
  }) async {
    uploads++;
    keys.add(key);
    if (uploadError != null) throw uploadError!;
    return pendingUpload == null ? 'file' : await pendingUpload!.future;
  }

  @override
  Future<String> submit(String fileId, String key) async {
    submissions++;
    keys.add(key);
    if (submitError != null) throw submitError!;
    return 'task';
  }

  @override
  Future<Map<String, dynamic>> task(String id, String key) async {
    polls++;
    keys.add(key);
    return pendingTask == null ? response : await pendingTask!.future;
  }

  @override
  Future<void> deleteFile(String id, String key) async {
    deletes++;
    keys.add(key);
    if (cleanupError != null) throw cleanupError!;
  }
}

Future<void> settleUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}
