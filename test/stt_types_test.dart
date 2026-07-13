import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('renders Soniox speaker changes as labeled sections', () {
    final text = renderSonioxTokens([
      {'text': '你好', 'speaker': '1'},
      {'text': '。', 'speaker': '1'},
      {'text': ' Hello', 'speaker': '2'},
      {'text': ' there.', 'speaker': '2'},
    ]);

    expect(text, '说话人 1：你好。\n说话人 2：Hello there.');
  });

  test('keeps unlabeled tokens and ignores translations and endpoints', () {
    final text = renderSonioxTokens([
      {'text': 'First', 'speaker': 1},
      {'text': '<end>', 'speaker': 1},
      {'text': ' translated', 'translation_status': 'translation'},
      {'text': ' continued'},
    ]);

    expect(text, '说话人 1：First\ncontinued');
  });

  test('groups directional translation runs without token alignment', () {
    final turns = renderSonioxTranslationTurns([
      {
        'text': 'Good morning',
        'translation_status': 'original',
        'language': 'en',
        'is_final': true,
      },
      {
        'text': '早上',
        'translation_status': 'translation',
        'language': 'zh',
        'source_language': 'en',
        'is_final': true,
      },
      {
        'text': '好',
        'translation_status': 'translation',
        'language': 'zh',
        'source_language': 'en',
        'is_final': true,
      },
      {
        'text': '你好',
        'translation_status': 'original',
        'language': 'zh',
        'is_final': true,
      },
      {
        'text': 'Hello',
        'translation_status': 'translation',
        'language': 'en',
        'source_language': 'zh',
        'is_final': false,
      },
      {
        'text': 'Bonjour',
        'translation_status': 'none',
        'language': 'fr',
        'is_final': true,
      },
    ]);

    expect(turns, hasLength(2));
    expect(turns[0].targetLanguage, 'zh');
    expect(turns[0].sourceLanguage, 'en');
    expect(turns[0].text, '早上好');
    expect(turns[0].isFinal, isTrue);
    expect(turns[1].targetLanguage, 'en');
    expect(turns[1].sourceLanguage, 'zh');
    expect(turns[1].text, 'Hello');
    expect(turns[1].isFinal, isFalse);
  });

  test('recomputed snapshots replace a partial translation turn', () {
    final partial = renderSonioxTranslationTurns([
      {
        'text': 'Hel',
        'translation_status': 'translation',
        'language': 'en',
        'source_language': 'zh',
        'is_final': false,
      },
    ]);
    final completed = renderSonioxTranslationTurns([
      {
        'text': 'Hello',
        'translation_status': 'translation',
        'language': 'en',
        'source_language': 'zh',
        'is_final': true,
      },
    ]);

    expect(partial.single.text, 'Hel');
    expect(partial.single.isFinal, isFalse);
    expect(completed.single.text, 'Hello');
    expect(completed.single.isFinal, isTrue);
  });
}
