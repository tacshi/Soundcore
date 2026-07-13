import '../protocol/models.dart';

/// Pure ordering/deduplication helpers for device and local recording lists.
class ExportCatalog {
  ExportCatalog._();

  static final RegExp _supportedName = RegExp(
    r'^\d+(?:_[^/\\]+)?\.(?:wav|opus(?:\.bin)?)$',
  );

  static bool isSupportedExportPath(String path) =>
      _supportedName.hasMatch(path.split('/').last);

  static int? fileIdFromPath(String path) {
    final name = path.split('/').last;
    final match = RegExp(r'^(\d+)').firstMatch(name);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static String? _suffixForPath(String path) {
    final name = path.split('/').last;
    for (final suffix in const ['.opus.bin', '.opus', '.wav']) {
      if (name.endsWith(suffix)) return suffix;
    }
    return null;
  }

  /// Builds a user-friendly filename while retaining the leading device file
  /// id used to match the recording with the device inventory.
  static String renamedFileName(String path, String label) {
    final name = path.split('/').last;
    final id = fileIdFromPath(path);
    if (id == null) throw ArgumentError('无法识别录音编号');

    final suffix = _suffixForPath(name);
    if (suffix == null) throw ArgumentError('不支持此文件格式');
    final trimmed = label.trim();
    if (trimmed.isEmpty) throw ArgumentError('请输入文件名');
    if (trimmed.length > 100) throw ArgumentError('文件名不能超过 100 个字符');
    if (RegExp(r'[\\/:*?"<>|\x00-\x1f]').hasMatch(trimmed)) {
      throw ArgumentError('文件名不能包含 \\ / : * ? " < > |');
    }
    return '${id}_$trimmed$suffix';
  }

  static String editableLabelFromPath(String path) {
    final name = path.split('/').last;
    final id = fileIdFromPath(path);
    if (id == null) return name;
    final suffix = _suffixForPath(name);
    if (suffix == null) return name;
    final stem = name.substring(0, name.length - suffix.length);
    final prefix = '${id}_';
    return stem.startsWith(prefix) ? stem.substring(prefix.length) : '';
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
    final candidatePlayable = candidate.endsWith('.wav');
    final currentPlayable = current.endsWith('.wav');
    if (candidatePlayable != currentPlayable) return candidatePlayable;
    final candidateRaw = candidate.endsWith('.opus.bin');
    final currentRaw = current.endsWith('.opus.bin');
    if (candidateRaw != currentRaw) return !candidateRaw;
    return candidate.compareTo(current) > 0;
  }
}
