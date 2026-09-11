import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/stt_types.dart';
import '../../protocol/models.dart';
import '../../state/recorder_controller.dart';
import '../recording_navigation.dart';
import '../../theme/app_theme.dart';
import '../../wifi/wifi_export_service.dart';
import '../widgets/widgets.dart';

/// On-device + local export file list (embedded in Home when not live recording).
///
/// Two tabs: **已导出** (local) and **设备端** (on-device inventory).
class FilesBody extends StatefulWidget {
  const FilesBody({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 0),
  });

  final EdgeInsets padding;

  /// Display cleanup: Soniox `<end>` → newline (see [normalizeSttText]).
  static String cleanTranscript(String raw) => normalizeSttText(raw);

  static String formatDuration(Duration? duration) {
    if (duration == null) return '--:--';
    final seconds = duration.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;
    final minuteText = minutes.toString().padLeft(2, '0');
    final secondText = remainingSeconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minuteText:$secondText'
        : '$minuteText:$secondText';
  }

  @override
  State<FilesBody> createState() => _FilesBodyState();
}

class _FilesBodyState extends State<FilesBody>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final exporting = c.isExporting || c.needsWifiJoin;
    final busy =
        c.phase == AppPhase.busy || exporting || c.downloadingFileId != null;
    final localPaths = c.exportedPaths.toList();
    final localCount = c.exportedPaths.length;
    final deviceCount = c.files.length;

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExportBanner(controller: c),
          if (c.errorMessage != null) ...[
            const SizedBox(height: 12),
            SurfaceCard(
              borderColor: AppColors.coral.withValues(alpha: 0.4),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: AppColors.coral,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.errorMessage!,
                      style: const TextStyle(
                        color: AppColors.coral,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: TabBar(
              controller: _tabs,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.label,
              indicatorColor: AppColors.accent,
              indicatorWeight: 2,
              labelColor: AppColors.accent,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              unselectedLabelStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w500, fontSize: 13),
              tabs: [
                Tab(text: localCount > 0 ? '本地 ($localCount)' : '本地'),
                Tab(text: deviceCount > 0 ? '设备端 ($deviceCount)' : '设备端'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                // ── 已导出（本地） ─────────────────────────────────
                _LocalExportsTab(paths: localPaths),
                // ── 设备端 ────────────────────────────────────────
                _DeviceFilesTab(busy: busy),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalExportsTab extends StatefulWidget {
  const _LocalExportsTab({required this.paths});

  final List<String> paths;

  @override
  State<_LocalExportsTab> createState() => _LocalExportsTabState();
}

class _LocalExportsTabState extends State<_LocalExportsTab> {
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _saving = false;
  bool _deleting = false;

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  Future<void> _saveSelected(BuildContext context) async {
    if (_selected.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final paths = await context
          .read<RecorderController>()
          .prepareLocalSharePaths(_selected);
      if (!context.mounted) return;
      if (paths.isEmpty) throw StateError('所选文件不存在');

      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: paths.map(XFile.new).toList(),
          title: '保存或分享录音',
          subject: '录音导出',
          sharePositionOrigin: origin,
        ),
      );
      if (!mounted) return;
      if (result.status == ShareResultStatus.success) {
        setState(() {
          _selecting = false;
          _selected.clear();
        });
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开分享菜单，请重试')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteSelected(BuildContext context) async {
    if (_selected.isEmpty || _saving || _deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除所选录音？'),
        content: Text('将永久删除所选的 ${_selected.length} 个本地录音，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除', style: TextStyle(color: AppColors.coral)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    setState(() => _deleting = true);
    final result = await context.read<RecorderController>().deleteLocalExports(
      _selected,
    );
    if (!context.mounted) return;
    setState(() {
      _deleting = false;
      _selecting = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.failed.isEmpty
              ? '已删除 ${result.deleted} 个录音'
              : '已删除 ${result.deleted} 个录音，${result.failed.length} 个失败',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    bool selectable(String path) => !c
        .recordingView(
          RecordingReference(fileId: c.fileIdFromPath(path), path: path),
        )
        .audioLocked;
    _selected.removeWhere(
      (path) => !widget.paths.contains(path) || !selectable(path),
    );
    final selectablePaths = widget.paths.where(selectable).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_selecting)
          _SelectionToolbar(
            count: _selected.length,
            allSelected:
                selectablePaths.isNotEmpty &&
                _selected.length == selectablePaths.length,
            saving: _saving,
            saveLabel: _saving ? '保存中…' : '保存所选',
            onSelectAll: _saving || _deleting || selectablePaths.isEmpty
                ? null
                : () => setState(() => _selected.addAll(selectablePaths)),
            onClear: _saving || _deleting || _selected.isEmpty
                ? null
                : () => setState(_selected.clear),
            onCancel: _saving || _deleting ? null : _toggleSelecting,
            onSave: _selected.isEmpty || _saving || _deleting
                ? null
                : () => _saveSelected(context),
            onDelete: _selected.isEmpty || _saving || _deleting
                ? null
                : () => _deleteSelected(context),
            deleting: _deleting,
          ),
        Expanded(
          child: RefreshIndicator(
            key: const ValueKey('local-recordings-refresh'),
            onRefresh: c.refreshLocalFiles,
            notificationPredicate: (notification) =>
                !_selecting &&
                !_saving &&
                !_deleting &&
                !c.isLiveSession &&
                !c.isExporting &&
                !c.needsWifiJoin &&
                notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical,
            child: widget.paths.isEmpty
                ? const _ScrollableHint(
                    hint: _Hint(
                      icon: Icons.folder_open_rounded,
                      title: '暂无本地录音',
                      body: '用设备开始录音，或在「设备端」下载已有录音。',
                    ),
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    key: const PageStorageKey('local-recordings-scroll'),
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: widget.paths.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.border),
                    itemBuilder: (context, i) {
                      final path = widget.paths[i];
                      return _LocalExportCard(
                        path: path,
                        selecting: _selecting,
                        selected: _selected.contains(path),
                        onSelected: _saving || _deleting || !selectable(path)
                            ? null
                            : () => setState(() {
                                if (!_selected.add(path)) {
                                  _selected.remove(path);
                                }
                              }),
                        onLongPress: _saving || _deleting || !selectable(path)
                            ? null
                            : () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _selecting = true;
                                  _selected.add(path);
                                });
                              },
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.count,
    required this.saveLabel,
    required this.allSelected,
    this.onSelectAll,
    this.onClear,
    this.onCancel,
    this.onSave,
    this.onDelete,
    this.saving = false,
    this.deleting = false,
  });
  final int count;
  final String saveLabel;
  final bool allSelected;
  final VoidCallback? onSelectAll;
  final VoidCallback? onClear;
  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  final VoidCallback? onDelete;
  final bool saving;
  final bool deleting;

  Widget _progress() => const SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          constraints.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(14) > 18;
      final textButtonStyle = TextButton.styleFrom(
        minimumSize: const Size(44, 48),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      );
      final iconButtonStyle = IconButton.styleFrom(
        minimumSize: const Size.square(48),
        visualDensity: VisualDensity.standard,
      );
      return Row(
        key: const ValueKey('recording-selection-toolbar'),
        children: [
          if (compact)
            IconButton(
              tooltip: allSelected ? '清空' : '全选',
              style: iconButtonStyle,
              onPressed: allSelected ? onClear : onSelectAll,
              icon: Icon(
                allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
              ),
            )
          else ...[
            TextButton(
              style: textButtonStyle,
              onPressed: onSelectAll,
              child: const Text('全选'),
            ),
            TextButton(
              style: textButtonStyle,
              onPressed: onClear,
              child: const Text('清空'),
            ),
          ],
          Expanded(
            child: Semantics(
              label: '已选 $count 项',
              excludeSemantics: true,
              child: Text(
                compact ? '$count 项' : '已选 $count 项',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: saveLabel,
            style: iconButtonStyle,
            onPressed: onSave,
            icon: saving ? _progress() : const Icon(Icons.save_alt_rounded),
          ),
          IconButton(
            tooltip: deleting ? '删除中…' : '删除所选',
            onPressed: onDelete,
            style: iconButtonStyle,
            color: AppColors.coral,
            icon: deleting
                ? _progress()
                : const Icon(Icons.delete_outline_rounded),
          ),
          IconButton(
            tooltip: '取消选择',
            style: iconButtonStyle,
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      );
    },
  );
}

class _DeviceFilesTab extends StatelessWidget {
  const _DeviceFilesTab({required this.busy});

  final bool busy;

  Future<void> _deleteSelected(
    BuildContext context,
    RecorderController controller,
  ) async {
    if (controller.selectedFileIds.isEmpty) return;
    final count = controller.selectedFileIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除设备端录音？'),
        content: Text('将永久删除设备上的 $count 个录音，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除', style: TextStyle(color: AppColors.coral)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final deleted = await controller.deleteSelectedDeviceFiles();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已删除 $deleted 个设备端录音')));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final downloadableCount = c.unexportedFiles.length;
    final selectedDownloadableCount = c.selectedUnexportedFiles.length;
    final selectedLocked = c.selectedFileIds.any(
      (id) => c
          .recordingView(
            RecordingReference(fileId: id, path: c.localPathFor(id)),
          )
          .audioLocked,
    );
    final anyDownloadLocked = c.unexportedFiles.any(
      (file) =>
          c.recordingView(RecordingReference(fileId: file.fileId)).audioLocked,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!c.selecting && downloadableCount > 0)
          OutlinedButton.icon(
            onPressed: c.connected && !busy && !anyDownloadLocked
                ? () => startWifiExport(context, c)
                : null,
            icon: const Icon(Icons.wifi_rounded),
            label: const Text('通过 Wi-Fi 下载全部'),
          ),
        if (c.selecting && c.files.isNotEmpty)
          _SelectionToolbar(
            count: c.selectedFileIds.length,
            allSelected:
                c.files.isNotEmpty &&
                c.files
                    .where(
                      (file) => !c
                          .recordingView(
                            RecordingReference(fileId: file.fileId),
                          )
                          .audioLocked,
                    )
                    .every((file) => c.selectedFileIds.contains(file.fileId)),
            saveLabel: selectedDownloadableCount == 0 ? '所选已下载' : '下载所选',
            onSelectAll: busy ? null : c.selectAllFiles,
            onClear: busy || c.selectedFileIds.isEmpty
                ? null
                : c.clearSelection,
            onCancel: busy ? null : c.toggleSelecting,
            onSave: busy || selectedLocked || selectedDownloadableCount == 0
                ? null
                : () => startWifiExport(context, c),
            onDelete: busy || selectedLocked || c.selectedFileIds.isEmpty
                ? null
                : () => _deleteSelected(context, c),
          ),
        if (c.selecting || downloadableCount > 0) const SizedBox(height: 10),
        Expanded(
          child: RefreshIndicator(
            key: const ValueKey('device-recordings-refresh'),
            onRefresh: c.refreshDeviceFiles,
            notificationPredicate: (notification) =>
                c.connected &&
                !busy &&
                !c.selecting &&
                notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical,
            child: !c.connected
                ? const _ScrollableHint(
                    hint: _Hint(
                      icon: Icons.link_off_rounded,
                      title: '未连接设备',
                      body: '点右上角「扫描」连接 soundcore Work，即可列出设备端录音。',
                    ),
                  )
                : c.files.isEmpty
                ? const _ScrollableHint(
                    hint: _Hint(
                      icon: Icons.inbox_rounded,
                      title: '设备上暂无录音',
                      body: '下拉刷新录音列表。',
                      productImage: 'assets/product/d3200_device_white.webp',
                    ),
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    key: const PageStorageKey('device-recordings-scroll'),
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: c.files.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.border),
                    itemBuilder: (context, i) {
                      final f = c.files[i];
                      final selected = c.selectedFileIds.contains(f.fileId);
                      final hasLocal = c.localPathFor(f.fileId) != null;
                      final downloading = c.downloadingFileId == f.fileId;
                      final locked = c
                          .recordingView(
                            RecordingReference(
                              fileId: f.fileId,
                              path: c.localPathFor(f.fileId),
                            ),
                          )
                          .audioLocked;
                      return _DeviceFileTile(
                        file: f,
                        selecting: c.selecting,
                        selected: selected,
                        hasLocal: hasLocal,
                        downloading: downloading,
                        onTap: c.selecting
                            ? (busy || locked
                                  ? null
                                  : () => c.toggleFileSelected(f.fileId))
                            : () => RecordingNavigation.open(
                                context,
                                RecordingReference(
                                  fileId: f.fileId,
                                  path: c.localPathFor(f.fileId),
                                ),
                              ),
                        onLongPress: busy || locked
                            ? null
                            : () {
                                HapticFeedback.selectionClick();
                                if (!c.selecting) {
                                  c.selectOnly(f.fileId);
                                } else if (!selected) {
                                  c.toggleFileSelected(f.fileId);
                                }
                              },
                        onExport: busy || hasLocal || locked
                            ? null
                            : () => c.downloadFileOverBle(f),
                        onDelete: busy || locked
                            ? null
                            : () => c.deleteFile(f.fileId),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _LocalExportCard extends StatelessWidget {
  const _LocalExportCard({
    required this.path,
    this.selecting = false,
    this.selected = false,
    this.onSelected,
    this.onLongPress,
  });

  final String path;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelected;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final reference = RecordingReference(
      fileId: c.fileIdFromPath(path),
      path: path,
    );
    final recording = c.recordingView(reference);
    final text = FilesBody.cleanTranscript(recording.text);
    final loaded = c.playingPath == path;
    final duration = FilesBody.formatDuration(c.localDurationForPath(path));
    final status = recording.audioLocked
        ? (recording.live ? '录音中' : '正在保存')
        : recording.processing
        ? '处理中'
        : recording.error != null
        ? '处理失败'
        : text.isNotEmpty
        ? '已转写'
        : null;
    return Material(
      color: selected
          ? AppColors.mint.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        key: ValueKey('recording-row-$path'),
        onLongPress: onLongPress,
        onTap: selecting
            ? (recording.audioLocked ? null : onSelected)
            : () => RecordingNavigation.open(context, reference),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selecting)
                Checkbox(
                  value: selected,
                  onChanged: recording.audioLocked || onSelected == null
                      ? null
                      : (_) => onSelected?.call(),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 12),
                  child: Icon(
                    loaded
                        ? Icons.graphic_eq_rounded
                        : Icons.audio_file_outlined,
                    color: loaded ? AppColors.accent : AppColors.textMuted,
                    size: 24,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recording.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$duration${status == null ? '' : ' · $status'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: recording.error != null
                            ? AppColors.coral
                            : AppColors.textSecondary,
                      ),
                    ),
                    if (text.isNotEmpty && !selecting) ...[
                      const SizedBox(height: 8),
                      Text(
                        text,
                        key: ValueKey('recording-preview-$path'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!selecting)
                const Padding(
                  padding: EdgeInsets.only(top: 3, left: 8),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textMuted,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kick SoftAP export + join sheet (shared by Home / Files body).
Future<void> startWifiExport(BuildContext context, RecorderController c) async {
  final ep = await c.beginWifiExport();
  if (ep == null || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _WifiJoinSheet(controller: c),
  );
}

class _ExportBanner extends StatelessWidget {
  const _ExportBanner({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.exportProgress;
    if (p.phase == ExportPhase.idle) return const SizedBox.shrink();

    Color color;
    IconData icon;
    switch (p.phase) {
      case ExportPhase.error:
        color = AppColors.coral;
        icon = Icons.error_outline_rounded;
      case ExportPhase.done:
        color = AppColors.mint;
        icon = Icons.check_circle_outline_rounded;
      case ExportPhase.awaitJoin:
        color = AppColors.amber;
        icon = Icons.wifi_rounded;
      default:
        color = AppColors.accent;
        icon = Icons.cloud_download_rounded;
    }

    return SurfaceCard(
      borderColor: color.withValues(alpha: 0.45),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  p.message.isNotEmpty ? p.message : p.phase.name,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              if (p.phase == ExportPhase.done || p.phase == ExportPhase.error)
                IconButton(
                  tooltip: '关闭',
                  onPressed: controller.clearExportState,
                  icon: const Icon(Icons.close, size: 18),
                  color: AppColors.textMuted,
                )
              else if (p.phase != ExportPhase.idle)
                TextButton(
                  onPressed: controller.cancelWifiExport,
                  child: const Text('取消'),
                ),
            ],
          ),
          if (p.phase == ExportPhase.transferring ||
              p.phase == ExportPhase.connectingWs) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: p.phase == ExportPhase.transferring
                    ? p.batchFraction
                    : null,
                minHeight: 6,
                backgroundColor: AppColors.border,
                color: color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              p.totalFiles > 0
                  ? '文件 ${p.currentFileIndex.clamp(0, p.totalFiles) + (p.phase == ExportPhase.transferring && p.currentFileIndex < p.totalFiles ? 1 : 0)} / ${p.totalFiles}'
                        '${p.bytesExpected > 0 ? ' · ${(p.bytesReceived / 1024).toStringAsFixed(1)} / ${(p.bytesExpected / 1024).toStringAsFixed(1)} KB' : ''}'
                  : '',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
          if (p.savedPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '已保存到应用 Documents/AnkerRecorder/exports\n'
              '${p.savedPaths.map((e) => e.split('/').last).join(', ')}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
          if (p.error != null) ...[
            const SizedBox(height: 6),
            Text(
              p.error!,
              style: const TextStyle(color: AppColors.coral, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _WifiJoinSheet extends StatefulWidget {
  const _WifiJoinSheet({required this.controller});

  final RecorderController controller;

  @override
  State<_WifiJoinSheet> createState() => _WifiJoinSheetState();
}

class _WifiJoinSheetState extends State<_WifiJoinSheet> {
  bool _running = false;
  bool _reachable = false;
  bool _probing = false;
  bool _autoStarted = false;
  Timer? _probeTimer;

  @override
  void initState() {
    super.initState();
    // Match the SDK's Wi-Fi check without opening the device's WSS port first.
    _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) => _probe());
    WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    if (!mounted || _running || _probing) return;
    _probing = true;
    final ok = await widget.controller.isOnSoftApNetwork();
    if (!mounted) return;
    _probing = false;
    if (ok != _reachable) {
      setState(() => _reachable = ok);
    }
    if (ok && !_autoStarted && !_running) {
      _autoStarted = true;
      await _continueExport();
    }
  }

  Future<void> _continueExport() async {
    if (_running) return;
    // A manual tap after a failed auto-attempt still counts as "started" —
    // stops _probe() from silently racing another auto-retry underneath it.
    _autoStarted = true;
    setState(() => _running = true);
    final c = widget.controller;
    final paths = await c.continueWifiExport();
    if (!mounted) return;
    if (paths.isNotEmpty || c.exportProgress.phase == ExportPhase.done) {
      Navigator.of(context).pop();
      final bleNote = c.connected ? '' : ' 蓝牙已断开，正在自动重连…';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            paths.isEmpty ? '导出完成$bleNote' : '已保存 ${paths.length} 个文件$bleNote',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      // Leave _autoStarted set: only the explicit "开始导出" button retries
      // from here, so the error message below doesn't get silently cleared
      // by another background auto-attempt every 2s.
      setState(() => _running = false);
      // The inline error card below is easy to miss (esp. on an auto-fired
      // attempt the user didn't watch) — a toast makes the failure obvious.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(c.exportProgress.error ?? c.errorMessage ?? '导出失败'),
          backgroundColor: AppColors.coral,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _openWifiSettings() async {
    if (Platform.isMacOS) {
      try {
        // Opens System Settings → Wi‑Fi on modern macOS.
        await Process.run('open', [
          'x-apple.systempreferences:com.apple.wifi-settings-extension',
        ]);
      } catch (_) {
        try {
          await Process.run('open', [
            '/System/Library/PreferencePanes/Network.prefPane',
          ]);
        } catch (_) {}
      }
      return;
    }
    if (Platform.isIOS) {
      // App-Prefs:root=WIFI is a private, undocumented scheme (not usable
      // for App Store review) but works for sideloaded/dev-signed installs
      // like this one and jumps straight to the Wi‑Fi pane. If it's ever
      // blocked by the OS, fall back to this app's own Settings page.
      final opened = await launchUrl(
        Uri.parse('App-Prefs:root=WIFI'),
        mode: LaunchMode.externalApplication,
      ).catchError((_) => false);
      if (opened) return;
      await openAppSettings();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请返回「设置」首页，点击「无线局域网」加入热点'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _copyJoinHint(String ssid, String password) async {
    await Clipboard.setData(
      ClipboardData(
        text:
            '网络名称：$ssid\n密码：$password\n'
            '（若列表里找不到，用「其他…」手动加入，可能为隐藏网络）',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制 SSID 与密码')));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final p = c.exportProgress;
    final ssid = p.ssid ?? '—';
    final password = p.password ?? '—';
    final ep = p.endpoint;
    final transferring =
        _running ||
        p.phase == ExportPhase.connectingWs ||
        p.phase == ExportPhase.transferring;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              transferring ? '正在导出…' : 'Wi‑Fi 导出',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            // Step checklist
            _ExportStep(index: 1, title: '设备已应答热点（IP 已就绪）', done: true),
            _ExportStep(
              index: 2,
              title: _reachable ? '已连接到设备 Wi‑Fi' : '手动加入热点（可能隐藏）',
              done: _reachable || transferring,
              active: !_reachable && !transferring,
            ),
            _ExportStep(
              index: 3,
              title: transferring
                  ? (p.message.isNotEmpty ? p.message : '传输文件中…')
                  : '传输并保存到本机',
              done: p.phase == ExportPhase.done,
              active: transferring,
              last: true,
            ),
            const SizedBox(height: 12),
            SurfaceCard(
              borderColor: AppColors.amber.withValues(alpha: 0.45),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.visibility_off_outlined,
                    color: AppColors.amber,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'SSID「$ssid」是发给录音豆的热点名（与飞书相同：WiFi-时间戳）。\n'
                      '列表里经常看不到它——多为隐藏网络，请用系统「其他…」手动输入加入，'
                      '不要只在「其他网络」列表里找。\n'
                      '录音豆请保持开机并打开充电盒；热点为 2.4GHz，约需几秒才就绪。',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SurfaceCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  _CredRow(
                    label: 'SSID',
                    value: ssid,
                    onCopy: () => Clipboard.setData(ClipboardData(text: ssid)),
                  ),
                  const Divider(height: 18, color: AppColors.border),
                  _CredRow(
                    label: '密码',
                    value: password,
                    onCopy: () =>
                        Clipboard.setData(ClipboardData(text: password)),
                  ),
                  if (ep != null) ...[
                    const Divider(height: 18, color: AppColors.border),
                    _CredRow(
                      label: '端点',
                      value: ep.displayEndpoint,
                      onCopy: () => Clipboard.setData(
                        ClipboardData(text: ep.displayEndpoint),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AccentButton(
                    label: '打开 Wi‑Fi 设置',
                    icon: Icons.settings_rounded,
                    filled: false,
                    onPressed: transferring ? null : _openWifiSettings,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AccentButton(
                    label: '复制凭证',
                    icon: Icons.copy_all_rounded,
                    filled: false,
                    onPressed: transferring
                        ? null
                        : () => _copyJoinHint(ssid, password),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '加入成功后会自动开始导出；也可手动点下方按钮。'
              '检测仅检查本机网络，不会提前占用设备的 WebSocket 端口。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
            ),
            // Only shown before the first (automatic) attempt — once that's
            // resolved (success navigates away; failure shows p.error below
            // instead), this must not linger next to an idle "开始导出"
            // button implying a start that already stalled.
            if (_reachable && !transferring && !_autoStarted) ...[
              const SizedBox(height: 8),
              const Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.mint,
                    size: 16,
                  ),
                  SizedBox(width: 6),
                  Text(
                    '已检测到设备网络，正在开始导出…',
                    style: TextStyle(color: AppColors.mint, fontSize: 12),
                  ),
                ],
              ),
            ],
            if (transferring) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: p.phase == ExportPhase.transferring
                      ? p.batchFraction
                      : null,
                  minHeight: 6,
                  backgroundColor: AppColors.border,
                  color: AppColors.mint,
                ),
              ),
              if (p.totalFiles > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '文件 ${p.currentFileIndex.clamp(0, p.totalFiles) + (p.phase == ExportPhase.transferring && p.currentFileIndex < p.totalFiles ? 1 : 0)} / ${p.totalFiles}'
                  '${p.bytesExpected > 0 ? ' · ${(p.bytesReceived / 1024).toStringAsFixed(1)} / ${(p.bytesExpected / 1024).toStringAsFixed(1)} KB' : ''}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
            if (p.error != null) ...[
              const SizedBox(height: 8),
              Text(
                p.error!,
                style: const TextStyle(color: AppColors.coral, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            AccentButton(
              label: transferring
                  ? '导出中…'
                  : _reachable
                  ? '开始导出'
                  : '我已加入 Wi‑Fi — 继续',
              icon: Icons.download_done_rounded,
              color: AppColors.mint,
              onPressed: transferring ? null : _continueExport,
            ),
            const SizedBox(height: 10),
            AccentButton(
              label: '取消导出',
              filled: false,
              color: AppColors.textMuted,
              onPressed: () async {
                await c.cancelWifiExport();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportStep extends StatelessWidget {
  const _ExportStep({
    required this.index,
    required this.title,
    required this.done,
    this.active = false,
    this.last = false,
  });

  final int index;
  final String title;
  final bool done;
  final bool active;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final color = done
        ? AppColors.mint
        : active
        ? AppColors.accent
        : AppColors.textMuted;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 8),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: done
                  ? AppColors.mint.withValues(alpha: 0.15)
                  : active
                  ? AppColors.accent.withValues(alpha: 0.12)
                  : AppColors.bgElevated,
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: done
                ? const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: AppColors.mint,
                  )
                : Text(
                    '$index',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active || done ? FontWeight.w600 : FontWeight.w500,
                color: done || active
                    ? AppColors.textPrimary
                    : AppColors.textMuted,
              ),
            ),
          ),
          if (active && !done)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: AppColors.accent,
              ),
            ),
        ],
      ),
    );
  }
}

class _CredRow extends StatelessWidget {
  const _CredRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
              fontSize: 13,
            ),
          ),
        ),
        IconButton(
          tooltip: '复制',
          onPressed: onCopy,
          icon: const Icon(Icons.copy_rounded, size: 18),
          color: AppColors.accent,
        ),
      ],
    );
  }
}

/// Device-side file row: export / delete only (no playback).
/// Playback is available after Wi‑Fi export under「已导出（本地）」.
class _DeviceFileTile extends StatelessWidget {
  const _DeviceFileTile({
    required this.file,
    required this.selecting,
    required this.selected,
    required this.hasLocal,
    required this.downloading,
    this.onTap,
    this.onLongPress,
    this.onExport,
    this.onDelete,
  });

  final OfflineFileEntry file;
  final bool selecting;
  final bool selected;
  final bool hasLocal;
  final bool downloading;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColors.mint.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        key: ValueKey('device-recording-row-${file.fileId}'),
        onLongPress: onLongPress,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(
            children: [
              if (selecting) ...[
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? AppColors.mint : AppColors.textMuted,
                  size: 22,
                ),
                const SizedBox(width: 10),
              ],
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.violet.withValues(alpha: 0.15),
                ),
                child: Icon(
                  hasLocal
                      ? Icons.audiotrack_rounded
                      : Icons.audiotrack_outlined,
                  color: AppColors.violet,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${file.sizeLabel}${hasLocal ? ' · 已下载' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              if (!selecting) ...[
                IconButton(
                  tooltip: hasLocal
                      ? '已下载'
                      : downloading
                      ? '正在下载'
                      : '通过蓝牙下载',
                  onPressed: onExport,
                  icon: downloading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: AppColors.mint,
                          ),
                        )
                      : Icon(
                          hasLocal
                              ? Icons.download_done_rounded
                              : Icons.download_rounded,
                          color: hasLocal
                              ? AppColors.textMuted
                              : AppColors.mint,
                        ),
                ),
                IconButton(
                  tooltip: '在设备上删除',
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.coral,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Empty lists must still accept the same pull gesture as populated lists.
class _ScrollableHint extends StatelessWidget {
  const _ScrollableHint({required this.hint});
  final Widget hint;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [SliverFillRemaining(hasScrollBody: false, child: hint)],
  );
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.body,
    this.productImage,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? productImage;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (productImage != null)
            Image.asset(
              productImage!,
              height: 88,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  Icon(icon, size: 44, color: AppColors.textMuted),
            )
          else
            Icon(icon, size: 44, color: AppColors.textMuted),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
