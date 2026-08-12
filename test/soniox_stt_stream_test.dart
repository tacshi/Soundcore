import 'package:anker_recorder/ai/soniox_stt_stream.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two-way translation uses exactly the configured language pair', () {
    final session = SonioxSttStreamSession(
      apiKey: 'test',
      language: 'fr',
      languageHints: const ['fr', 'de'],
      translation: const SonioxTranslationConfig.twoWay('zh', 'en'),
    );

    expect(session.configForTesting['language_hints'], ['zh', 'en']);
    expect(session.configForTesting['translation'], {
      'type': 'two_way',
      'language_a': 'zh',
      'language_b': 'en',
    });
  });

  test('one-way translation preserves recognition hints and target', () {
    final session = SonioxSttStreamSession(
      apiKey: 'test',
      language: 'en',
      languageHints: const ['zh', 'en', 'ja'],
      translation: const SonioxTranslationConfig.oneWay('ZH'),
    );

    expect(session.configForTesting['language_hints'], ['zh', 'en', 'ja']);
    expect(session.configForTesting['translation'], {
      'type': 'one_way',
      'target_language': 'zh',
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

  test('live transcription does not prime Soniox with product metadata', () {
    final session = SonioxSttStreamSession(
      apiKey: 'test',
      languageHints: const ['zh', 'en'],
    );

    expect(session.configForTesting, isNot(contains('context')));
  });
}
