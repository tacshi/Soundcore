import 'package:anker_recorder/state/transcript_store.dart';
import 'package:anker_recorder/state/recording.dart';
import 'package:anker_recorder/ai/speech_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy transcript data loads with empty speaker aliases', () {
    final data = TranscriptStore.decode({
      'byPath': {'/tmp/123.wav': '说话人 1：你好'},
      'byFileId': {'123': '说话人 1：你好'},
    });

    expect(data.byPath['/tmp/123.wav'], '说话人 1：你好');
    expect(data.byFileId[123], '说话人 1：你好');
    expect(data.aliasesByPath, isEmpty);
    expect(data.aliasesByFileId, isEmpty);
  });

  test('speaker aliases round-trip through transcript JSON data', () {
    final encoded = TranscriptStore.encode(
      byPath: const {'/tmp/123.wav': '说话人 1：你好'},
      byFileId: const {123: '说话人 1：你好'},
      aliasesByPath: const {
        '/tmp/123.wav': {'1': '张三'},
      },
      aliasesByFileId: const {
        123: {'1': '张三'},
      },
    );
    final data = TranscriptStore.decode(encoded);

    expect(data.aliasesByPath['/tmp/123.wav'], {'1': '张三'});
    expect(data.aliasesByFileId[123], {'1': '张三'});
  });

  test(
    'provider and revision-bound translation round-trip with legacy source',
    () {
      final data = TranscriptStore.decode(
        TranscriptStore.encode(
          byPath: const {'/tmp/123.wav': 'Original'},
          byFileId: const {123: 'Original'},
          aliasesByPath: const {},
          aliasesByFileId: const {},
          metadata: const {
            'file:123': TranscriptMetadata(
              provider: SttProvider.apple,
              sourceLanguage: 'en-US',
              revision: 2,
            ),
          },
          translations: const {
            'file:123': RecordingTranslation(
              text: '译文',
              sourceLanguage: 'en-US',
              targetLanguage: 'zh',
              provider: SttProvider.apple,
              sourceRevision: 2,
            ),
          },
        ),
      );
      expect(data.byFileId[123], 'Original');
      expect(data.metadata['file:123']!.provider, SttProvider.apple);
      expect(data.translations['file:123']!.sourceRevision, 2);
      expect(data.translations['file:123']!.text, '译文');
      final malformed = TranscriptStore.decode({
        'translations': {
          'file:123': {'text': 5},
        },
      });
      expect(malformed.translations, isEmpty);
    },
  );
}
