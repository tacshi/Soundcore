import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/stt_types.dart';

/// Lightweight JSON settings (API keys, STT provider, toggles).
class AppSettingsStore {
  AppSettingsStore._();

  static const _fileName = 'app_settings.json';

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

  static Future<void> save(AppSettings s) async {
    try {
      final f = await _file();
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(s.toJson()),
      );
      debugPrint('[AppSettings] saved provider=${s.sttProvider.name}');
    } catch (e) {
      debugPrint('[AppSettings] save failed: $e');
    }
  }
}

class AppSettings {
  const AppSettings({
    this.xaiApiKey,
    this.sonioxApiKey,
    this.sttProvider = SttProvider.soniox,
    this.autoTranscribe = true,
    this.autoRealtime = true,
    this.transcriptLanguage = 'zh',
    this.sttMode = SttDisplayMode.transcription,
    this.translationTargetLanguage = 'zh',
    this.ownerLanguage = 'zh',
    this.guestLanguage = 'en',
  });

  final String? xaiApiKey;
  final String? sonioxApiKey;
  final SttProvider sttProvider;
  final bool autoTranscribe;
  final bool autoRealtime;
  final String transcriptLanguage;
  final SttDisplayMode sttMode;
  final String translationTargetLanguage;
  final String ownerLanguage;
  final String guestLanguage;

  AppSettings copyWith({
    String? xaiApiKey,
    String? sonioxApiKey,
    SttProvider? sttProvider,
    bool? autoTranscribe,
    bool? autoRealtime,
    String? transcriptLanguage,
    SttDisplayMode? sttMode,
    String? translationTargetLanguage,
    String? ownerLanguage,
    String? guestLanguage,
    bool clearXai = false,
    bool clearSoniox = false,
  }) {
    return AppSettings(
      xaiApiKey: clearXai ? null : (xaiApiKey ?? this.xaiApiKey),
      sonioxApiKey: clearSoniox ? null : (sonioxApiKey ?? this.sonioxApiKey),
      sttProvider: sttProvider ?? this.sttProvider,
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
    if (xaiApiKey != null && xaiApiKey!.isNotEmpty) 'xaiApiKey': xaiApiKey,
    if (sonioxApiKey != null && sonioxApiKey!.isNotEmpty)
      'sonioxApiKey': sonioxApiKey,
    'sttProvider': sttProvider.name,
    'autoTranscribe': autoTranscribe,
    'autoRealtime': autoRealtime,
    'transcriptLanguage': transcriptLanguage,
    'sttMode': sttMode.name,
    'translationTargetLanguage': translationTargetLanguage,
    'ownerLanguage': ownerLanguage,
    'guestLanguage': guestLanguage,
  };

  factory AppSettings.fromJson(Map<String, dynamic> map) {
    final providerName = '${map['sttProvider'] ?? 'soniox'}';
    final provider = SttProvider.values.firstWhere(
      (e) => e.name == providerName,
      orElse: () => SttProvider.soniox,
    );
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
      xaiApiKey: _str(map['xaiApiKey']),
      sonioxApiKey: _str(map['sonioxApiKey']),
      sttProvider: provider,
      autoTranscribe: map['autoTranscribe'] != false,
      autoRealtime: map['autoRealtime'] != false,
      transcriptLanguage: _str(map['transcriptLanguage']) ?? 'zh',
      sttMode: sttMode,
      translationTargetLanguage:
          (_str(map['translationTargetLanguage']) ?? 'zh').toLowerCase(),
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
