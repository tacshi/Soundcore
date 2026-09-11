import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/stt_types.dart';
import '../ai/speech_provider.dart';

/// Lightweight JSON settings for speech providers and recording preferences.
class AppSettingsStore {
  AppSettingsStore._();

  static const _fileName = 'app_settings.json';
  static Future<void> _pendingSave = Future.value();

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

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const AppSettings();
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return AppSettings.fromJson(map);
    } catch (e) {
      debugPrint('[AppSettings] load failed: $e');
      return const AppSettings();
    }
  }

  static Future<void> save(AppSettings s, {bool strict = false}) {
    final encoded = const JsonEncoder.withIndent('  ').convert(s.toJson());
    final operation = _pendingSave.then((_) async {
      try {
        final file = await _file();
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(encoded, flush: true);
        await temporary.rename(file.path);
      } catch (error) {
        debugPrint('[AppSettings] save failed: $error');
        if (strict) rethrow;
      }
    });
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }
}

class AppSettings {
  const AppSettings({
    this.speechProvider,
    this.appleSourceLanguage = '',
    this.sonioxApiKey,
    this.mossApiKey,
    this.autoTranscribe = true,
    this.autoRealtime = true,
    this.transcriptLanguage = 'auto',
    this.sttMode = SttDisplayMode.transcription,
    this.translationTargetLanguage = 'zh',
    this.ownerLanguage = 'zh',
    this.guestLanguage = 'en',
  });

  final String? sonioxApiKey;
  final String? mossApiKey;

  /// Null means an existing install has not selected a provider yet.
  final SttProvider? speechProvider;
  final String appleSourceLanguage;
  final bool autoTranscribe;
  final bool autoRealtime;
  final String transcriptLanguage;
  final SttDisplayMode sttMode;
  final String translationTargetLanguage;
  final String ownerLanguage;
  final String guestLanguage;

  AppSettings copyWith({
    SttProvider? speechProvider,
    String? appleSourceLanguage,
    String? sonioxApiKey,
    String? mossApiKey,
    bool? autoTranscribe,
    bool? autoRealtime,
    String? transcriptLanguage,
    SttDisplayMode? sttMode,
    String? translationTargetLanguage,
    String? ownerLanguage,
    String? guestLanguage,
    bool clearSoniox = false,
    bool clearMoss = false,
  }) {
    return AppSettings(
      speechProvider: speechProvider ?? this.speechProvider,
      appleSourceLanguage: appleSourceLanguage ?? this.appleSourceLanguage,
      mossApiKey: clearMoss ? null : (mossApiKey ?? this.mossApiKey),
      sonioxApiKey: clearSoniox ? null : (sonioxApiKey ?? this.sonioxApiKey),
      autoTranscribe: autoTranscribe ?? this.autoTranscribe,
      autoRealtime: autoRealtime ?? this.autoRealtime,
      transcriptLanguage: transcriptLanguage ?? this.transcriptLanguage,
      sttMode: sttMode ?? this.sttMode,
      translationTargetLanguage:
          translationTargetLanguage ?? this.translationTargetLanguage,
      ownerLanguage: ownerLanguage ?? this.ownerLanguage,
      guestLanguage: guestLanguage ?? this.guestLanguage,
    );
  }

  Map<String, dynamic> toJson() => {
    if (speechProvider != null) 'speechProvider': speechProvider!.name,
    'appleSourceLanguage': appleSourceLanguage,
    if (sonioxApiKey != null && sonioxApiKey!.isNotEmpty)
      'sonioxApiKey': sonioxApiKey,
    if (mossApiKey != null && mossApiKey!.isNotEmpty) 'mossApiKey': mossApiKey,
    'autoTranscribe': autoTranscribe,
    'autoRealtime': autoRealtime,
    'transcriptLanguage': transcriptLanguage,
    'sttMode': sttMode.name,
    'translationTargetLanguage': translationTargetLanguage,
    'ownerLanguage': ownerLanguage,
    'guestLanguage': guestLanguage,
  };

  factory AppSettings.fromJson(Map<String, dynamic> map) {
    final modeName = _str(map['sttMode']);
    final sttMode = SttDisplayMode.values.firstWhere(
      (mode) => mode.name == modeName,
      orElse: () => map['communicationModeEnabled'] == true
          ? SttDisplayMode.conversation
          : SttDisplayMode.transcription,
    );
    var ownerLanguage = (_str(map['ownerLanguage']) ?? 'zh').toLowerCase();
    var guestLanguage = (_str(map['guestLanguage']) ?? 'en').toLowerCase();
    if (ownerLanguage == guestLanguage) {
      ownerLanguage = 'zh';
      guestLanguage = 'en';
    }
    return AppSettings(
      speechProvider: SttProvider.parse(map['speechProvider']),
      appleSourceLanguage: _str(map['appleSourceLanguage']) ?? '',
      sonioxApiKey: _str(map['sonioxApiKey']),
      mossApiKey: _str(map['mossApiKey']),
      autoTranscribe: map['autoTranscribe'] != false,
      autoRealtime: map['autoRealtime'] != false,
      transcriptLanguage: _str(map['transcriptLanguage']) ?? 'auto',
      sttMode: sttMode,
      translationTargetLanguage: _str(map['translationTargetLanguage']) ?? 'zh',
      ownerLanguage: ownerLanguage,
      guestLanguage: guestLanguage,
    );
  }

  static String? _str(dynamic v) {
    final s = '$v'.trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }
}
