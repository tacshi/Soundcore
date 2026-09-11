import '../ai/speech_provider.dart';
import '../ai/stt_types.dart';

/// Navigation identity survives a live recording acquiring its file id/path.
class RecordingReference {
  const RecordingReference({this.sessionId, this.fileId, this.path})
    : assert(sessionId != null || fileId != null || path != null);

  final String? sessionId;
  final int? fileId;
  final String? path;
  String get key => sessionId != null
      ? 'session:$sessionId'
      : fileId != null
      ? 'file:$fileId'
      : 'path:$path';
}

class TranscriptMetadata {
  const TranscriptMetadata({
    this.provider = SttProvider.soniox,
    this.sourceLanguage,
    this.revision = 0,
  });

  final SttProvider provider;
  final String? sourceLanguage;
  final int revision;

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'sourceLanguage': sourceLanguage,
    'revision': revision,
  };

  factory TranscriptMetadata.fromJson(Map json) => TranscriptMetadata(
    provider: SttProvider.parse(json['provider']) ?? SttProvider.soniox,
    sourceLanguage: json['sourceLanguage'] is String
        ? json['sourceLanguage'] as String
        : null,
    revision: json['revision'] is int ? json['revision'] as int : 0,
  );
}

class RecordingTranslation {
  const RecordingTranslation({
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.provider,
    required this.sourceRevision,
  });

  final String text;
  final String sourceLanguage;
  final String targetLanguage;
  final SttProvider provider;
  final int sourceRevision;

  Map<String, Object?> toJson() => {
    'text': text,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'provider': provider.name,
    'sourceRevision': sourceRevision,
  };

  static RecordingTranslation? decode(Object? value) {
    if (value is! Map ||
        value['text'] is! String ||
        value['sourceLanguage'] is! String ||
        value['targetLanguage'] is! String ||
        value['sourceRevision'] is! int) {
      return null;
    }
    if ((value['text'] as String).trim().isEmpty) return null;
    return RecordingTranslation(
      text: value['text'] as String,
      sourceLanguage: value['sourceLanguage'] as String,
      targetLanguage: value['targetLanguage'] as String,
      provider: SttProvider.parse(value['provider']) ?? SttProvider.apple,
      sourceRevision: value['sourceRevision'] as int,
    );
  }
}

class RecordingViewData {
  const RecordingViewData({
    required this.reference,
    required this.title,
    required this.text,
    this.path,
    this.translation,
    this.sourceLanguage,
    this.mode = SttDisplayMode.transcription,
    this.live = false,
    this.paused = false,
    this.audioLocked = false,
    this.processing = false,
    this.error,
    this.progress,
    this.provider = SttProvider.soniox,
    this.transcriptionEnabled = true,
    this.speechReady = true,
  });

  final RecordingReference reference;
  final String? path;
  final String title;
  final String text;
  final RecordingTranslation? translation;
  final String? sourceLanguage;
  final SttDisplayMode mode;
  final bool live;
  final bool paused;
  final bool audioLocked;
  final bool processing;
  final String? error;
  final SttFileProgress? progress;
  final SttProvider provider;
  final bool transcriptionEnabled;
  final bool speechReady;
}
