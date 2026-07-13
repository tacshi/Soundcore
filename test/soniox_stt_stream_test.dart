import 'package:anker_recorder/ai/soniox_stt_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two-way translation uses exactly the configured language pair', () {
    final session = SonioxSttStreamSession(
      apiKey: 'test',
      language: 'fr',
      languageHints: const ['fr', 'de'],
      translationLanguageA: 'zh',
      translationLanguageB: 'en',
    );

    expect(session.configForTesting['language_hints'], ['zh', 'en']);
    expect(session.configForTesting['translation'], {
      'type': 'two_way',
      'language_a': 'zh',
      'language_b': 'en',
    });
  });

  test('normal Soniox transcription has no translation configuration', () {
    final session = SonioxSttStreamSession(
      apiKey: 'test',
      languageHints: const ['zh', 'en'],
    );

    expect(session.configForTesting, isNot(contains('translation')));
    expect(session.configForTesting['language_hints'], ['zh', 'en']);
  });
}
