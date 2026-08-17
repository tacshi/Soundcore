import 'package:anker_recorder/state/transcript_store.dart';
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
}
