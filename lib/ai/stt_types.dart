import 'dart:async';
import 'dart:typed_data';

/// Supported speech-to-text backends.
enum SttProvider {
  xai,
  soniox;

  String get label {
    switch (this) {
      case SttProvider.xai:
        return 'xAI';
      case SttProvider.soniox:
        return 'Soniox';
    }
  }

  String get envKeyName {
    switch (this) {
      case SttProvider.xai:
        return 'XAI_API_KEY';
      case SttProvider.soniox:
        return 'SONIOX_API_KEY';
    }
  }
}

enum SttFileStage { preparing, uploading, queued, processing, fetching }

class SttFileProgress {
  const SttFileProgress(this.stage, {this.uploadedBytes, this.totalBytes});

  final SttFileStage stage;
  final int? uploadedBytes;
  final int? totalBytes;

  double? get fraction {
    final uploaded = uploadedBytes;
    final total = totalBytes;
    if (uploaded == null || total == null || total <= 0) return null;
    return (uploaded / total).clamp(0.0, 1.0);
  }
}

typedef SttFileProgressCallback = void Function(SttFileProgress progress);

/// Normalize provider-specific markers in transcript text.
///
/// Soniox endpoint detection emits `<end>` tokens; convert those to newlines
/// and tidy surrounding whitespace.
String normalizeSttText(String raw) {
  var t = raw;
  // Soniox endpoint marker → paragraph break.
  t = t.replaceAll(RegExp(r'\s*<end>\s*', caseSensitive: false), '\n');
  // Collapse spaces/tabs within a line (keep newlines).
  t = t.replaceAll(RegExp(r'[^\S\n]+'), ' ');
  // Trim spaces at line edges; collapse 3+ blank lines to one blank line.
  t = t
      .split('\n')
      .map((line) => line.trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return t;
}

/// Render Soniox tokens as readable, speaker-attributed text.
///
/// Tokens without a speaker continue under the most recent speaker. Translation
/// tokens are excluded because the app displays the source transcript.
String renderSonioxTokens(Iterable<dynamic> tokens) {
  final buffer = StringBuffer();
  String? currentSpeaker;

  for (final token in tokens) {
    if (token is! Map) continue;
    if (token['translation_status'] == 'translation') continue;

    var text = '${token['text'] ?? ''}';
    if (text.isEmpty) continue;
    if (RegExp(r'^<end>$', caseSensitive: false).hasMatch(text.trim())) {
      buffer.write('\n');
      continue;
    }

    final rawSpeaker = token['speaker'];
    final speaker = rawSpeaker == null ? null : '$rawSpeaker'.trim();
    if (speaker != null && speaker.isNotEmpty && speaker != currentSpeaker) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write('说话人 $speaker：');
      currentSpeaker = speaker;
      text = text.trimLeft();
    }
    buffer.write(text);
  }

  return normalizeSttText(buffer.toString());
}

/// Batch / file transcription result.
class SttResult {
  const SttResult({
    required this.text,
    this.durationSec,
    this.language,
    this.sourcePath,
    this.provider,
  });

  final String text;
  final double? durationSec;
  final String? language;
  final String? sourcePath;
  final SttProvider? provider;
}

/// Live transcript event from a streaming STT session.
class SttStreamEvent {
  const SttStreamEvent({
    required this.type,
    this.text = '',
    this.isFinal = false,
    this.speechFinal = false,
    this.durationSec,
    this.error,
  });

  /// `created` | `partial` | `done` | `error` | `closed`
  final String type;
  final String text;
  final bool isFinal;
  final bool speechFinal;
  final double? durationSec;
  final String? error;
}

/// Common interface for PCM16 LE streaming STT (xAI WS / Soniox WS).
abstract class SttStreamSession {
  Stream<SttStreamEvent> get events;
  bool get isOpen;
  bool get isServerReady;

  Future<void> start({Duration timeout = const Duration(seconds: 15)});
  void sendPcm(Uint8List pcm16le);
  void finalizeUtterance();
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  });
  Future<void> close();
  Future<void> dispose();
}
