import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/soniox_languages.dart';
import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Immersive, face-to-face live translation surface.
class CommunicationScreen extends StatelessWidget {
  const CommunicationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: _TranslationPanel(
                    key: const ValueKey('communication-owner-panel'),
                    languageCode: c.ownerLanguage,
                    turns: c.ownerTranslationTurns,
                    backgroundColor: const Color(0xFFF0F4FF),
                    accentColor: AppColors.accent,
                  ),
                ),
                Expanded(
                  child: RotatedBox(
                    key: const ValueKey('communication-guest-rotation'),
                    quarterTurns: 2,
                    child: _TranslationPanel(
                      key: const ValueKey('communication-guest-panel'),
                      languageCode: c.guestLanguage,
                      turns: c.guestTranslationTurns,
                      backgroundColor: const Color(0xFFECFAF5),
                      accentColor: AppColors.mint,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.center,
              child: _CenterControls(controller: c),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranslationPanel extends StatelessWidget {
  const _TranslationPanel({
    super.key,
    required this.languageCode,
    required this.turns,
    required this.backgroundColor,
    required this.accentColor,
  });

  final String languageCode;
  final List<SttTranslationTurn> turns;
  final Color backgroundColor;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final visibleTurns = turns
        .where((turn) => turn.text.trim().isNotEmpty)
        .toList(growable: false);
    final latest = visibleTurns.isEmpty ? null : visibleTurns.last;
    final contextTurns = latest == null
        ? const <SttTranslationTurn>[]
        : visibleTurns
              .take(visibleTurns.length - 1)
              .where((turn) => turn.isFinal)
              .toList()
              .reversed
              .take(2)
              .toList()
              .reversed
              .toList();
    final language = sonioxLanguageFor(languageCode);

    return Semantics(
      label: '${language.name} translation',
      child: ColoredBox(
        color: backgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 34),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    language.label,
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: latest == null
                    ? Center(
                        child: Text(
                          '…',
                          style: TextStyle(
                            color: accentColor.withValues(alpha: 0.55),
                            fontSize: 44,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        reverse: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (final turn in contextTurns) ...[
                              Text(
                                turn.text,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 16,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            Text(
                              latest.text,
                              key: ValueKey(
                                'communication-latest-$languageCode',
                              ),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final error =
        c.transcriptError ??
        (!c.sttConfigured ? '请先在设置中配置 SONIOX_API_KEY' : null);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        key: const ValueKey('communication-center-controls'),
        margin: const EdgeInsets.symmetric(horizontal: 18),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: AppColors.bgCard.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
          boxShadow: AppColors.cardShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: AppColors.coral,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '交流 · Soniox',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('communication-pause'),
                  tooltip: '暂停录音',
                  visualDensity: VisualDensity.compact,
                  onPressed: c.recording ? c.pauseRecord : null,
                  icon: const Icon(Icons.pause_rounded, size: 20),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 4),
              Text(
                error,
                key: const ValueKey('communication-error'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.coral,
                  fontSize: 11,
                  height: 1.25,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
