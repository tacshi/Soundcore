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
