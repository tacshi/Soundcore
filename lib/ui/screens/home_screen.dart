import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/soniox_languages.dart';
import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';

/// Primary tab: recording history while idle, flat live transcription in-session.
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
    final live = c.isLiveSession;
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
                if (!live) ...[
                  const SizedBox(height: 2),
                  Text(
                    online
                        ? (c.isPlaying
                              ? (c.statusMessage?.startsWith('正在播放') == true
                                    ? c.statusMessage!
                                    : '正在播放')
                              : _idleStatus(c))
                        : '点「扫描」查找 soundcore Work',
                    style: TextStyle(
                      fontSize: 12,
                      color: c.isPlaying
                          ? AppColors.accent
                          : AppColors.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (online && !live) ...[
            StatusPill(label: '在线', color: AppColors.mint),
          ] else if (!online)
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

class _LiveSessionView extends StatefulWidget {
  const _LiveSessionView({super.key});

  @override
  State<_LiveSessionView> createState() => _LiveSessionViewState();
}

class _LiveSessionViewState extends State<_LiveSessionView> {
  final ScrollController _scrollController = ScrollController();
  int? _lastContentRevision;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _followLatest(int revision) {
    if (_lastContentRevision == revision) return;
    _lastContentRevision = revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final draft = c.transcript.isNotEmpty
        ? c.transcript
        : (c.transcriptPartial ?? '');
    final targetLanguage = sonioxLanguageFor(c.translationTargetLanguage);
    final translationRevision = Object.hashAll(
      c.translationTurns.map(
        (turn) => Object.hash(
          turn.text,
          turn.isFinal,
          turn.sourceText,
          turn.sourceLanguage,
          turn.targetLanguage,
        ),
      ),
    );
    final pending = c.pendingTranslationSource;
    final contentRevision = Object.hash(
      c.sttMode,
      draft,
      translationRevision,
      pending?.text,
      pending?.language,
    );
    _followLatest(contentRevision);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TranscriptToolbar(controller: c, targetLanguage: targetLanguage),
        if (!c.autoTranscribe)
          const _InlineNotice(
            icon: Icons.subtitles_off_rounded,
            text: '自动转写已关闭，可在「设置」中开启。',
            color: AppColors.amber,
          )
        else if (!c.sttConfigured)
          _InlineNotice(
            icon: Icons.key_off_rounded,
            text: '请在「设置」中配置 SONIOX_API_KEY',
            color: AppColors.amber,
          ),
        if (c.transcriptError != null)
          _InlineNotice(
            icon: Icons.error_outline_rounded,
            text: c.transcriptError!,
            color: AppColors.coral,
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const padding = EdgeInsets.fromLTRB(20, 18, 20, 24);
              final minimumHeight = (constraints.maxHeight - padding.vertical)
                  .clamp(0.0, double.infinity);
              return Scrollbar(
                controller: _scrollController,
                child: SingleChildScrollView(
                  key: const ValueKey('live-transcript-scroll'),
                  controller: _scrollController,
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minimumHeight),
                    child: c.translationModeActive
                        ? _LiveTranslationPreview(
                            turns: c.translationTurns,
                            sourceDraft: draft,
                            pendingSource: c.pendingTranslationSource,
                            targetLanguage: targetLanguage,
                            configured: c.sttConfigured,
                          )
                        : draft.isEmpty
                        ? _TranscriptPlaceholder(
                            configured: c.sttConfigured,
                            autoTranscribe: c.autoTranscribe,
                            connected: c.connected,
                          )
                        : SelectableText(
                            draft,
                            key: const ValueKey('live-transcript-text'),
                            style: const TextStyle(
                              fontSize: 20,
                              height: 1.55,
                              color: AppColors.textPrimary,
                            ),
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TranscriptToolbar extends StatelessWidget {
  const _TranscriptToolbar({
    required this.controller,
    required this.targetLanguage,
  });

  final RecorderController controller;
  final SonioxLanguage targetLanguage;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final live = c.recording || c.realtimeState.active || c.streamingSttActive;
    final title = c.translationModeActive
        ? '${c.streamingSttActive ? '翻译中' : '即时翻译'} · ${targetLanguage.name}'
        : '${c.streamingSttActive ? '实时转写' : '即时转写'} · Soniox';
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
        child: Row(
          children: [
            Semantics(
              label: live ? '转写进行中' : '转写等待中',
              child: Container(
                key: const ValueKey('live-session-indicator'),
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: live ? AppColors.coral : AppColors.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (c.recording)
              IconButton.filledTonal(
                key: const ValueKey('pause-recording'),
                tooltip: '暂停录音',
                visualDensity: VisualDensity.compact,
                onPressed: c.phase == AppPhase.busy ? null : c.pauseRecord,
                icon: const Icon(Icons.pause_rounded, size: 21),
              ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptPlaceholder extends StatelessWidget {
  const _TranscriptPlaceholder({
    required this.configured,
    required this.autoTranscribe,
    required this.connected,
  });

  final bool configured;
  final bool autoTranscribe;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final message = !connected
        ? '连接 soundcore Work 后即可开始即时转写'
        : !autoTranscribe
        ? '自动转写当前已关闭'
        : !configured
        ? '配置 API Key 后即可开始即时转写'
        : '开始说话后，这里会实时显示转写文字…';
    return Center(
      child: Text(
        message,
        key: const ValueKey('live-transcript-placeholder'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 16,
          height: 1.5,
        ),
      ),
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
        return Column(
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
                fontSize: 16,
                height: 1.5,
              ),
            ),
          ],
        );
      }
      return Center(
        child: Text(
          configured
              ? '开始说话后，这里会显示${targetLanguage.name}翻译…'
              : '请在「设置」中配置 SONIOX_API_KEY',
          key: const ValueKey('translation-empty'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 16,
            height: 1.5,
            color: AppColors.textMuted,
          ),
        ),
      );
    }

    final latest = turns.last;
    final previous = turns
        .take(turns.length - 1)
        .where((turn) => turn.isFinal)
        .toList(growable: false);
    final pending = pendingSource;
    final original =
        pending?.text ??
        (latest.sourceText.isNotEmpty ? latest.sourceText : sourceDraft);
    final sourceLanguage = sonioxLanguageFor(
      pending?.language ?? latest.sourceLanguage,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final turn in previous) ...[
          Text(
            turn.text,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 16,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
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
    );
  }
}
