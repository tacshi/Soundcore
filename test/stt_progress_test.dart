import 'dart:typed_data';

import 'package:anker_recorder/ai/progress_multipart.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipart file reports monotonic upload progress', () async {
    final updates = <int>[];
    final bytes = Uint8List(700 * 1024);
    final file = multipartFileWithProgress(
      field: 'file',
      bytes: bytes,
      filename: 'recording.ogg',
      onProgress: (sent, _) => updates.add(sent),
    );

    await file.finalize().drain<void>();

    expect(updates.first, 0);
    expect(updates.last, bytes.length);
    expect(updates, orderedEquals(updates.toList()..sort()));
  });

  test('upload fraction is bounded', () {
    expect(
      const SttFileProgress(
        SttFileStage.uploading,
        uploadedBytes: 50,
        totalBytes: 100,
      ).fraction,
      0.5,
    );
    expect(
      const SttFileProgress(
        SttFileStage.uploading,
        uploadedBytes: 120,
        totalBytes: 100,
      ).fraction,
      1,
    );
  });
}
