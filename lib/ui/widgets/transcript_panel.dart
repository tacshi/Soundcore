import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'widgets.dart';

/// Live / final AI transcript card.
///
/// Use [compact] on the live home view to avoid duplicating large chrome.
class TranscriptPanel extends StatelessWidget {
  const TranscriptPanel({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final hasText =
        c.transcript.isNotEmpty || (c.transcriptPartial?.isNotEmpty ?? false);
    final show =
        c.autoTranscribe ||
        c.transcribing ||
        hasText ||
        c.transcriptError != null ||
        !c.sttConfigured;

    if (!show) return const SizedBox.shrink();

    final draft = c.transcript.isNotEmpty
        ? c.transcript
        : (c.transcriptPartial ?? '');

    if (compact) {
      if (!hasText && c.sttConfigured) return const SizedBox.shrink();
      return SurfaceCard(
        borderColor: AppColors.violet.withValues(alpha: 0.25),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!c.sttConfigured)
              Text(
                '转写未就绪：在「设置」配置 SONIOX_API_KEY',
                style: const TextStyle(color: AppColors.amber, fontSize: 12),
              )
            else if (hasText)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '使用 Soniox${c.streamingSttActive ? ' · 流式' : ''}',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: draft));
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('转写已复制')));
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('复制'),
                  ),
                ],
              ),
          ],
        ),
      );
    }

    return SurfaceCard(
      borderColor: AppColors.violet.withValues(alpha: 0.35),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.subtitles_outlined,
                color: AppColors.violet,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.streamingSttActive
                      ? 'AI 实时转写（Soniox）'
                      : c.transcribing
                      ? 'AI 转写中（Soniox）…'
                      : 'AI 转写 · Soniox',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (c.streamingSttActive || c.transcribing)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.violet,
                  ),
                ),
              const SizedBox(width: 6),
              Switch.adaptive(
                value: c.autoTranscribe,
                activeTrackColor: AppColors.violet.withValues(alpha: 0.45),
                activeThumbColor: AppColors.violet,
                onChanged: c.setAutoTranscribe,
              ),
            ],
          ),
          if (!c.sttConfigured) ...[
            const SizedBox(height: 8),
            Text(
              '未配置 SONIOX_API_KEY。请在「设置」查看说明。',
              style: const TextStyle(
                color: AppColors.amber,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
          if (c.transcriptError != null) ...[
            const SizedBox(height: 8),
            Text(
              c.transcriptError!,
              style: const TextStyle(
                color: AppColors.coral,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
          if (draft.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.bgElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: SingleChildScrollView(
                child: Text(
                  draft,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: draft));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('转写已复制')));
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('复制'),
                ),
                TextButton(
                  onPressed: c.clearTranscript,
                  child: const Text('清空'),
                ),
              ],
            ),
          ] else if (c.sttConfigured && c.autoTranscribe) ...[
            const SizedBox(height: 8),
            Text(
              c.streamingSttActive
                  ? 'PCM 流式转写中 · 已解码 ${c.pcmFramesDecoded} 帧'
                  : '录音时自动转写；也可对本地文件点「转写」。',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
