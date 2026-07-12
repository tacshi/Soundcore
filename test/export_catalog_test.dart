import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/state/export_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local exports are deduplicated and sorted newest first', () {
    final paths = ExportCatalog.newestPathsFirst([
      '/exports/1710000000.opus.bin',
      '/exports/1730000000.opus',
      '/exports/1710000000.opus',
      '/exports/1720000000.opus',
    ]);

    expect(paths, [
      '/exports/1730000000.opus',
      '/exports/1720000000.opus',
      '/exports/1710000000.opus',
    ]);
  });

  test('standard WAV is preferred over raw Opus for the same recording', () {
    final result = ExportCatalog.newestPathsFirst([
      '/exports/1730000000.opus',
      '/exports/1730000000.wav',
    ]);

    expect(result, ['/exports/1730000000.wav']);
  });

  test('unexported device recordings are newest first', () {
    final missing = ExportCatalog.unexportedNewestFirst(
      [
        OfflineFileEntry(fileId: 100, sizeBytes: 160),
        OfflineFileEntry(fileId: 300, sizeBytes: 160),
        OfflineFileEntry(fileId: 200, sizeBytes: 160),
      ],
      {200},
    );

    expect(missing.map((file) => file.fileId), [300, 100]);
  });
}
