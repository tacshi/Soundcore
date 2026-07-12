import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'widgets.dart';

/// Sticky playback controls: play/pause, ±5s seek, speed dropdown, scrubber.
class PlaybackBar extends StatelessWidget {
  const PlaybackBar({super.key});

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }

  static String _speedLabel(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}×';
    return '$s×';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    if (!c.hasLoadedTrack) return const SizedBox.shrink();

    final canSeek = c.duration > Duration.zero || c.position > Duration.zero;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderColor: AppColors.accent.withValues(alpha: 0.35),
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.graphic_eq_rounded,
                color: AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.playingTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭播放器',
                visualDensity: VisualDensity.compact,
                onPressed: c.stopPlayback,
                icon: const Icon(Icons.close_rounded, size: 18),
                color: AppColors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Scrubber
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.border,
              thumbColor: AppColors.accent,
              overlayColor: AppColors.accent.withValues(alpha: 0.15),
            ),
            child: Slider(
              value: c.playbackProgress,
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
                  _fmt(c.position),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
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
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              // Speed dropdown
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppColors.bgElevated,
                  borderRadius: BorderRadius.circular(10),
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
                    dropdownColor: AppColors.bgCard,
                    icon: const Icon(
                      Icons.arrow_drop_down_rounded,
                      color: AppColors.textMuted,
                      size: 20,
                    ),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
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
                    _RoundControl(
                      tooltip: '后退 5 秒',
                      icon: Icons.replay_5_rounded,
                      onPressed: canSeek
                          ? () => c.seekBy(const Duration(seconds: -5))
                          : null,
                    ),
                    const SizedBox(width: 10),
                    _PlayPauseButton(
                      playing: c.isPlaying,
                      onPressed: c.togglePlayPause,
                    ),
                    const SizedBox(width: 10),
                    _RoundControl(
                      tooltip: '前进 5 秒',
                      icon: Icons.forward_5_rounded,
                      onPressed: canSeek
                          ? () => c.seekBy(const Duration(seconds: 5))
                          : null,
                    ),
                  ],
                ),
              ),
              // Balance width of speed control so transport stays centered.
              const SizedBox(width: 72),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    );
  }
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.bgElevated,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 24,
              color: onPressed == null
                  ? AppColors.textMuted.withValues(alpha: 0.4)
                  : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
