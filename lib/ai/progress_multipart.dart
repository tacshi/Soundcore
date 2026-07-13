import 'dart:typed_data';

import 'package:http/http.dart' as http;

http.MultipartFile multipartFileWithProgress({
  required String field,
  required Uint8List bytes,
  required String filename,
  required void Function(int sent, int total) onProgress,
}) {
  const chunkSize = 256 * 1024;

  Stream<List<int>> chunks() async* {
    final total = bytes.length;
    onProgress(0, total);
    for (var offset = 0; offset < total; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, total);
      yield Uint8List.sublistView(bytes, offset, end);
      onProgress(end, total);
    }
  }

  return http.MultipartFile(field, chunks(), bytes.length, filename: filename);
}
