import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/moss_stt.dart';
import '../ai/stt_types.dart';

/// The two unknown stages are written *before* issuing non-idempotent requests.
/// They deliberately require an explicit new attempt if no response was saved.
enum MossJobStage {
  queued,
  uploadUnknown,
  uploaded,
  submissionUnknown,
  polling,
  result,
  cleanup,
  complete,
  failed,
}

class MossJob {
  MossJob({
    required this.id,
    required this.recordingKey,
    required this.path,
    this.stage = MossJobStage.queued,
    this.fileId,
    this.taskId,
    this.text,
    this.language,
    this.error,
    this.discarded = false,
  });
  final String id;
  String recordingKey;
  String path;
  MossJobStage stage;
  String? fileId;
  String? taskId;
  String? text;
  String? language;
  String? error;
  bool discarded;
  // Secrets and transient progress are never serialized.
  String? key;
  SttFileProgress? progress;
  bool get pending =>
      !discarded &&
      switch (stage) {
        MossJobStage.queued ||
        MossJobStage.uploaded ||
        MossJobStage.polling ||
        MossJobStage.result => true,
        _ => false,
      };
  Map<String, dynamic> toJson() => {
    'id': id,
    'recordingKey': recordingKey,
    'path': path,
    'stage': stage.name,
    'fileId': fileId,
    'taskId': taskId,
    'text': text,
    'language': language,
    'error': error,
    'discarded': discarded,
  };
  factory MossJob.fromJson(Map<String, dynamic> json) => MossJob(
    id: json['id'] as String,
    recordingKey: json['recordingKey'] as String,
    path: json['path'] as String,
    stage: MossJobStage.values.byName(json['stage'] as String),
    fileId: json['fileId'] as String?,
    taskId: json['taskId'] as String?,
    text: json['text'] as String?,
    language: json['language'] as String?,
    error: json['error'] as String?,
    discarded: json['discarded'] == true,
  );
}

class MossJobStore {
  MossJobStore({this.file, this.inMemory = false});
  final File? file;
  final bool inMemory;
  List<Map<String, dynamic>> _memory = [];
  Future<void> _writing = Future.value();
  Future<File> _file() async {
    if (file != null) return file!;
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, 'AnkerRecorder', 'moss_jobs.json'));
  }

  Future<List<MossJob>> load() async {
    if (inMemory) return _memory.map(MossJob.fromJson).toList();
    final source = await _file();
    if (!await source.exists()) return [];
    // A corrupt journal is an error, never permission to upload again.
    return (jsonDecode(await source.readAsString()) as List)
        .map((item) => MossJob.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<void> save(List<MossJob> jobs) {
    final snapshot = jobs.map((job) => job.toJson()).toList();
    final operation = _writing.then((_) async {
      if (inMemory) {
        _memory = snapshot;
        return;
      }
      final destination = await _file();
      await destination.parent.create(recursive: true);
      final temporary = File('${destination.path}.tmp');
      await temporary.writeAsString(jsonEncode(snapshot), flush: true);
      await temporary.rename(destination.path);
    });
    _writing = operation.catchError((Object _) {});
    return operation;
  }
}

/// Serial file work, independent of the current live recording. Result delivery
/// must finish persisting the transcript before this queue acknowledges it.
class MossJobQueue {
  MossJobQueue({
    required this.service,
    required this.store,
    required this.apiKey,
    required this.canStart,
    required this.onResult,
    required this.onChanged,
  });
  final MossSttService service;
  final MossJobStore store;
  final String? Function() apiKey;
  final bool Function() canStart;
  final Future<void> Function(MossJob, SttResult) onResult;
  final void Function() onChanged;
  final List<MossJob> jobs = [];
  final Map<String, Completer<void>> _waiters = {};
  bool _loaded = false;
  bool _running = false;
  bool _disposed = false;
  Timer? _timer;
  Future<void>? _loading;
  String? loadError;
  MossJob? active;
  bool get busy => active != null;
  MossJob? forRecording(String key) =>
      jobs.where((job) => job.recordingKey == key && !job.discarded).lastOrNull;

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      jobs.addAll(await store.load());
      for (final job in jobs) {
        if (job.stage == MossJobStage.uploadUnknown ||
            job.stage == MossJobStage.submissionUnknown) {
          job.error = '上次请求结果未确认；重试会重新提交，可能重复计费';
        }
      }
      _loaded = true;
    } catch (_) {
      loadError = '无法读取待处理转写，请重启后重试';
    }
    if (!_disposed) {
      onChanged();
      wake();
    }
  }

  Future<void> enqueue(
    String recordingKey,
    String path, {
    String? key,
    bool retry = false,
  }) async {
    await load();
    if (!_loaded) throw StateError(loadError ?? '无法读取转写任务');
    if (_disposed) return;
    final previous = forRecording(recordingKey);
    if (previous != null) {
      if (previous.pending || identical(previous, active)) return;
      if (!retry) return;
      // A known task is safe to query again; never upload it twice.
      if (previous.taskId != null &&
          previous.stage != MossJobStage.complete &&
          previous.stage != MossJobStage.cleanup) {
        previous.stage = previous.text != null
            ? MossJobStage.result
            : MossJobStage.polling;
        previous.error = null;
        previous.key = key;
        await store.save(jobs);
        final waiter = _waiters.putIfAbsent(previous.id, Completer<void>.new);
        wake();
        return waiter.future;
      }
      previous.discarded = true;
      if (previous.fileId != null &&
          previous.stage != MossJobStage.submissionUnknown) {
        previous.stage = MossJobStage.cleanup;
      }
    }
    final job = MossJob(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      recordingKey: recordingKey,
      path: path,
    )..key = key;
    jobs.add(job);
    await store.save(jobs);
    final waiter = _waiters.putIfAbsent(job.id, Completer<void>.new);
    onChanged();
    wake();
    return waiter.future;
  }

  void wake() {
    if (!_loaded || _disposed || _running || _timer != null) return;
    // Defer to avoid notification/rebuild reentrancy.
    _timer = Timer(Duration.zero, () {
      _timer = null;
      unawaited(_drain());
    });
  }

  void _later(Duration duration) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(duration, () {
      _timer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (_running || _disposed || !canStart()) return;
    final job =
        jobs
            .where(
              (item) =>
                  item.pending ||
                  (item.discarded && item.stage == MossJobStage.polling),
            )
            .firstOrNull ??
        jobs.where((item) => item.stage == MossJobStage.cleanup).firstOrNull;
    if (job == null) return;
    final key = job.key ?? apiKey();
    if (key == null || key.isEmpty) {
      final changed = job.error != '请在设置中配置 MOSS Pro';
      job.error = '请在设置中配置 MOSS Pro';
      _finishWaiter(job);
      if (changed) onChanged();
      return;
    }
    job.key = key;
    _running = true;
    active = job;
    var delay = Duration.zero;
    onChanged();
    try {
      if (job.stage == MossJobStage.queued) {
        job.progress = const SttFileProgress(SttFileStage.preparing);
        final playable = await service.prepareAudio(job.path);
        if (_disposed) return;
        if (job.discarded) {
          job.stage = MossJobStage.complete;
          await store.save(jobs);
          return;
        }
        job.stage = MossJobStage.uploadUnknown;
        await store.save(jobs);
        if (_disposed) return;
        if (job.discarded) {
          job.stage = MossJobStage.complete;
          await store.save(jobs);
          return;
        }
        job.fileId = await service.upload(
          playable,
          key,
          onProgress: (progress) {
            job.progress = progress;
            if (!_disposed) onChanged();
          },
        );
        job.stage = job.discarded
            ? MossJobStage.cleanup
            : MossJobStage.uploaded;
        await store.save(jobs);
      }
      if (_disposed) return;
      if (job.stage == MossJobStage.uploaded && job.discarded) {
        job.stage = MossJobStage.cleanup;
      }
      if (job.stage == MossJobStage.uploaded) {
        job.stage = MossJobStage.submissionUnknown;
        await store.save(jobs);
        if (_disposed) return;
        job.taskId = await service.submit(job.fileId!, key);
        job.stage = MossJobStage.polling;
        await store.save(jobs);
      }
      if (_disposed) return;
      if (job.stage == MossJobStage.polling) {
        job.progress = const SttFileProgress(SttFileStage.processing);
        onChanged();
        final result = await service.task(job.taskId!, key);
        if (_disposed) return;
        switch (result['status']) {
          case 'SUCCESS':
            if (job.discarded) {
              job.stage = MossJobStage.cleanup;
              break;
            }
            SttResult transcript;
            try {
              transcript = service.parse(result);
            } on MossException catch (error) {
              job.error = error.message;
              job.stage = MossJobStage.cleanup;
              await store.save(jobs);
              break;
            }
            job.text = transcript.text;
            job.language = transcript.language;
            job.stage = MossJobStage.result;
            await store.save(jobs);
          case 'FAILED':
            job.error = const MossException('failed').message;
            job.stage = MossJobStage.cleanup;
            await store.save(jobs);
          case 'PENDING':
          case 'PROCESSING':
            job.error = null;
            job.progress = SttFileProgress(
              result['status'] == 'PENDING'
                  ? SttFileStage.queued
                  : SttFileStage.processing,
            );
            delay = Duration(
              seconds: ((result['retry_after'] as num?)?.toInt() ?? 3).clamp(
                1,
                30,
              ),
            );
          default:
            throw const MossException('response');
        }
      }
      if (_disposed) return;
      if (job.stage == MossJobStage.result) {
        if (!job.discarded) {
          await onResult(
            job,
            SttResult(
              text: job.text!,
              language: job.language,
              sourcePath: job.path,
            ),
          );
        }
        if (_disposed) return;
        job.stage = MossJobStage.cleanup;
        job.error = null;
        await store.save(jobs);
      }
      if (job.stage == MossJobStage.cleanup) {
        if (job.fileId != null) await service.deleteFile(job.fileId!, key);
        job.stage = MossJobStage.complete;
        job.text = null;
        await store.save(jobs);
        _finishWaiter(job);
      }
    } catch (error) {
      if (_disposed) return;
      debugPrint(
        '[MOSS] ${job.stage.name}: ${error is MossException ? error : error.runtimeType}',
      );
      if (job.stage == MossJobStage.cleanup ||
          job.stage == MossJobStage.complete) {
        job.stage = MossJobStage.cleanup;
        delay = const Duration(seconds: 30);
        _finishWaiter(job);
      } else if (job.stage == MossJobStage.uploadUnknown ||
          job.stage == MossJobStage.submissionUnknown) {
        // An explicit HTTP rejection proves no accepted upload/task exists.
        if (error is MossException &&
            error.statusCode != null &&
            error.statusCode! < 500) {
          job.stage = job.fileId == null
              ? MossJobStage.failed
              : MossJobStage.cleanup;
          job.error = error.message;
        } else {
          job.error = '上次请求结果未确认；重试会重新提交，可能重复计费';
        }
        _finishWaiter(job);
      } else if (job.stage == MossJobStage.polling &&
          error is MossException &&
          error.retryable) {
        job.error = error.message;
        delay = const Duration(seconds: 10);
        _finishWaiter(job);
      } else {
        job.error = error is MossException ? error.message : '无法保存转写，请重试';
        // Keep the result payload for an explicit retry after a disk failure.
        job.stage = MossJobStage.failed;
        _finishWaiter(job);
      }
      try {
        await store.save(jobs);
      } catch (_) {
        job.error = '无法保存转写进度，请检查存储空间后重试';
      }
    } finally {
      _running = false;
      active = null;
      if (!_disposed) {
        onChanged();
        if (delay > Duration.zero) {
          _later(delay);
        } else {
          wake();
        }
      }
    }
  }

  void _finishWaiter(MossJob job) => _waiters.remove(job.id)?.complete();

  Future<void> rename(String oldKey, String newKey, String path) async {
    await load();
    if (!_loaded || !jobs.any((job) => job.recordingKey == oldKey)) return;
    for (final job in jobs.where((job) => job.recordingKey == oldKey)) {
      job.recordingKey = newKey;
      job.path = path;
    }
    await store.save(jobs);
  }

  Future<void> discard(String key) async {
    await load();
    if (!_loaded || !jobs.any((job) => job.recordingKey == key)) return;
    for (final job in jobs.where((job) => job.recordingKey == key)) {
      job.discarded = true;
      // Poll accepted tasks to termination before removing their audio.
      if (job.taskId == null && !identical(job, active)) {
        job.stage = job.fileId == null
            ? MossJobStage.complete
            : MossJobStage.cleanup;
      }
      _finishWaiter(job);
    }
    await store.save(jobs);
    wake();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
    service.dispose();
  }
}
