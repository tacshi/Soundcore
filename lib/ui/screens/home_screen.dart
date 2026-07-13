import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/soniox_languages.dart';
import '../../ai/stt_types.dart';
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConnectionHeader(onScan: () => showScanDevicesSheet(context)),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: live
                  ? const _LiveSessionView(key: ValueKey('live'))
                  : const FilesBody(
                      key: ValueKey('files'),
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                    ),
            ),
          ),
        ],
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

    return Container(
      color: AppColors.bgCard,
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        20,
        16,
      ),
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
                            ? (c.autoTranscribe ? '实时同步转写' : '自动转写已关闭')
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
            IconButton(
              tooltip: '扫描',
              onPressed: onScan,
              style: IconButton.styleFrom(
                foregroundColor: AppColors.accent,
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(Icons.radar_rounded, size: 44),
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
    final targetLanguage = sonioxLanguageFor(c.translationTargetLanguage);

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
        const SizedBox(height: 14)._visibleWhen(c.autoTranscribe),
        SurfaceCard(
          borderColor: AppColors.violet.withValues(alpha: 0.35),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    c.translationModeActive
                        ? Icons.translate_rounded
                        : Icons.subtitles_outlined,
                    color: AppColors.violet,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.translationModeActive
                          ? (c.streamingSttActive
                                ? '翻译中（Soniox → ${targetLanguage.name}）'
                                : '翻译预览 · ${targetLanguage.name}')
                          : (c.streamingSttActive
                                ? '转写中（${c.sttProvider.label}）'
                                : '转写预览'),
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
                child: c.translationModeActive
                    ? _LiveTranslationPreview(
                        turns: c.translationTurns,
                        sourceDraft: draft,
                        pendingSource: c.pendingTranslationSource,
                        targetLanguage: targetLanguage,
                        configured: c.sttConfigured,
                      )
                    : SingleChildScrollView(
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
              if (draft.isNotEmpty || c.translationTurns.isNotEmpty) ...[
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
        )._visibleWhen(c.autoTranscribe),
        const SizedBox(height: 12)._visibleWhen(c.autoTranscribe),
        const TranscriptPanel(compact: true)._visibleWhen(c.autoTranscribe),
      ],
    );
  }
}

class _LiveTranslationPreview extends StatelessWidget {
  const _LiveTranslationPreview({
    required this.turns,
    required this.sourceDraft,
    required this.pendingSource,
    required this.targetLanguage,
    required this.configured,
  });

  final List<SttTranslationTurn> turns;
  final String sourceDraft;
  final SttSourceChunk? pendingSource;
  final SonioxLanguage targetLanguage;
  final bool configured;

  @override
  Widget build(BuildContext context) {
    if (turns.isEmpty) {
      final sourceText = pendingSource?.text ?? sourceDraft;
      if (sourceText.isNotEmpty) {
        return SingleChildScrollView(
          reverse: true,
          child: Column(
            key: const ValueKey('translation-pending'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.violet,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    '正在翻译…',
                    style: TextStyle(
                      color: AppColors.violet,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                sourceText,
                key: const ValueKey('translation-original'),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
            ],
          ),
        );
      }
      return Text(
        configured
            ? '开始说话后，这里会显示${targetLanguage.name}翻译…'
            : '请在「设置」中配置 SONIOX_API_KEY',
        key: const ValueKey('translation-empty'),
        style: const TextStyle(
          fontSize: 16,
          height: 1.5,
          color: AppColors.textMuted,
        ),
      );
    }

    final latest = turns.last;
    final completed = turns
        .take(turns.length - 1)
        .where((turn) => turn.isFinal)
        .toList(growable: false);
    final previousStart = completed.length > 2 ? completed.length - 2 : 0;
    final previous = completed.skip(previousStart);
    final pending = pendingSource;
    final original =
        pending?.text ??
        (latest.sourceText.isNotEmpty ? latest.sourceText : sourceDraft);
    final sourceLanguage = sonioxLanguageFor(
      pending?.language ?? latest.sourceLanguage,
    );

    return SingleChildScrollView(
      reverse: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final turn in previous) ...[
            Text(
              turn.text,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            latest.text,
            key: const ValueKey('translation-latest'),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 23,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          if (!latest.isFinal) ...[
            const SizedBox(height: 5),
            const Text(
              '翻译中…',
              style: TextStyle(color: AppColors.violet, fontSize: 11),
            ),
          ],
          if (pending != null) ...[
            const SizedBox(height: 12),
            const Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.violet,
                  ),
                ),
                SizedBox(width: 7),
                Text(
                  '正在翻译新原文…',
                  style: TextStyle(color: AppColors.violet, fontSize: 11),
                ),
              ],
            ),
          ],
          if (original.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              '${pending == null ? '原文' : '待翻译原文'} · ${sourceLanguage.name}',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              original,
              key: const ValueKey('translation-original'),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

extension on Widget {
  Widget _visibleWhen(bool visible) => visible ? this : const SizedBox.shrink();
}
