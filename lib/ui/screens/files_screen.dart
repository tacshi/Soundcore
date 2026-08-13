import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/stt_types.dart';
import '../../protocol/models.dart';
import '../../state/export_catalog.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../../wifi/wifi_export_service.dart';
import '../widgets/inline_player.dart';
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
              unselectedLabelColor: AppColors.textMuted,
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
              ),
              tabs: [
                Tab(text: localCount > 0 ? '已导出 ($localCount)' : '已导出'),
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
      ).showSnackBar(SnackBar(content: Text('无法打开分享菜单：$error')));
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
    if (widget.paths.isEmpty) {
      return const _Hint(
        icon: Icons.folder_open_rounded,
        title: '暂无本地导出',
        body: '录音结束后的实时文件，或从「设备端」Wi‑Fi 导出后，会出现在这里。',
      );
    }
    _selected.removeWhere((path) => !widget.paths.contains(path));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (_selecting) ...[
              TextButton(
                onPressed: _saving || _deleting
                    ? null
                    : () => setState(() => _selected.addAll(widget.paths)),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: _saving || _deleting || _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
                child: const Text('清空'),
              ),
              const Spacer(),
              Text(
                '已选 ${_selected.length} 项',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ] else ...[
              const Spacer(),
              TextButton.icon(
                onPressed: _toggleSelecting,
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text('批量管理'),
              ),
            ],
          ],
        ),
        if (_selecting) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _selected.isEmpty || _saving || _deleting
                      ? null
                      : () => _saveSelected(context),
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_alt_rounded, size: 18),
                  label: Text(_saving ? '保存中…' : '保存所选'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.coral,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _selected.isEmpty || _saving || _deleting
                      ? null
                      : () => _deleteSelected(context),
                  icon: _deleting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(_deleting ? '删除中…' : '删除所选'),
                ),
              ),
              IconButton(
                tooltip: '取消选择',
                onPressed: _saving || _deleting ? null : _toggleSelecting,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ],
        const SizedBox(height: 4),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: widget.paths.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, color: AppColors.border),
            itemBuilder: (context, i) {
              final path = widget.paths[i];
              return _LocalExportCard(
                path: path,
                selecting: _selecting,
                selected: _selected.contains(path),
                onSelected: () => setState(() {
                  if (!_selected.add(path)) _selected.remove(path);
                }),
              );
            },
          ),
        ),
      ],
    );
  }
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!c.selecting)
          Row(
            children: [
              Expanded(
                child: AccentButton(
                  label: downloadableCount == 0 ? '全部已导出' : '全部导出（Wi‑Fi）',
                  icon: downloadableCount == 0
                      ? Icons.download_done_rounded
                      : Icons.download_rounded,
                  color: AppColors.mint,
                  onPressed: c.connected && downloadableCount > 0 && !busy
                      ? () => startWifiExport(context, c)
                      : null,
                ),
              ),
              if (c.files.isNotEmpty) ...[
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: busy ? null : c.toggleSelecting,
                  icon: const Icon(Icons.checklist_rounded, size: 18),
                  label: const Text('批量管理'),
                ),
              ],
              IconButton(
                tooltip: '刷新',
                onPressed: c.connected && !busy ? c.listFiles : null,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        if (c.selecting && c.files.isNotEmpty) ...[
          Row(
            children: [
              TextButton(
                onPressed: busy ? null : c.selectAllFiles,
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: busy || c.selectedFileIds.isEmpty
                    ? null
                    : c.clearSelection,
                child: const Text('清空'),
              ),
              const Spacer(),
              Text(
                '已选 ${c.selectedFileIds.length} 项',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || selectedDownloadableCount == 0
                      ? null
                      : () => startWifiExport(context, c),
                  icon: Icon(
                    selectedDownloadableCount == 0
                        ? Icons.download_done_rounded
                        : Icons.download_rounded,
                    size: 18,
                  ),
                  label: Text(
                    selectedDownloadableCount == 0 ? '所选已导出' : '导出所选',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.coral,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: busy || c.selectedFileIds.isEmpty
                      ? null
                      : () => _deleteSelected(context, c),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('删除所选'),
                ),
              ),
              IconButton(
                tooltip: '取消选择',
                onPressed: busy ? null : c.toggleSelecting,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: !c.connected
              ? const _Hint(
                  icon: Icons.link_off_rounded,
                  title: '未连接设备',
                  body: '点右上角「扫描」连接 soundcore Work，即可列出设备端录音。',
                )
              : c.files.isEmpty
              ? _Hint(
                  icon: Icons.inbox_rounded,
                  title: '设备上暂无录音',
                  body: '进入本页会自动拉取列表，也可点右上角刷新。',
                  productImage: 'assets/product/d3200_device_white.webp',
                  action: AccentButton(
                    label: '获取列表',
                    expand: false,
                    onPressed: busy ? null : c.listFiles,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: c.files.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, i) {
                    final f = c.files[i];
                    final selected = c.selectedFileIds.contains(f.fileId);
                    final hasLocal = c.localPathFor(f.fileId) != null;
                    final downloading = c.downloadingFileId == f.fileId;
                    return _DeviceFileTile(
                      file: f,
                      selecting: c.selecting,
                      selected: selected,
                      hasLocal: hasLocal,
                      downloading: downloading,
                      onTap: c.selecting
                          ? () => c.toggleFileSelected(f.fileId)
                          : null,
                      onExport: busy || hasLocal
                          ? null
                          : () => c.downloadFileOverBle(f),
                      onDelete: busy ? null : () => c.deleteFile(f.fileId),
                    );
                  },
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
  });

  final String path;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelected;

  Future<void> _rename(
    BuildContext context,
    RecorderController controller,
  ) async {
    final input = TextEditingController(
      text: ExportCatalog.editableLabelFromPath(path),
    );
    String? validationError;
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          title: const Text(
            '重命名录音',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: input,
                autofocus: true,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: '文件名',
                  counterText: '',
                  errorText: validationError,
                  isDense: true,
                ),
                onSubmitted: (value) {
                  try {
                    ExportCatalog.renamedFileName(path, value);
                    Navigator.pop(dialogContext, value);
                  } on ArgumentError catch (error) {
                    setDialogState(
                      () => validationError = error.message?.toString(),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
              const Text(
                '录音编号和扩展名保持不变',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  ExportCatalog.renamedFileName(path, input.text);
                  Navigator.pop(dialogContext, input.text);
                } on ArgumentError catch (error) {
                  setDialogState(
                    () => validationError = error.message?.toString(),
                  );
                }
              },
              child: const Text('重命名'),
            ),
          ],
        ),
      ),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    input.dispose();
    if (label == null || !context.mounted) return;

    try {
      await controller.renameLocalExport(path, label);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重命名失败：$error')));
    }
  }

  Future<void> _saveRecording(
    BuildContext context,
    RecorderController controller,
  ) async {
    try {
      // iOS does not expose a directory/save-location picker through
      // file_selector. Its share sheet provides the native "Save to Files"
      // action and supports the optional transcript sidecar as a second file.
      if (Platform.isIOS) {
        await _shareRecording(
          context,
          controller,
          title: '保存录音',
          failureLabel: '保存',
        );
        return;
      }

      final destination = await getDirectoryPath(
        confirmButtonText: '保存',
        canCreateDirectories: true,
      );
      if (destination == null) return;
      final result = await controller.saveLocalCopies([path], destination);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.failed.isEmpty
                ? '已保存录音${result.transcripts > 0 ? '和转写文本' : ''}'
                : '保存失败：${result.failed.join('\n')}',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _shareRecording(
    BuildContext context,
    RecorderController controller, {
    String title = '分享录音',
    String failureLabel = '分享',
  }) async {
    final name = path.split('/').last;
    try {
      final paths = await controller.prepareLocalSharePaths([path]);
      if (paths.isEmpty) throw StateError('录音文件不存在');
      if (!context.mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await SharePlus.instance.share(
        ShareParams(
          files: paths.map(XFile.new).toList(),
          title: title,
          subject: paths.length > 1 ? '$name 录音及转写' : '$name 录音',
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$failureLabel失败：$error')));
    }
  }

  Future<void> _confirmRetranscribe(
    BuildContext context,
    RecorderController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新转写？'),
        content: const Text('当前转写文本将被新的转写结果替换。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重新转写'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await controller.transcribeLocalFile(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final name = path.split('/').last;
    final fileId = c.fileIdFromPath(path);
    final loaded = c.playingPath == path;
    final rawText = c.transcriptForPath(path);
    final text = rawText == null ? null : FilesBody.cleanTranscript(rawText);
    final hasText = text != null && text.isNotEmpty;
    final expanded = c.expandedLocalPath == path;
    final duration = FilesBody.formatDuration(c.localDurationForPath(path));
    final transcribingThis = c.transcribingPath == path;
    final transcriptionProgress = transcribingThis
        ? c.fileTranscriptionProgress
        : null;

    final backgroundColor = selected
        ? AppColors.mint.withValues(alpha: 0.08)
        : loaded || expanded
        ? AppColors.accent.withValues(alpha: 0.06)
        : Colors.transparent;
    return Material(
      color: backgroundColor,
      child: InkWell(
        onTap: selecting ? onSelected : () => c.toggleLocalExpanded(path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (selecting) ...[
                    Checkbox(
                      value: selected,
                      onChanged: (_) => onSelected?.call(),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    name.endsWith('.opus') || name.endsWith('.wav')
                        ? Icons.audio_file_rounded
                        : Icons.insert_drive_file_rounded,
                    color: loaded ? AppColors.accent : AppColors.mint,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: loaded
                                ? AppColors.accent
                                : AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          transcribingThis
                              ? '$duration • 转写中'
                              : hasText
                              ? '$duration • 已转写'
                              : duration,
                          style: TextStyle(
                            fontSize: 11,
                            color: transcribingThis || hasText
                                ? AppColors.violet
                                : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!selecting) ...[
                    IconButton(
                      tooltip: hasText ? '保存录音和转写' : '保存录音',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _saveRecording(context, c),
                      icon: const Icon(Icons.file_download_outlined, size: 19),
                    ),
                    IconButton(
                      tooltip: hasText ? '分享录音和转写' : '分享录音',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _shareRecording(context, c),
                      icon: const Icon(Icons.ios_share_rounded, size: 19),
                    ),
                    IconButton(
                      tooltip: '重命名',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _rename(context, c),
                      icon: const Icon(Icons.edit_outlined, size: 19),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: AppColors.textMuted,
                    ),
                  ],
                ],
              ),
              if (hasText && !expanded && !selecting) ...[
                const SizedBox(height: 8),
                Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
              if (expanded && !selecting) ...[
                const SizedBox(height: 8),
                const Divider(height: 1, color: AppColors.border),
                if (transcriptionProgress != null) ...[
                  const SizedBox(height: 12),
                  _FileTranscriptionProgress(progress: transcriptionProgress),
                ],
                if (hasText) ...[
                  SizedBox(height: transcriptionProgress == null ? 10 : 6),
                  if (c.sttConfigured)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: c.transcribing
                            ? null
                            : () => _confirmRetranscribe(context, c),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text(
                          '重新转写',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.45,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  if (c.sttConfigured) ...[
                    if (transcriptionProgress == null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: c.transcribing
                              ? null
                              : () => c.transcribeLocalFile(path),
                          icon: const Icon(Icons.subtitles_outlined, size: 16),
                          label: const Text('转写此文件'),
                        ),
                      ),
                  ] else
                    const Text(
                      '在「设置」配置 API Key 后可转写此文件',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                InlinePlayer(path: path, fileId: fileId),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FileTranscriptionProgress extends StatelessWidget {
  const _FileTranscriptionProgress({required this.progress});

  final SttFileProgress progress;

  String get _label {
    switch (progress.stage) {
      case SttFileStage.preparing:
        return '正在准备音频…';
      case SttFileStage.uploading:
        final fraction = progress.fraction;
        return fraction == null ? '正在上传…' : '正在上传 ${(fraction * 100).round()}%';
      case SttFileStage.queued:
        return '等待转写…';
      case SttFileStage.processing:
        return '正在转写…';
      case SttFileStage.fetching:
        return '正在获取结果…';
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = progress.stage == SttFileStage.uploading
        ? progress.fraction
        : null;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.violet.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.subtitles_outlined,
                size: 17,
                color: AppColors.violet,
              ),
              const SizedBox(width: 8),
              Text(
                _label,
                style: const TextStyle(
                  color: AppColors.violet,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 4,
              color: AppColors.violet,
              backgroundColor: AppColors.violet.withValues(alpha: 0.14),
            ),
          ),
        ],
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
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
          if (p.savedPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '已保存到应用 Documents/AnkerRecorder/exports\n'
              '${p.savedPaths.map((e) => e.split('/').last).join(', ')}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
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
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
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
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
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
    this.onExport,
    this.onDelete,
  });

  final OfflineFileEntry file;
  final bool selecting;
  final bool selected;
  final bool hasLocal;
  final bool downloading;
  final VoidCallback? onTap;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColors.mint.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
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
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'id ${file.fileId} · ${file.sizeLabel}'
                      '${hasLocal ? ' · 已导出' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
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

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.productImage,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
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
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
