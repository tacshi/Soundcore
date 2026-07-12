import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/widgets.dart';

/// App preferences: STT providers, streaming, BLE, diagnostics.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();

    return GradientScaffold(
      appBar: AppBar(title: const Text('设置')),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
          children: [
            const SectionLabel('传输'),
            SurfaceCard(
              child: _SettingsSwitch(
                title: '自动传输',
                subtitle: c.autoTransferActive
                    ? '正在传输设备端未导出录音…'
                    : '录音时优先传输当前录音；结束后自动补齐未导出录音',
                value: c.autoRealtime,
                onChanged: c.setAutoRealtime,
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('AI 转写'),
            SurfaceCard(
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
                  const Text(
                    '服务商',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  _ProviderSelector(controller: c),
                  const SizedBox(height: 14),
                  // Only the selected provider’s key field (bound 1:1).
                  if (c.sttProvider == SttProvider.xai)
                    _ApiKeyField(
                      key: const ValueKey('apikey-xai'),
                      label: 'xAI API Key',
                      envName: 'XAI_API_KEY',
                      initialValue: c.xaiApiKeyStored ?? '',
                      configured: c.xaiConfigured,
                      onSave: c.setXaiApiKey,
                    )
                  else
                    _ApiKeyField(
                      key: const ValueKey('apikey-soniox'),
                      label: 'Soniox API Key',
                      envName: 'SONIOX_API_KEY',
                      initialValue: c.sonioxApiKeyStored ?? '',
                      configured: c.sonioxConfigured,
                      onSave: c.setSonioxApiKey,
                    ),
                  const SizedBox(height: 14),
                  const Text(
                    '语言提示',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final (index, e) in const [
                        ('zh', '中文'),
                        ('en', 'English'),
                        ('ja', '日本語'),
                        ('ko', '한국어'),
                      ].indexed) ...[
                        if (index > 0) const SizedBox(width: 6),
                        Expanded(
                          child: SizedBox(
                            width: double.infinity,
                            child: ChoiceChip(
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(e.$2),
                              ),
                              selected: c.transcriptLanguage == e.$1,
                              onSelected: (_) => c.setTranscriptLanguage(e.$1),
                              selectedColor: AppColors.accentSoft,
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 6,
                              ),
                              labelPadding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              labelStyle: TextStyle(
                                color: c.transcriptLanguage == e.$1
                                    ? AppColors.accent
                                    : AppColors.textSecondary,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
  final ValueChanged<bool> onChanged;

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

/// Provider picker: dropdown when multiple keys exist; segmented otherwise.
class _ProviderSelector extends StatelessWidget {
  const _ProviderSelector({required this.controller});

  final RecorderController controller;

  String _statusLabel(SttProvider p, RecorderController c) {
    final ok = p == SttProvider.xai ? c.xaiConfigured : c.sonioxConfigured;
    return ok ? '${p.label} · 已配置' : '${p.label} · 未配置';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final multiConfigured = c.xaiConfigured && c.sonioxConfigured;

    if (multiConfigured) {
      // Both keys ready → dropdown chooses which backend is active.
      // Still shows that provider’s key field below for review/edit.
      final options = const [SttProvider.soniox, SttProvider.xai]
          .where(
            (p) =>
                (p == SttProvider.xai && c.xaiConfigured) ||
                (p == SttProvider.soniox && c.sonioxConfigured),
          )
          .toList();
      final selected = options.contains(c.sttProvider)
          ? c.sttProvider
          : options.first;

      return DropdownButtonFormField<SttProvider>(
        // Controlled by parent; key forces rebuild when selection changes.
        key: ValueKey('provider-$selected'),
        initialValue: selected,
        decoration: InputDecoration(
          isDense: true,
          labelText: '当前使用的服务商',
          filled: true,
          fillColor: AppColors.bgElevated,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
          ),
        ),
        items: [
          for (final p in options)
            DropdownMenuItem(value: p, child: Text(_statusLabel(p, c))),
        ],
        onChanged: (p) {
          if (p != null) c.setSttProvider(p);
        },
      );
    }

    // 0–1 keys: segmented control to pick which provider to configure / use.
    return SegmentedButton<SttProvider>(
      segments: [
        for (final p in const [SttProvider.soniox, SttProvider.xai])
          ButtonSegment(
            value: p,
            label: Text(
              p == SttProvider.xai
                  ? (c.xaiConfigured ? 'xAI' : 'xAI 未配置')
                  : (c.sonioxConfigured ? 'Soniox' : 'Soniox 未配置'),
              style: const TextStyle(fontSize: 12),
            ),
            icon: Icon(
              (p == SttProvider.xai ? c.xaiConfigured : c.sonioxConfigured)
                  ? Icons.check_circle
                  : Icons.key_off_outlined,
              size: 16,
            ),
          ),
      ],
      selected: {c.sttProvider},
      onSelectionChanged: (s) {
        if (s.isNotEmpty) c.setSttProvider(s.first);
      },
      showSelectedIcon: false,
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
  bool _obscure = true;
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
    final borderColor = widget.configured
        ? AppColors.mint.withValues(alpha: 0.4)
        : AppColors.accent.withValues(alpha: 0.35);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
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
            obscureText: _obscure,
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
                borderSide: const BorderSide(
                  color: AppColors.accent,
                  width: 1.4,
                ),
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _obscure ? '显示' : '隐藏',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                  ),
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
            '环境变量：export ${widget.envName}=…（重启后仍可作为后备）',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
