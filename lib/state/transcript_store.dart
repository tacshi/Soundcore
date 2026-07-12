import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists completed per-recording transcripts on the app device.
class TranscriptStore {
  TranscriptStore._();

  static const _fileName = 'transcripts.json';
  static Future<void> _pendingSave = Future<void>.value();

  static Future<File> _file() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _fileName));
  }

  static Future<({Map<String, String> byPath, Map<int, String> byFileId})>
  load() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return (byPath: <String, String>{}, byFileId: <int, String>{});
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) {
        return (byPath: <String, String>{}, byFileId: <int, String>{});
      }

      final byPath = <String, String>{};
      final paths = json['byPath'];
      if (paths is Map) {
        for (final entry in paths.entries) {
          final text = entry.value;
          if (text is String && text.isNotEmpty) {
            byPath['${entry.key}'] = text;
          }
        }
      }

      final byFileId = <int, String>{};
      final ids = json['byFileId'];
      if (ids is Map) {
        for (final entry in ids.entries) {
          final id = int.tryParse('${entry.key}');
          final text = entry.value;
          if (id != null && text is String && text.isNotEmpty) {
            byFileId[id] = text;
          }
        }
      }
      return (byPath: byPath, byFileId: byFileId);
    } catch (e) {
      debugPrint('[TranscriptStore] load failed: $e');
      return (byPath: <String, String>{}, byFileId: <int, String>{});
    }
  }

  static Future<void> save({
    required Map<String, String> byPath,
    required Map<int, String> byFileId,
  }) {
    final paths = Map<String, String>.from(byPath);
    final ids = Map<int, String>.from(byFileId);
    _pendingSave = _pendingSave.then((_) => _write(paths, ids));
    return _pendingSave;
  }

  static Future<void> _write(
    Map<String, String> byPath,
    Map<int, String> byFileId,
  ) async {
    try {
      final file = await _file();
      final json = <String, dynamic>{
        'byPath': byPath,
        'byFileId': byFileId.map((id, text) => MapEntry('$id', text)),
      };
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } catch (e) {
      debugPrint('[TranscriptStore] save failed: $e');
    }
  }
}
