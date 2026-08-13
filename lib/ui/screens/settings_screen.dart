import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/stt_types.dart';
import '../../ai/soniox_languages.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/widgets.dart';

/// App preferences: Soniox STT, streaming, BLE, and diagnostics.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();

    return GradientScaffold(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
          children: [
            const SectionLabel('传输'),
            _SettingsGroup(
              key: const ValueKey('settings-transfer-group'),
              child: _SettingsSwitch(
                title: '自动传输',
                subtitle: c.autoTransferActive
                    ? '正在传输设备端未导出录音…'
                    : '自动补齐已结束但未导出的历史录音（当前录音始终实时传输，以支持转写）',
                value: c.autoRealtime,
                onChanged: c.setAutoRealtime,
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('AI 转写'),
            _SettingsGroup(
              key: const ValueKey('settings-stt-group'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SettingsSwitch(
                    title: '自动转写',
                    subtitle: '录音时实时/近实时生成文字',
                    value: c.autoTranscribe,
                    onChanged: c.setAutoTranscribe,
                  ),
                  const Divider(height: 20),
                  _ApiKeyField(
                    key: const ValueKey('apikey-soniox'),
                    label: 'Soniox API Key',
                    envName: 'SONIOX_API_KEY',
                    initialValue: c.sonioxApiKeyStored ?? '',
                    configured: c.sonioxConfigured,
                    onSave: c.setSonioxApiKey,
                  ),
                  const SizedBox(height: 14),
                  _TranscriptLanguageSelector(controller: c),
                  const Divider(height: 28),
                  _SttModeSelector(controller: c),
                  if (c.sttMode == SttDisplayMode.translation) ...[
                    const SizedBox(height: 14),
                    _TranslationLanguageSettings(controller: c),
                  ],
                  if (c.sttMode == SttDisplayMode.conversation) ...[
                    const SizedBox(height: 14),
                    _CommunicationLanguageSettings(controller: c),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
        child: child,
      ),
    );
  }
}

class _TranscriptLanguageSelector extends StatelessWidget {
  const _TranscriptLanguageSelector({required this.controller});

  static const _languages = [
    ('auto', '自动'),
    ('zh', '中文'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
  ];

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final selected =
        _languages.any(
          (language) => language.$1 == controller.transcriptLanguage,
        )
        ? controller.transcriptLanguage
        : 'auto';
    return Row(
      children: [
        const Expanded(
          child: Text(
            '语言提示',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('transcript-language-selector'),
            value: selected,
            isDense: true,
            borderRadius: BorderRadius.circular(10),
            icon: const Icon(Icons.expand_more_rounded, size: 18),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            items: [
              for (final language in _languages)
                DropdownMenuItem(value: language.$1, child: Text(language.$2)),
            ],
            onChanged: (value) {
              if (value != null) controller.setTranscriptLanguage(value);
            },
          ),
        ),
      ],
    );
  }
}

class _SttModeSelector extends StatelessWidget {
  const _SttModeSelector({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final subtitle = !c.autoTranscribe ? '请先开启自动转写' : '翻译为单向翻译，交流为面对面双向翻译';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '实时模式',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 12,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<SttDisplayMode>(
          key: const ValueKey('stt-display-mode-selector'),
          segments: [
            const ButtonSegment(
              value: SttDisplayMode.transcription,
              label: Text('转写'),
              icon: Icon(Icons.subtitles_outlined),
            ),
            ButtonSegment(
              value: SttDisplayMode.translation,
              label: const Text('翻译'),
              icon: const Icon(Icons.translate_rounded),
              enabled: c.sonioxTranslationModeAvailable,
            ),
            ButtonSegment(
              value: SttDisplayMode.conversation,
              label: const Text('交流'),
              icon: const Icon(Icons.record_voice_over_outlined),
              enabled: c.sonioxTranslationModeAvailable,
            ),
          ],
          selected: {c.sttMode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) c.setSttMode(selection.first);
          },
        ),
      ],
    );
  }
}

class _TranslationLanguageSettings extends StatelessWidget {
  const _TranslationLanguageSettings({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    return _LanguageField(
      label: '目标语言',
      code: controller.translationTargetLanguage,
      excludedCode: null,
      onSelected: controller.setTranslationTargetLanguage,
    );
  }
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: value,
          activeTrackColor: AppColors.accent.withValues(alpha: 0.45),
          activeThumbColor: AppColors.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _CommunicationLanguageSettings extends StatelessWidget {
  const _CommunicationLanguageSettings({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LanguageField(
          label: '我的语言',
          code: c.ownerLanguage,
          excludedCode: c.guestLanguage,
          onSelected: c.setOwnerLanguage,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: IconButton(
              key: const ValueKey('swap-communication-languages'),
              tooltip: '交换语言',
              visualDensity: VisualDensity.compact,
              onPressed: c.swapCommunicationLanguages,
              icon: const Icon(
                Icons.swap_vert_rounded,
                color: AppColors.violet,
              ),
            ),
          ),
        ),
        _LanguageField(
          label: '对方语言',
          code: c.guestLanguage,
          excludedCode: c.ownerLanguage,
          onSelected: c.setGuestLanguage,
        ),
      ],
    );
  }
}

class _LanguageField extends StatelessWidget {
  const _LanguageField({
    required this.label,
    required this.code,
    required this.excludedCode,
    required this.onSelected,
  });

  final String label;
  final String code;
  final String? excludedCode;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final language = sonioxLanguageFor(code);
    return OutlinedButton(
      key: ValueKey('communication-language-$label'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () async {
        final selected = await showModalBottomSheet<String>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: AppColors.bgCard,
          builder: (_) => _LanguagePickerSheet(
            title: label,
            selectedCode: code,
            excludedCode: excludedCode,
          ),
        );
        if (selected != null) onSelected(selected);
      },
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  language.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const Icon(Icons.search_rounded, size: 20),
        ],
      ),
    );
  }
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet({
    required this.title,
    required this.selectedCode,
    required this.excludedCode,
  });

  final String title;
  final String selectedCode;
  final String? excludedCode;

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final languages = sonioxLanguages.where((language) {
      if (language.code == widget.excludedCode) return false;
      if (query.isEmpty) return true;
      return language.code.contains(query) ||
          language.name.toLowerCase().contains(query);
    }).toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '选择${widget.title}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SearchBar(
                  hintText: '搜索语言或代码',
                  leading: const Icon(Icons.search_rounded),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: languages.length,
              itemBuilder: (context, index) {
                final language = languages[index];
                final selected = language.code == widget.selectedCode;
                return ListTile(
                  title: Text(language.name),
                  subtitle: Text(language.code),
                  trailing: selected
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop(language.code),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ApiKeyField extends StatefulWidget {
  const _ApiKeyField({
    super.key,
    required this.label,
    required this.envName,
    required this.initialValue,
    required this.configured,
    required this.onSave,
  });

  final String label;
  final String envName;
  final String initialValue;
  final bool configured;
  final ValueChanged<String?> onSave;

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  late final TextEditingController _controller;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant _ApiKeyField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync from controller only when not mid-edit.
    if (!_dirty && oldWidget.initialValue != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final v = _controller.text.trim();
    widget.onSave(v.isEmpty ? null : v);
    setState(() => _dirty = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          v.isEmpty ? '已清除 ${widget.label}' : '已保存 ${widget.label}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              widget.configured ? Icons.verified_rounded : Icons.key_outlined,
              size: 16,
              color: widget.configured ? AppColors.mint : AppColors.amber,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            Text(
              widget.configured ? '已配置' : '未配置',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: widget.configured ? AppColors.mint : AppColors.amber,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(
            fontSize: 13,
            fontFamily: 'Menlo',
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: '粘贴 API Key…',
            hintStyle: const TextStyle(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
            filled: true,
            fillColor: AppColors.bgElevated,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_controller.text.isNotEmpty)
                  IconButton(
                    tooltip: '清除',
                    onPressed: () {
                      _controller.clear();
                      setState(() => _dirty = true);
                      widget.onSave(null);
                      setState(() => _dirty = false);
                    },
                    icon: const Icon(
                      Icons.clear_rounded,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          onChanged: (_) {
            if (!_dirty) setState(() => _dirty = true);
          },
          onSubmitted: (_) => _commit(),
          onEditingComplete: _commit,
        ),
        if (_dirty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: AccentButton(
              label: '保存',
              icon: Icons.save_rounded,
              expand: false,
              onPressed: _commit,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '环境变量：export ${widget.envName}=…',
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 10,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}
