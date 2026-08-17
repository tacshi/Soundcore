import 'dart:async';
import 'dart:typed_data';

enum SttDisplayMode { transcription, translation, conversation }

enum SonioxTranslationKind { none, oneWay, twoWay }

class SonioxTranslationConfig {
  const SonioxTranslationConfig.none()
    : kind = SonioxTranslationKind.none,
      targetLanguage = null,
      languageA = null,
      languageB = null;

  const SonioxTranslationConfig.oneWay(this.targetLanguage)
    : kind = SonioxTranslationKind.oneWay,
      languageA = null,
      languageB = null;

  const SonioxTranslationConfig.twoWay(this.languageA, this.languageB)
    : kind = SonioxTranslationKind.twoWay,
      targetLanguage = null;

  final SonioxTranslationKind kind;
  final String? targetLanguage;
  final String? languageA;
  final String? languageB;

  Map<String, dynamic>? toApiJson() {
    switch (kind) {
      case SonioxTranslationKind.none:
        return null;
      case SonioxTranslationKind.oneWay:
        final target = targetLanguage?.trim().toLowerCase();
        if (target == null || target.isEmpty) return null;
        return {'type': 'one_way', 'target_language': target};
      case SonioxTranslationKind.twoWay:
        final a = languageA?.trim().toLowerCase();
        final b = languageB?.trim().toLowerCase();
        if (a == null || a.isEmpty || b == null || b.isEmpty || a == b) {
          return null;
        }
        return {'type': 'two_way', 'language_a': a, 'language_b': b};
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

/// One diarized speaker found in a completed transcript.
class TranscriptSpeaker {
  const TranscriptSpeaker({
    required this.id,
    required this.defaultLabel,
    required this.displayLabel,
  });

  /// Provider-assigned identifier, scoped to one recording.
  final String id;
  final String defaultLabel;
  final String displayLabel;
}

final RegExp _transcriptSpeakerPrefix = RegExp(
  r'^说话人\s+([^：\r\n]+)：',
  multiLine: true,
);

/// Extract diarized speakers in first-appearance order.
List<TranscriptSpeaker> extractTranscriptSpeakers(
  String transcript, {
  Map<String, String> aliases = const {},
}) {
  final seen = <String>{};
  final speakers = <TranscriptSpeaker>[];
  for (final match in _transcriptSpeakerPrefix.allMatches(transcript)) {
    final id = match.group(1)!.trim();
    if (id.isEmpty || !seen.add(id)) continue;
    final defaultLabel = '说话人 $id';
    final alias = aliases[id]?.trim();
    speakers.add(
      TranscriptSpeaker(
        id: id,
        defaultLabel: defaultLabel,
        displayLabel: alias == null || alias.isEmpty ? defaultLabel : alias,
      ),
    );
  }
  return speakers;
}

/// Apply recording-specific aliases only to canonical line-start prefixes.
String applyTranscriptSpeakerAliases(
  String transcript,
  Map<String, String> aliases,
) {
  if (transcript.isEmpty || aliases.isEmpty) return transcript;
  return transcript.replaceAllMapped(_transcriptSpeakerPrefix, (match) {
    final id = match.group(1)!.trim();
    final alias = aliases[id]?.trim();
    return alias == null || alias.isEmpty ? match.group(0)! : '$alias：';
  });
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

/// One cumulative translated turn in a Soniox real-time result snapshot.
class SttTranslationTurn {
  const SttTranslationTurn({
    required this.targetLanguage,
    required this.sourceLanguage,
    required this.text,
    required this.isFinal,
    this.sourceText = '',
  });

  final String targetLanguage;
  final String sourceLanguage;
  final String text;
  final bool isFinal;
  final String sourceText;
}

class SttSourceChunk {
  const SttSourceChunk({required this.language, required this.text});

  final String language;
  final String text;
}

/// Group contiguous Soniox translation tokens into directional turns.
///
/// Original tokens separate translated runs. This is intentional: Soniox
/// translations follow their source chunk but are not aligned token-for-token.
List<SttTranslationTurn> renderSonioxTranslationTurns(
  Iterable<dynamic> tokens,
) {
  final turns = <_MutableTranslationTurn>[];
  _MutableTranslationTurn? current;
  final source = StringBuffer();
  String sourceLanguage = '';
  var previousWasTranslation = false;

  for (final token in tokens) {
    if (token is! Map) {
      current = null;
      source.clear();
      sourceLanguage = '';
      previousWasTranslation = false;
      continue;
    }

    final text = '${token['text'] ?? ''}';
    if (RegExp(r'^<end>$', caseSensitive: false).hasMatch(text.trim())) {
      current = null;
      source.clear();
      sourceLanguage = '';
      previousWasTranslation = false;
      continue;
    }

    if (token['translation_status'] != 'translation') {
      current = null;
      final language = '${token['language'] ?? ''}'.trim().toLowerCase();
      if (text.isEmpty || language.isEmpty) {
        previousWasTranslation = false;
        continue;
      }
      if (previousWasTranslation || sourceLanguage != language) {
        source.clear();
        sourceLanguage = language;
      }
      source.write(text);
      previousWasTranslation = false;
      continue;
    }

    final targetLanguage = '${token['language'] ?? ''}'.trim().toLowerCase();
    final translatedSourceLanguage = '${token['source_language'] ?? ''}'
        .trim()
        .toLowerCase();
    if (text.isEmpty ||
        targetLanguage.isEmpty ||
        translatedSourceLanguage.isEmpty) {
      current = null;
      previousWasTranslation = true;
      continue;
    }

    if (current == null ||
        current.targetLanguage != targetLanguage ||
        current.sourceLanguage != translatedSourceLanguage) {
      current = _MutableTranslationTurn(
        targetLanguage: targetLanguage,
        sourceLanguage: translatedSourceLanguage,
        sourceText: sourceLanguage == translatedSourceLanguage
            ? normalizeSttText(source.toString())
            : '',
      );
      turns.add(current);
    }
    current.text.write(text);
    current.isFinal = current.isFinal && token['is_final'] == true;
    previousWasTranslation = true;
  }

  return [
    for (final turn in turns)
      if (normalizeSttText(turn.text.toString()).isNotEmpty)
        SttTranslationTurn(
          targetLanguage: turn.targetLanguage,
          sourceLanguage: turn.sourceLanguage,
          text: normalizeSttText(turn.text.toString()),
          isFinal: turn.isFinal,
          sourceText: turn.sourceText,
        ),
  ];
}

/// Return source speech at the tail of a snapshot that has not received any
/// translation tokens yet.
SttSourceChunk? findSonioxPendingTranslationSource(Iterable<dynamic> tokens) {
  final source = StringBuffer();
  String language = '';

  for (final token in tokens) {
    if (token is! Map) {
      source.clear();
      language = '';
      continue;
    }
    final text = '${token['text'] ?? ''}';
    if (RegExp(r'^<end>$', caseSensitive: false).hasMatch(text.trim()) ||
        token['translation_status'] == 'translation') {
      source.clear();
      language = '';
      continue;
    }
    final tokenLanguage = '${token['language'] ?? ''}'.trim().toLowerCase();
    if (text.isEmpty || tokenLanguage.isEmpty) continue;
    if (language != tokenLanguage) {
      source.clear();
      language = tokenLanguage;
    }
    source.write(text);
  }

  final text = normalizeSttText(source.toString());
  return text.isEmpty ? null : SttSourceChunk(language: language, text: text);
}

class _MutableTranslationTurn {
  _MutableTranslationTurn({
    required this.targetLanguage,
    required this.sourceLanguage,
    required this.sourceText,
  });

  final String targetLanguage;
  final String sourceLanguage;
  final String sourceText;
  final StringBuffer text = StringBuffer();
  bool isFinal = true;
}

/// Batch / file transcription result.
class SttResult {
  const SttResult({
    required this.text,
    this.durationSec,
    this.language,
    this.sourcePath,
  });

  final String text;
  final double? durationSec;
  final String? language;
  final String? sourcePath;
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
    this.translationTurns = const [],
    this.pendingTranslationSource,
  });

  /// `created` | `partial` | `done` | `error` | `closed`
  final String type;
  final String text;
  final bool isFinal;
  final bool speechFinal;
  final double? durationSec;
  final String? error;
  final List<SttTranslationTurn> translationTurns;
  final SttSourceChunk? pendingTranslationSource;
}

/// Common interface for PCM16 LE streaming STT.
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
