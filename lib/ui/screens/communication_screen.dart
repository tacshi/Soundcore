import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/soniox_languages.dart';
import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Immersive, face-to-face live translation surface.
class CommunicationScreen extends StatefulWidget {
  const CommunicationScreen({super.key, this.reference});
  final RecordingReference? reference;
  @override
  State<CommunicationScreen> createState() => _CommunicationScreenState();
}

class _CommunicationScreenState extends State<CommunicationScreen> {
  String _owner = 'en';
  String _guest = 'zh';
  List<SttTranslationTurn> _ownerTurns = const [];
  List<SttTranslationTurn> _guestTurns = const [];
  String? _error;
  bool _captured = false;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final currentReference = c.currentRecordingReference;
    final displayed = widget.reference == null
        ? null
        : c.recordingView(widget.reference!).reference;
    final current =
        widget.reference == null ||
        currentReference != null &&
            (currentReference.key == widget.reference!.key ||
                currentReference.fileId != null &&
                    currentReference.fileId == displayed?.fileId ||
                currentReference.path != null &&
                    currentReference.path == displayed?.path);
    if (current) {
      if (!_captured || c.recording) {
        _owner = c.activeOwnerLanguage;
        _guest = c.activeGuestLanguage;
        _captured = true;
      }
      _ownerTurns = List.of(c.ownerTranslationTurns);
      _guestTurns = List.of(c.guestTranslationTurns);
      _error = c.transcriptError;
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('双向交流')),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: _TranslationPanel(
                    key: const ValueKey('communication-owner-panel'),
                    languageCode: _owner,
                    turns: _ownerTurns,
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
                      languageCode: _guest,
                      turns: _guestTurns,
                      backgroundColor: const Color(0xFFECFAF5),
                      accentColor: AppColors.mint,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.center,
              child: _CenterControls(
                controller: c,
                current: current,
                error: _error,
              ),
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
  const _CenterControls({
    required this.controller,
    required this.current,
    this.error,
  });

  final RecorderController controller;
  final bool current;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = controller;
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
                  decoration: BoxDecoration(
                    color: current && c.recording
                        ? AppColors.coral
                        : AppColors.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    current && c.recording ? '交流 · Soniox' : '已暂停',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('communication-pause'),
                  tooltip: '暂停录音',

                  onPressed: current && c.recording && c.phase != AppPhase.busy
                      ? c.pauseRecord
                      : null,
                  icon: const Icon(Icons.pause_rounded, size: 20),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 4),
              Text(
                error!,
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
