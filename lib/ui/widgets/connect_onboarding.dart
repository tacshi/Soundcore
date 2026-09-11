import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Feishu-style post-connect success + tips carousel.
///
/// 1. 连接成功 (battery) → 继续
/// 2. 一键录音 → 下一步
/// 3. 标记重点 → 下一步
/// 4. 轻松佩戴 → 下一步
/// 5. 文件自动同步 → 我知道了
class ConnectOnboarding extends StatefulWidget {
  const ConnectOnboarding({super.key, required this.onDone, this.onClose});

  final VoidCallback onDone;
  final VoidCallback? onClose;

  @override
  State<ConnectOnboarding> createState() => _ConnectOnboardingState();
}

class _ConnectOnboardingState extends State<ConnectOnboarding> {
  /// 0 = success; 1..3 = tips; 4 = auto-sync finale.
  int _step = 0;

  static const _tipPages = <_TipPage>[
    _TipPage(
      title: '开始录音',
      body: '按下按键开始录音\n再次按下即可结束',
      image: 'assets/product/guide_record.webp',
      highlight: _TipHighlight.recordButton,
    ),
    _TipPage(
      title: '标记重点',
      body: '双击麦克风添加录音标记\n震动表示完成',
      image: 'assets/product/guide_mark.webp',
      highlight: _TipHighlight.center,
    ),
    _TipPage(
      title: '佩戴麦克风',
      body: '推开磁吸垫片\n夹在衣物边缘',
      image: 'assets/product/guide_wear.webp',
      highlight: _TipHighlight.none,
    ),
  ];

  void _next() {
    if (_step < 1 + _tipPages.length) {
      setState(() => _step++);
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(key: ValueKey(_step), child: _buildStep(context)),
    );
  }

  Widget _buildStep(BuildContext context) {
    if (_step == 0) {
      return _SuccessStep(
        onContinue: _next,
        onClose: widget.onClose ?? widget.onDone,
      );
    }
    final tipIndex = _step - 1;
    if (tipIndex < _tipPages.length) {
      final page = _tipPages[tipIndex];
      return _TipStep(
        page: page,
        pageIndex: tipIndex,
        pageCount: _tipPages.length + 1, // tips + finale
        primaryLabel: '下一步',
        onPrimary: _next,
        onClose: widget.onClose ?? widget.onDone,
      );
    }
    // Finale: auto-sync (local equivalent of Feishu 智能纪要).
    return _TipStep(
      page: const _TipPage(
        title: '下载录音',
        body: '在设置中开启自动传输，可下载设备上的录音',
        image: 'assets/product/guide_sync.webp',
        highlight: _TipHighlight.none,
      ),
      pageIndex: _tipPages.length,
      pageCount: _tipPages.length + 1,
      primaryLabel: '我知道了',
      onPrimary: widget.onDone,
      onClose: widget.onClose ?? widget.onDone,
      primaryFilled: true,
    );
  }
}

enum _TipHighlight { none, recordButton, center }

class _TipPage {
  const _TipPage({
    required this.title,
    required this.body,
    required this.image,
    this.highlight = _TipHighlight.none,
  });

  final String title;
  final String body;
  final String image;
  final _TipHighlight highlight;
}

/// 🎉 连接成功 — dual battery snapshot.
class _SuccessStep extends StatelessWidget {
  const _SuccessStep({required this.onContinue, required this.onClose});

  final VoidCallback onContinue;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final info = c.info ?? c.lastKnownInfo;
    final mic = info?.battery ?? info?.displayBatteryPercent ?? 0;
    final box = info?.boxBattery ?? mic;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          const Text(
            '🎉  连接成功',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 28),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _BatteryProductCard(
                    image: 'assets/product/guide_connect_device.webp',
                    percent: mic,
                    label: '麦克风',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _BatteryProductCard(
                    image: 'assets/product/guide_connect_case.webp',
                    percent: box,
                    label: '充电仓',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: onContinue,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('继续'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatteryProductCard extends StatelessWidget {
  const _BatteryProductCard({
    required this.image,
    required this.percent,
    required this.label,
  });

  final String image;
  final int percent;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = percent.clamp(0, 100);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(
          image,
          height: 120,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Icon(
            label.contains('仓')
                ? Icons.battery_charging_full_rounded
                : Icons.mic_external_on_rounded,
            size: 72,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '$p%',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: p / 100.0,
            minHeight: 6,
            backgroundColor: AppColors.border,
            color: AppColors.mint,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _TipStep extends StatelessWidget {
  const _TipStep({
    required this.page,
    required this.pageIndex,
    required this.pageCount,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onClose,
    this.primaryFilled = false,
  });

  final _TipPage page;
  final int pageIndex;
  final int pageCount;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback onClose;
  final bool primaryFilled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 200,
                  child: Center(
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Image.asset(
                            page.image,
                            height: 180,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => Image.asset(
                              'assets/product/guide_connect_device.webp',
                              height: 160,
                              errorBuilder: (_, _, _) => const Icon(
                                Icons.headphones_rounded,
                                size: 96,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                          if (page.highlight == _TipHighlight.recordButton)
                            const Positioned.fill(
                              child: Align(
                                alignment: Alignment(0.53, 0.18),
                                child: _PulseDot(),
                              ),
                            ),
                          if (page.highlight == _TipHighlight.center)
                            const Positioned.fill(
                              child: Align(child: _PulseDot(size: 28)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  page.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  page.body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Page dots (tips + finale).
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(pageCount, (i) {
              final on = i == pageIndex;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: on ? 14 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: on ? AppColors.accent : AppColors.border,
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
          const SizedBox(height: 18),
          if (primaryFilled)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: onPrimary,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(primaryLabel),
              ),
            )
          else
            TextButton(
              onPressed: onPrimary,
              child: Text(
                primaryLabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({this.size = 22});

  final double size;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        final s = widget.size + 10 * t;
        return Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent.withValues(alpha: 0.25 + 0.25 * t),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.7),
              width: 2.5,
            ),
          ),
          child: Center(
            child: Container(
              width: widget.size * 0.45,
              height: widget.size * 0.45,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent,
              ),
            ),
          ),
        );
      },
    );
  }
}
