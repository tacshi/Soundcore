import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/stt_types.dart';
import '../../protocol/models.dart';
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
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 110),
  });

  final EdgeInsets padding;

  /// Display cleanup: Soniox `<end>` → newline (see [normalizeSttText]).
  static String cleanTranscript(String raw) => normalizeSttText(raw);

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
    final busy = c.phase == AppPhase.busy || exporting;
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
          Material(
            color: AppColors.bgElevated,
            borderRadius: BorderRadius.circular(12),
            child: TabBar(
              controller: _tabs,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
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
    final destination = await getDirectoryPath(
      confirmButtonText: '保存到这里',
      canCreateDirectories: true,
    );
    if (destination == null || !context.mounted) return;

    setState(() => _saving = true);
    final result = await context.read<RecorderController>().saveLocalCopies(
      _selected,
      destination,
    );
    if (!context.mounted) return;
    setState(() {
      _saving = false;
      if (result.failed.isEmpty) {
        _selecting = false;
        _selected.clear();
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.failed.isEmpty
              ? '已保存 ${result.audios} 个录音和 ${result.transcripts} 份转写'
              : '已保存 ${result.audios} 个录音，${result.failed.length} 个失败',
        ),
      ),
    );
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
              const SizedBox(width: 8),
              FilledButton.icon(
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
              const SizedBox(width: 6),
              FilledButton.icon(
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
            ] else ...[
              const Spacer(),
              TextButton.icon(
                onPressed: _toggleSelecting,
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text('批量管理'),
              ),
            ],
            if (_selecting)
              IconButton(
                tooltip: '取消选择',
                onPressed: _saving || _deleting ? null : _toggleSelecting,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: widget.paths.length,
            itemBuilder: (context, i) {
              final path = widget.paths[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _LocalExportCard(
                  path: path,
                  selecting: _selecting,
                  selected: _selected.contains(path),
                  onSelected: () => setState(() {
                    if (!_selected.add(path)) _selected.remove(path);
                  }),
                ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!c.selecting)
          Row(
            children: [
              Expanded(
                child: AccentButton(
                  label: '全部导出（Wi‑Fi）',
                  icon: Icons.download_rounded,
                  color: AppColors.mint,
                  onPressed: c.connected && c.files.isNotEmpty && !busy
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
                  onPressed: busy || c.selectedFileIds.isEmpty
                      ? null
                      : () => startWifiExport(context, c),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('导出所选'),
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
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: c.files.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final f = c.files[i];
                    final selected = c.selectedFileIds.contains(f.fileId);
                    final hasLocal = c.localPathFor(f.fileId) != null;
                    return _DeviceFileTile(
                      file: f,
                      selecting: c.selecting,
                      selected: selected,
                      hasLocal: hasLocal,
                      onTap: c.selecting
                          ? () => c.toggleFileSelected(f.fileId)
                          : null,
                      onExport: busy
                          ? null
                          : () {
                              c.selectOnly(f.fileId);
                              startWifiExport(context, c);
                            },
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

  Future<void> _exportTranscript(
    BuildContext context,
    String name,
    String text,
  ) async {
    final stem = name.replaceFirst(RegExp(r'\.(?:wav|opus(?:\.bin)?)$'), '');
    try {
      final destination = await getSaveLocation(
        suggestedName: '$stem.txt',
        confirmButtonText: '导出',
        canCreateDirectories: true,
      );
      if (destination == null) return;
      await File(destination.path).writeAsString(text, flush: true);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('转写文本已导出')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  Future<void> _shareTranscript(
    BuildContext context,
    String name,
    String text,
  ) async {
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          title: '分享转写文本',
          subject: '$name 转写文本',
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分享失败：$error')));
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
    final playing = loaded && c.isPlaying;
    final rawText = c.transcriptForPath(path);
    final text = rawText == null ? null : FilesBody.cleanTranscript(rawText);
    final hasText = text != null && text.isNotEmpty;
    final expanded = c.expandedLocalPath == path;

    return SurfaceCard(
      borderColor: loaded || expanded
          ? AppColors.accent.withValues(alpha: 0.5)
          : hasText
          ? AppColors.violet.withValues(alpha: 0.3)
          : null,
      onTap: selecting ? onSelected : () => c.toggleLocalExpanded(path),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (selecting) ...[
                Checkbox(value: selected, onChanged: (_) => onSelected?.call()),
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
                      playing
                          ? '正在播放'
                          : hasText
                          ? '已转写 · 点开查看'
                          : loaded
                          ? '已加载'
                          : '点开播放 / 转写',
                      style: TextStyle(
                        fontSize: 11,
                        color: hasText ? AppColors.violet : AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (!selecting)
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: AppColors.textMuted,
                ),
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
            if (hasText) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (c.sttConfigured)
                    TextButton.icon(
                      onPressed: c.transcribing
                          ? null
                          : () => _confirmRetranscribe(context, c),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(
                        c.transcribing ? '转写中…' : '重新转写',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: '导出转写文本',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _exportTranscript(context, name, text),
                    icon: const Icon(Icons.file_download_outlined, size: 19),
                  ),
                  IconButton(
                    tooltip: '分享转写文本',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _shareTranscript(context, name, text),
                    icon: const Icon(Icons.ios_share_rounded, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
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
              if (c.sttConfigured)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: c.transcribing
                        ? null
                        : () => c.transcribeLocalFile(path),
                    icon: const Icon(Icons.subtitles_outlined, size: 16),
                    label: Text(c.transcribing ? '转写中…' : '转写此文件'),
                  ),
                )
              else
                const Text(
                  '在「设置」配置 API Key 后可转写此文件',
                  style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                ),
            ],
            const SizedBox(height: 8),
            InlinePlayer(path: path, fileId: fileId),
          ],
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
    // Poll SoftAP every 2s; auto-start transfer once the host is reachable.
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
    final ok = await widget.controller.probeSoftApReachable();
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
    setState(() => _running = true);
    final c = widget.controller;
    final paths = await c.continueWifiExport();
    if (!mounted) return;
    if (paths.isNotEmpty || c.exportProgress.phase == ExportPhase.done) {
      Navigator.of(context).pop();
      final bleNote = c.connected ? '' : ' 蓝牙可能已断开，导出后请点「扫描」重连。';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            paths.isEmpty ? '导出完成$bleNote' : '已保存 ${paths.length} 个文件$bleNote',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      setState(() {
        _running = false;
        _autoStarted = false; // allow another auto try after failure
      });
    }
  }

  Future<void> _openWifiSettings() async {
    try {
      if (Platform.isMacOS) {
        // Opens System Settings → Wi‑Fi on modern macOS.
        await Process.run('open', [
          'x-apple.systempreferences:com.apple.wifi-settings-extension',
        ]);
      } else if (Platform.isIOS) {
        // Best-effort; may be restricted by iOS.
        await Process.run('open', ['App-Prefs:WIFI']);
      }
    } catch (_) {
      try {
        if (Platform.isMacOS) {
          await Process.run('open', [
            '/System/Library/PreferencePanes/Network.prefPane',
          ]);
        }
      } catch (_) {}
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
            const SizedBox(height: 12),
            SurfaceCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'macOS 加入步骤',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '1. 打开「系统设置 → Wi‑Fi」\n'
                    '2. 滚到底部点「其他…」(Other…)\n'
                    '3. 网络名称粘贴：$ssid\n'
                    '4. 安全性选「WPA2/WPA3 个人级」\n'
                    '5. 密码粘贴：$password\n'
                    '6. 勾选「显示网络」可选；连接成功后回到本应用',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
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
              '端点 192.168.43.x 为设备热点网关，说明 SoftAP 指令已成功。',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
            if (_reachable && !transferring) ...[
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
              onPressed: transferring
                  ? null
                  : () async {
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
    this.onTap,
    this.onExport,
    this.onDelete,
  });

  final OfflineFileEntry file;
  final bool selecting;
  final bool selected;
  final bool hasLocal;
  final VoidCallback? onTap;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      borderColor: selected ? AppColors.mint.withValues(alpha: 0.55) : null,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
              hasLocal ? Icons.audiotrack_rounded : Icons.audiotrack_outlined,
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
              tooltip: '通过 Wi‑Fi 导出',
              onPressed: onExport,
              icon: const Icon(Icons.download_rounded, color: AppColors.mint),
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
