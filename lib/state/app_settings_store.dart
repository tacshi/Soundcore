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
    this.sttProvider = SttProvider.xai,
    this.autoTranscribe = true,
    this.autoRealtime = true,
    this.showAllDevices = false,
    this.transcriptLanguage = 'zh',
  });

  final String? xaiApiKey;
  final String? sonioxApiKey;
  final SttProvider sttProvider;
  final bool autoTranscribe;
  final bool autoRealtime;
  final bool showAllDevices;
  final String transcriptLanguage;

  AppSettings copyWith({
    String? xaiApiKey,
    String? sonioxApiKey,
    SttProvider? sttProvider,
    bool? autoTranscribe,
    bool? autoRealtime,
    bool? showAllDevices,
    String? transcriptLanguage,
    bool clearXai = false,
    bool clearSoniox = false,
  }) {
    return AppSettings(
      xaiApiKey: clearXai ? null : (xaiApiKey ?? this.xaiApiKey),
      sonioxApiKey: clearSoniox ? null : (sonioxApiKey ?? this.sonioxApiKey),
      sttProvider: sttProvider ?? this.sttProvider,
      autoTranscribe: autoTranscribe ?? this.autoTranscribe,
      autoRealtime: autoRealtime ?? this.autoRealtime,
      showAllDevices: showAllDevices ?? this.showAllDevices,
      transcriptLanguage: transcriptLanguage ?? this.transcriptLanguage,
    );
  }

  Map<String, dynamic> toJson() => {
    if (xaiApiKey != null && xaiApiKey!.isNotEmpty) 'xaiApiKey': xaiApiKey,
    if (sonioxApiKey != null && sonioxApiKey!.isNotEmpty)
      'sonioxApiKey': sonioxApiKey,
    'sttProvider': sttProvider.name,
    'autoTranscribe': autoTranscribe,
    'autoRealtime': autoRealtime,
    'showAllDevices': showAllDevices,
    'transcriptLanguage': transcriptLanguage,
  };

  factory AppSettings.fromJson(Map<String, dynamic> map) {
    final providerName = '${map['sttProvider'] ?? 'xai'}';
    final provider = SttProvider.values.firstWhere(
      (e) => e.name == providerName,
      orElse: () => SttProvider.xai,
    );
    return AppSettings(
      xaiApiKey: _str(map['xaiApiKey']),
      sonioxApiKey: _str(map['sonioxApiKey']),
      sttProvider: provider,
      autoTranscribe: map['autoTranscribe'] != false,
      autoRealtime: map['autoRealtime'] != false,
      showAllDevices: map['showAllDevices'] == true,
      transcriptLanguage: _str(map['transcriptLanguage']) ?? 'zh',
    );
  }

  static String? _str(dynamic v) {
    final s = '$v'.trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }
}
