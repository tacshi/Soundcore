import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/stt_types.dart';
import '../../ai/apple_speech.dart';
import '../../ai/soniox_languages.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/widgets.dart';

/// Processing choices apply to the next recording.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();

    return GradientScaffold(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const SectionLabel('传输'),
            _SettingsGroup(
              key: const ValueKey('settings-transfer-group'),
              child: _SettingsSwitch(
                title: '自动传输',
                subtitle: c.autoTransferActive
                    ? '正在传输设备端未导出录音…'
                    : '自动下载设备上的历史录音',
                value: c.autoRealtime,
                onChanged: c.setAutoRealtime,
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('语音与翻译'),
            _SettingsGroup(
              key: const ValueKey('settings-stt-group'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SettingsSwitch(
                    title: '自动转写',
                    subtitle: '录音时生成文字',
                    value: c.autoTranscribe,
                    onChanged: c.setAutoTranscribe,
                  ),
                  const Divider(height: 20),
                  _ProviderSelector(controller: c),
                  const SizedBox(height: 16),
                  if (c.speechProvider == SttProvider.soniox) ...[
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
                  ] else
                    _AppleLanguageSettings(controller: c),
                  if (c.isLiveSession) ...[
                    const SizedBox(height: 12),
                    const Text(
                      '更改将用于下一段录音',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const Divider(height: 28),
                  _SttModeSelector(controller: c),
                  if (c.sttMode == SttDisplayMode.translation &&
                      c.speechProvider == SttProvider.soniox) ...[
                    const SizedBox(height: 14),
                    _TranslationLanguageSettings(controller: c),
                  ],
                  if (c.speechProvider == SttProvider.soniox &&
                      c.sttMode == SttDisplayMode.conversation) ...[
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

class _ProviderSelector extends StatelessWidget {
  const _ProviderSelector({required this.controller});
  final RecorderController controller;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<SttProvider>(
    key: ValueKey('speech-provider-${controller.speechProvider.name}'),
    initialValue: controller.speechProvider,
    decoration: const InputDecoration(labelText: '语音服务'),
    isExpanded: true,
    items: [
      for (final provider in SttProvider.values)
        DropdownMenuItem(value: provider, child: Text(provider.label)),
    ],
    onChanged: (provider) {
      if (provider != null) controller.setSpeechProvider(provider);
    },
  );
}

class _AppleLanguageSettings extends StatelessWidget {
  const _AppleLanguageSettings({required this.controller});
  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final capabilities = c.appleCapabilities;
    final preparing = c.appleLanguagePreparationBusy;
    final loading = c.appleCapabilitiesLoading;
    if (!capabilities.supported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            loading
                ? '正在检查设备支持…'
                : c.appleSetupError ?? 'Apple 设备端需要 iOS 26 和受支持的设备。',
            style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          if (!loading)
            TextButton.icon(
              onPressed: c.refreshAppleCapabilities,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新检查'),
            ),
        ],
      );
    }
    final speechReady = capabilities.speechStatus == SpeechResourceStatus.ready;
    final translationReady =
        capabilities.translationStatus == SpeechResourceStatus.ready;
    final requiresDownload =
        capabilities.speechStatus == SpeechResourceStatus.needsDownload ||
        capabilities.translationStatus == SpeechResourceStatus.needsDownload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AppleLanguageField(
          label: '原文语言',
          value: c.appleSourceLanguage,
          languages: capabilities.speechLanguages,
          onChanged: preparing ? null : c.setAppleSourceLanguage,
        ),
        const SizedBox(height: 16),
        _AppleLanguageField(
          label: '翻译目标语言',
          value: c.translationTargetLanguage,
          languages: capabilities.translationLanguages,
          onChanged: preparing ? null : c.setTranslationTargetLanguage,
        ),
        const SizedBox(height: 12),
        Text(
          preparing
              ? '正在准备语言…'
              : loading
              ? '正在检查语言…'
              : !speechReady
              ? (capabilities.speechStatus == SpeechResourceStatus.unsupported
                    ? '请选择受支持的原文语言'
                    : '转写语言需要下载')
              : !translationReady
              ? (capabilities.translationStatus ==
                        SpeechResourceStatus.unsupported
                    ? '转写可用，请选择受支持的翻译语言组合'
                    : '转写可用，翻译语言需要下载')
              : '转写和翻译语言已就绪',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        if (c.appleSetupError != null) ...[
          const SizedBox(height: 8),
          Text(
            c.appleSetupError!,
            style: const TextStyle(
              color: AppColors.coral,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
        if (requiresDownload || preparing || c.appleSetupError != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('prepare-apple-languages'),
              onPressed: preparing || loading || c.isLiveSession
                  ? null
                  : c.prepareAppleLanguages,
              icon: preparing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                preparing
                    ? '准备中…'
                    : c.appleSetupError == null
                    ? '下载并准备语言'
                    : '重试',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AppleLanguageField extends StatelessWidget {
  const _AppleLanguageField({
    required this.label,
    required this.value,
    required this.languages,
    required this.onChanged,
  });
  final String label;
  final String value;
  final List<SpeechLanguage> languages;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) {
    final selected = languages
        .where((language) => language.code.toLowerCase() == value.toLowerCase())
        .firstOrNull
        ?.code;
    return DropdownButtonFormField<String>(
      key: ValueKey('apple-language-$label-$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      hint: const Text('选择语言'),
      items: [
        for (final language in languages)
          DropdownMenuItem(
            value: language.code,
            child: Text(language.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (value) {
              if (value != null) onChanged!(value);
            },
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
    return DropdownButtonFormField<String>(
      key: const ValueKey('transcript-language-selector'),
      initialValue: selected,
      decoration: const InputDecoration(labelText: '语言提示'),
      isExpanded: true,
      items: [
        for (final language in _languages)
          DropdownMenuItem(value: language.$1, child: Text(language.$2)),
      ],
      onChanged: (value) {
        if (value != null) controller.setTranscriptLanguage(value);
      },
    );
  }
}

class _SttModeSelector extends StatelessWidget {
  const _SttModeSelector({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final soniox = c.speechProvider == SttProvider.soniox;
    final subtitle = !c.autoTranscribe
        ? '请先开启自动转写'
        : soniox
        ? '翻译为单向，交流为双向'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '实时模式',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 10),
        SegmentedButton<SttDisplayMode>(
          key: const ValueKey('stt-display-mode-selector'),
          segments: [
            const ButtonSegment(
              value: SttDisplayMode.transcription,
              label: Text('转写'),
            ),
            ButtonSegment(
              value: SttDisplayMode.translation,
              label: const Text('翻译'),
              enabled:
                  c.autoTranscribe &&
                  (c.speechProvider == SttProvider.apple
                      ? c.appleTranslationAvailable
                      : c.sonioxTranslationModeAvailable),
            ),
            if (soniox)
              ButtonSegment(
                value: SttDisplayMode.conversation,
                label: const Text('交流'),
                enabled: c.conversationModeAvailable,
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
                  color: AppColors.textSecondary,
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
                    color: AppColors.textSecondary,
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
              color: AppColors.textSecondary,
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
                      color: AppColors.textSecondary,
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
            color: AppColors.textSecondary,
            fontSize: 10,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}
