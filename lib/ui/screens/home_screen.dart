import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';

/// Primary tab: live transcription while recording, otherwise device file list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loadedFiles = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFiles) return;
    _loadedFiles = true;
    final c = context.read<RecorderController>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.refreshFilesOnTabEnter();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final live = c.isLiveSession;

    return GradientScaffold(
      appBar: AppBar(title: Text(live ? '实时转写' : '录音')),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: _ConnectionHeader(
                onScan: () => showScanDevicesSheet(context),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: live
                    ? const _LiveSessionView(key: ValueKey('live'))
                    : const FilesBody(
                        key: ValueKey('files'),
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 110),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionHeader extends StatelessWidget {
  const _ConnectionHeader({required this.onScan});

  final VoidCallback onScan;

  /// Prefer real connection/STT status; never keep a stale "正在播放" line.
  static String _idleStatus(RecorderController c) {
    final m = c.statusMessage;
    if (m == null || m.isEmpty) return '已连接 · 可录音或浏览文件';
    if (m.startsWith('正在播放') || m.startsWith('正在准备播放')) {
      return '已连接 · 可录音或浏览文件';
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final online = c.connected;
    final name = c.displayDeviceName;

    return SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderColor: online
          ? AppColors.mint.withValues(alpha: 0.35)
          : AppColors.border,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: (online ? AppColors.mint : AppColors.accent).withValues(
                alpha: 0.12,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: online
                ? Image.asset(
                    'assets/product/d3200_device_white.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.headphones_rounded,
                      color: AppColors.mint,
                    ),
                  )
                : const Icon(Icons.link_off_rounded, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? name : (c.displayDevice != null ? name : '未连接设备'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  online
                      ? (c.recording
                            ? '录音中 · 实时同步转写'
                            : c.isPlaying
                            ? (c.statusMessage?.startsWith('正在播放') == true
                                  ? c.statusMessage!
                                  : '正在播放')
                            : _idleStatus(c))
                      : '点「扫描」查找 soundcore Work',
                  style: TextStyle(
                    fontSize: 12,
                    color: c.recording
                        ? AppColors.coral
                        : c.isPlaying
                        ? AppColors.accent
                        : AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (online) ...[
            StatusPill(
              label: c.recording ? '录音中' : '在线',
              color: c.recording ? AppColors.coral : AppColors.mint,
              icon: c.recording ? Icons.fiber_manual_record : null,
            ),
          ] else
            IconButton.filled(
              tooltip: '扫描',
              onPressed: onScan,
              style: IconButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.all(11),
              ),
              icon: const Icon(Icons.radar_rounded, size: 22),
            ),
        ],
      ),
    );
  }
}

class _LiveSessionView extends StatelessWidget {
  const _LiveSessionView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final draft = c.transcript.isNotEmpty
        ? c.transcript
        : (c.transcriptPartial ?? '');

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
      children: [
        SurfaceCard(
          glow: true,
          borderColor: AppColors.coral.withValues(alpha: 0.35),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: AppColors.coral,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '实时会话',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (c.streamingSttActive)
                    StatusPill(
                      label: c.sttProvider.label,
                      color: AppColors.violet,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (c.realtimeState.active || c.realtimeState.bytesReceived > 0)
                Text(
                  c.realtimeState.message.isNotEmpty
                      ? c.realtimeState.message
                      : 'BLE 实时传输中…',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              if (c.pcmFramesDecoded > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '已解码 ${c.pcmFramesDecoded} 帧 Opus → PCM',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: AccentButton(
                      label: c.recording ? '录音中…' : '开始录音',
                      icon: Icons.mic_rounded,
                      color: AppColors.coral,
                      onPressed:
                          !c.connected ||
                              c.recording ||
                              c.blocksRecordingControl
                          ? null
                          : c.startRecord,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AccentButton(
                      label: '暂停',
                      icon: Icons.pause_rounded,
                      filled: false,
                      color: AppColors.amber,
                      onPressed: !c.recording || c.phase == AppPhase.busy
                          ? null
                          : c.pauseRecord,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SurfaceCard(
          borderColor: AppColors.violet.withValues(alpha: 0.35),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.subtitles_outlined,
                    color: AppColors.violet,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.streamingSttActive
                          ? '转写中（${c.sttProvider.label}）'
                          : c.autoTranscribe
                          ? '转写预览'
                          : '转写已关闭',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (c.streamingSttActive || c.transcribing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.violet,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(
                  minHeight: 160,
                  maxHeight: 320,
                ),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    draft.isEmpty
                        ? (c.sttConfigured
                              ? '开始说话后，这里会实时显示转写文字…'
                              : '请在「设置」中配置 ${c.sttProvider.envKeyName}')
                        : draft,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      color: draft.isEmpty
                          ? AppColors.textMuted
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
              if (c.transcriptError != null) ...[
                const SizedBox(height: 8),
                Text(
                  c.transcriptError!,
                  style: const TextStyle(color: AppColors.coral, fontSize: 12),
                ),
              ],
              if (draft.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: c.clearTranscript,
                    child: const Text('清空'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        const TranscriptPanel(compact: true),
      ],
    );
  }
}
