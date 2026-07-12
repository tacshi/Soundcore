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
}
