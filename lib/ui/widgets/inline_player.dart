import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Compact play controls for a **local** exported file.
class InlinePlayer extends StatelessWidget {
  const InlinePlayer({super.key, required this.path, this.fileId});

  final String path;
  final int? fileId;

  static String _fmt(Duration d) {
    final total = d.inSeconds.abs();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static String _speedLabel(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}×';
    return '$s×';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final loaded = c.playingPath == path;
    final playing = loaded && c.isPlaying;
    final canSeek =
        loaded && (c.duration > Duration.zero || c.position > Duration.zero);
    final progress = loaded ? c.playbackProgress : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: AppColors.accent,
            inactiveTrackColor: AppColors.border,
            thumbColor: AppColors.accent,
            overlayColor: AppColors.accent.withValues(alpha: 0.12),
          ),
          child: Slider(
            padding: const EdgeInsets.symmetric(vertical: 18),
            value: progress,
            onChanged: canSeek
                ? (v) {
                    final totalMs = c.duration.inMilliseconds > 0
                        ? c.duration.inMilliseconds
                        : 1;
                    c.seekTo(Duration(milliseconds: (v * totalMs).round()));
                  }
                : null,
          ),
        ),
        Row(
          children: [
            Text(
              loaded ? _fmt(c.position) : '00:00',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (loaded) ...[
              const Spacer(),
              Text(
                _fmt(c.duration),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            PopupMenuButton<double>(
              tooltip: '播放速度',
              initialValue: c.playbackSpeed,
              onSelected: c.setPlaybackSpeed,
              itemBuilder: (_) => [
                for (final speed in RecorderController.playbackSpeeds)
                  PopupMenuItem(value: speed, child: Text(_speedLabel(speed))),
              ],
              child: Container(
                constraints: const BoxConstraints(minWidth: 72, minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.bgElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _speedLabel(c.playbackSpeed),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const Icon(Icons.expand_more_rounded, size: 20),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _IconBtn(
                  icon: Icons.replay_5_rounded,
                  tooltip: '后退 5 秒',
                  onPressed: canSeek
                      ? () => c.seekBy(const Duration(seconds: -5))
                      : null,
                ),
                const SizedBox(width: 2),
                Material(
                  color: AppColors.accent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => c.playExported(path, fileId: fileId),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: Tooltip(
                        message: playing ? '暂停播放' : '播放录音',
                        child: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _IconBtn(
                  icon: Icons.forward_5_rounded,
                  tooltip: '前进 5 秒',
                  onPressed: canSeek
                      ? () => c.seekBy(const Duration(seconds: 5))
                      : null,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 30),
        color: onPressed == null ? AppColors.textMuted : AppColors.textPrimary,
        constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
      ),
    );
  }
}
