import '../protocol/models.dart';

/// Pure ordering/deduplication helpers for device and local recording lists.
class ExportCatalog {
  ExportCatalog._();

  static int? fileIdFromPath(String path) {
    final name = path.split('/').last;
    final match = RegExp(r'^(\d+)').firstMatch(name);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// One local row per recording, ordered by the timestamp-shaped file id.
  static List<String> newestPathsFirst(Iterable<String> paths) {
    final byId = <int, String>{};
    final withoutId = <String>{};
    for (final path in paths) {
      final id = fileIdFromPath(path);
      if (id == null) {
        withoutId.add(path);
        continue;
      }
      final current = byId[id];
      if (current == null || _prefer(path, current)) byId[id] = path;
    }

    final ids = byId.keys.toList()..sort((a, b) => b.compareTo(a));
    final fallback = withoutId.toList()..sort((a, b) => b.compareTo(a));
    return [...ids.map((id) => byId[id]!), ...fallback];
  }

  static List<OfflineFileEntry> unexportedNewestFirst(
    Iterable<OfflineFileEntry> deviceFiles,
    Set<int> exportedIds,
  ) {
    final missing = deviceFiles
        .where((file) => !exportedIds.contains(file.fileId))
        .toList();
    missing.sort((a, b) {
      final aTime = a.endTime ?? a.fileId;
      final bTime = b.endTime ?? b.fileId;
      return bTime.compareTo(aTime);
    });
    return missing;
  }

  static bool _prefer(String candidate, String current) {
    final candidateRaw = candidate.endsWith('.opus.bin');
    final currentRaw = current.endsWith('.opus.bin');
    if (candidateRaw != currentRaw) return !candidateRaw;
    return candidate.compareTo(current) > 0;
  }
}
