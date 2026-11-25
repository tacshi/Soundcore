import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

File recordingHighlightsFile(String audioPath, int fileId) =>
    File(p.join(p.dirname(audioPath), '$fileId.highlights.json'));

Future<List<int>> readRecordingHighlights(String audioPath, int fileId) async {
  final file = recordingHighlightsFile(audioPath, fileId);
  try {
    final data = jsonDecode(await file.readAsString());
    if (data is List) {
      return data.whereType<int>().where((offset) => offset >= 0).toList();
    }
  } on FileSystemException {
    // Earlier downloads do not have a highlights file.
  } on FormatException {
    // A damaged sidecar must not prevent playback.
  }
  return const [];
}
