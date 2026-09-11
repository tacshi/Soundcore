import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'recording.dart';

typedef TranscriptStoreData = ({
  Map<String, String> byPath,
  Map<int, String> byFileId,
  Map<String, Map<String, String>> aliasesByPath,
  Map<int, Map<String, String>> aliasesByFileId,
  Map<String, TranscriptMetadata> metadata,
  Map<String, RecordingTranslation> translations,
});

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

  static TranscriptStoreData _emptyData() => (
    byPath: <String, String>{},
    byFileId: <int, String>{},
    aliasesByPath: <String, Map<String, String>>{},
    aliasesByFileId: <int, Map<String, String>>{},
    metadata: <String, TranscriptMetadata>{},
    translations: <String, RecordingTranslation>{},
  );

  static Future<TranscriptStoreData> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return _emptyData();
      final json = jsonDecode(await file.readAsString());
      return decode(json);
    } catch (e) {
      debugPrint('[TranscriptStore] load failed: $e');
      return _emptyData();
    }
  }

  @visibleForTesting
  static TranscriptStoreData decode(Object? json) {
    if (json is! Map) return _emptyData();

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

    final aliasesByPath = _decodeAliases<String>(
      json['aliasesByPath'],
      (key) => '$key',
    );
    final aliasesByFileId = _decodeAliases<int>(
      json['aliasesByFileId'],
      (key) => int.tryParse('$key'),
    );
    return (
      byPath: byPath,
      byFileId: byFileId,
      aliasesByPath: aliasesByPath,
      aliasesByFileId: aliasesByFileId,
      metadata: _decodeMetadata(json['metadata']),
      translations: _decodeTranslations(json['translations']),
    );
  }

  static Map<String, TranscriptMetadata> _decodeMetadata(Object? value) {
    if (value is! Map) return {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: TranscriptMetadata.fromJson(entry.value as Map),
    };
  }

  static Map<String, RecordingTranslation> _decodeTranslations(Object? value) {
    final output = <String, RecordingTranslation>{};
    if (value is Map) {
      for (final entry in value.entries) {
        final translation = RecordingTranslation.decode(entry.value);
        if (entry.key is String && translation != null) {
          output[entry.key as String] = translation;
        }
      }
    }
    return output;
  }

  static Map<K, Map<String, String>> _decodeAliases<K>(
    Object? json,
    K? Function(Object? key) parseKey,
  ) {
    final decoded = <K, Map<String, String>>{};
    if (json is! Map) return decoded;
    for (final entry in json.entries) {
      final key = parseKey(entry.key);
      final rawAliases = entry.value;
      if (key == null || rawAliases is! Map) continue;
      final aliases = <String, String>{};
      for (final aliasEntry in rawAliases.entries) {
        final id = '${aliasEntry.key}'.trim();
        final alias = aliasEntry.value;
        if (id.isNotEmpty && alias is String && alias.trim().isNotEmpty) {
          aliases[id] = alias.trim();
        }
      }
      if (aliases.isNotEmpty) decoded[key] = aliases;
    }
    return decoded;
  }

  static Future<void> save({
    required Map<String, String> byPath,
    required Map<int, String> byFileId,
    required Map<String, Map<String, String>> aliasesByPath,
    required Map<int, Map<String, String>> aliasesByFileId,
    Map<String, TranscriptMetadata> metadata = const {},
    Map<String, RecordingTranslation> translations = const {},
    bool strict = false,
  }) {
    final paths = Map<String, String>.from(byPath);
    final ids = Map<int, String>.from(byFileId);
    final pathAliases = _copyAliases(aliasesByPath);
    final idAliases = _copyAliases(aliasesByFileId);
    final meta = Map<String, TranscriptMetadata>.from(metadata);
    final translated = Map<String, RecordingTranslation>.from(translations);
    final operation = _pendingSave.then(
      (_) =>
          _write(paths, ids, pathAliases, idAliases, meta, translated, strict),
    );
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }

  static Map<K, Map<String, String>> _copyAliases<K>(
    Map<K, Map<String, String>> source,
  ) => source.map(
    (key, aliases) => MapEntry(key, Map<String, String>.from(aliases)),
  );

  @visibleForTesting
  static Map<String, dynamic> encode({
    required Map<String, String> byPath,
    required Map<int, String> byFileId,
    required Map<String, Map<String, String>> aliasesByPath,
    required Map<int, Map<String, String>> aliasesByFileId,
    Map<String, TranscriptMetadata> metadata = const {},
    Map<String, RecordingTranslation> translations = const {},
  }) => <String, dynamic>{
    'version': 2,
    'byPath': byPath,
    'byFileId': byFileId.map((id, text) => MapEntry('$id', text)),
    'aliasesByPath': aliasesByPath,
    'aliasesByFileId': aliasesByFileId.map(
      (id, aliases) => MapEntry('$id', aliases),
    ),
    'metadata': metadata.map((key, value) => MapEntry(key, value.toJson())),
    'translations': translations.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };

  static Future<void> _write(
    Map<String, String> byPath,
    Map<int, String> byFileId,
    Map<String, Map<String, String>> aliasesByPath,
    Map<int, Map<String, String>> aliasesByFileId,
    Map<String, TranscriptMetadata> metadata,
    Map<String, RecordingTranslation> translations,
    bool strict,
  ) async {
    try {
      final file = await _file();
      final json = encode(
        byPath: byPath,
        byFileId: byFileId,
        aliasesByPath: aliasesByPath,
        aliasesByFileId: aliasesByFileId,
        metadata: metadata,
        translations: translations,
      );
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (e) {
      debugPrint('[TranscriptStore] save failed: $e');
      if (strict) rethrow;
    }
  }
}
