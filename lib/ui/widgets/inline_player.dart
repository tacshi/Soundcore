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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Text(
                loaded ? _fmt(c.position) : '00:00',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (loaded) ...[
                const Spacer(),
                Text(
                  _fmt(c.duration),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Container(
              constraints: const BoxConstraints(minWidth: 82, minHeight: 42),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppColors.bgElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<double>(
                  value:
                      RecorderController.playbackSpeeds.contains(
                        c.playbackSpeed,
                      )
                      ? c.playbackSpeed
                      : 1.0,
                  isDense: true,
                  iconSize: 22,
                  dropdownColor: AppColors.bgCard,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  items: [
                    for (final s in RecorderController.playbackSpeeds)
                      DropdownMenuItem(value: s, child: Text(_speedLabel(s))),
                  ],
                  onChanged: (v) {
                    if (v != null) c.setPlaybackSpeed(v);
                  },
                ),
              ),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _IconBtn(
                    icon: Icons.replay_5_rounded,
                    tooltip: '后退 5 秒',
                    onPressed: canSeek
                        ? () => c.seekBy(const Duration(seconds: -5))
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Material(
                    color: AppColors.accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => c.playExported(path, fileId: fileId),
                      child: SizedBox(
                        width: 46,
                        height: 46,
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
                  const SizedBox(width: 6),
                  _IconBtn(
                    icon: Icons.forward_5_rounded,
                    tooltip: '前进 5 秒',
                    onPressed: canSeek
                        ? () => c.seekBy(const Duration(seconds: 5))
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 56),
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
