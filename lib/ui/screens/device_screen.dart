import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../crypto/device_crypto.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';

class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    if (!c.connected) {
      return _OfflineDeviceView(controller: c);
    }

    final info = c.info;
    final micBat = info?.battery;
    final caseBat = info?.boxBattery;
    return GradientScaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/product/d3200_device_connected_white.webp',
              width: 40,
              height: 40,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Image.asset(
                'assets/product/hero_connected_white.png',
                width: 40,
                height: 40,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.headphones_rounded,
                  size: 28,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                info?.hasIdentity == true ? 'soundcore Work' : '已连接',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: c.phase == AppPhase.busy ? null : c.refreshInfo,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '断开连接',
            onPressed: c.disconnect,
            icon: const Icon(Icons.link_off_rounded, color: AppColors.coral),
          ),
        ],
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
          children: [
            const SectionLabel('电量'),
            _DeviceSection(
              key: const ValueKey('device-battery-section'),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    children: [
                      Image.asset(
                        'assets/product/d3200_device_white.webp',
                        height: 28,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 4),
                      BatteryRing(
                        percent: micBat ?? 0,
                        charging: info?.charging ?? false,
                        size: 72,
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        '麦克风',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  Container(width: 1, height: 82, color: AppColors.border),
                  Column(
                    children: [
                      Image.asset(
                        'assets/product/d3200_chargebox_white.webp',
                        height: 28,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 4),
                      BatteryRing(
                        percent: caseBat ?? 0,
                        charging: info?.boxCharging ?? false,
                        size: 72,
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        '充电盒',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('录音'),
            _DeviceSection(
              key: const ValueKey('device-recording-section'),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: AccentButton(
                          label: c.recording ? '录音中…' : '开始',
                          icon: Icons.mic_rounded,
                          color: AppColors.coral,
                          onPressed: c.recording || c.blocksRecordingControl
                              ? null
                              : c.startRecord,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AccentButton(
                          label: '暂停',
                          icon: Icons.pause_rounded,
                          filled: false,
                          color: AppColors.amber,
                          onPressed: !c.recording || c.phase == AppPhase.busy
                              ? null
                              : c.pauseRecord,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  AccentButton(
                    label: '同步设备时钟',
                    icon: Icons.schedule_rounded,
                    filled: false,
                    onPressed: c.phase == AppPhase.busy ? null : c.syncTime,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('配对绑定'),
            _DeviceSection(
              key: const ValueKey('device-pairing-section'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: AccentButton(
                          label: c.bound ? '已绑定' : '绑定',
                          icon: Icons.link_rounded,
                          onPressed: c.bound || c.phase == AppPhase.busy
                              ? null
                              : () => c.bindDevice(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AccentButton(
                          label: '解绑',
                          icon: Icons.link_off_rounded,
                          filled: false,
                          color: AppColors.textSecondary,
                          onPressed: !c.bound || c.phase == AppPhase.busy
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: AppColors.bgCard,
                                      title: const Text('确认解绑？'),
                                      content: const Text(
                                        '将向设备发送解绑指令（与飞书相同，payload 00）。\n'
                                        '• 不会清空录音或恢复出厂\n'
                                        '• 成功后会断开连接\n'
                                        '• 之后可再扫描、连接并重新绑定',
                                        style: TextStyle(
                                          color: AppColors.textSecondary,
                                          height: 1.4,
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('取消'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('解绑'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) await c.unbindDevice();
                                },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 10),
                  _FirmwareAuthPanel(controller: c),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('设备信息'),
            _DeviceSection(
              key: const ValueKey('device-info-section'),
              child: Column(
                children: [
                  const _DeviceInfoRow(label: '产品', value: 'D3200'),
                  const Divider(),
                  _DeviceInfoRow(
                    label: '序列号',
                    value: info?.serialNumber.isNotEmpty == true
                        ? info!.serialNumber
                        : '—',
                  ),
                  const Divider(),
                  _DeviceInfoRow(
                    label: '固件版本',
                    value: info?.firmwareVersion.isNotEmpty == true
                        ? info!.firmwareVersion
                        : '—',
                  ),
                  const Divider(),
                  _DeviceInfoRow(label: '存储', value: info?.storageLabel ?? '—'),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('危险操作'),
            _DeviceSection(
              key: const ValueKey('device-danger-section'),
              borderColor: AppColors.coral.withValues(alpha: 0.25),
              child: AccentButton(
                label: '恢复出厂设置',
                icon: Icons.restart_alt_rounded,
                color: AppColors.coral,
                filled: false,
                onPressed: c.phase == AppPhase.busy
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: AppColors.bgCard,
                            title: const Text('确定恢复出厂？'),
                            content: const Text(
                              '将发送重置指令（0x01/0xB8）。'
                              '设备将恢复默认设置。',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text(
                                  '重置',
                                  style: TextStyle(color: AppColors.coral),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) await c.resetDevice();
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FirmwareAuthPanel extends StatelessWidget {
  const _FirmwareAuthPanel({required this.controller});

  final RecorderController controller;

  (String, Color) _statusBadge() {
    switch (controller.authState) {
      case DeviceAuthState.authenticated:
        return ('已认证', AppColors.mint);
      case DeviceAuthState.authenticating:
        return ('认证中…', AppColors.accent);
      case DeviceAuthState.noBindingKey:
        return ('设备无密钥', AppColors.amber);
      case DeviceAuthState.failed:
        return ('认证失败', AppColors.coral);
      case DeviceAuthState.unknown:
        return (
          controller.hasAuthCredentials ? '已保存密钥' : '未配置密钥',
          controller.hasAuthCredentials ? AppColors.accent : AppColors.textMuted,
        );
      case DeviceAuthState.unconfigured:
        return ('未配置密钥', AppColors.textMuted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final (badgeLabel, badgeColor) = _statusBadge();
    final busy = c.phase == AppPhase.busy;

    return Column(
      key: const ValueKey('device-auth-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '固件 03.56+ 认证（0B/8B）',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            StatusPill(label: badgeLabel, color: badgeColor),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          c.hasAuthCredentials
              ? 'Account ID: ${_maskId(c.authCredentials!.accountId)}'
              : '新固件需要绑定密钥完成 0B/8B 认证；未绑定官方 App 可直接密钥绑定，需与官方 App 共存可导入 btsnoop 或密钥。',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: AccentButton(
                label: '密钥绑定',
                icon: Icons.vpn_key_rounded,
                filled: !c.hasAuthCredentials,
                onPressed: busy ? null : () => c.bindDeviceWithKey(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AccentButton(
                label: '导入密钥',
                icon: Icons.upload_file_rounded,
                filled: false,
                onPressed: busy ? null : () => _showAuthImportDialog(context, c),
              ),
            ),
          ],
        ),
        if (c.hasAuthCredentials) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: AccentButton(
                  label: '重新认证',
                  icon: Icons.verified_user_outlined,
                  filled: false,
                  onPressed: busy
                      ? null
                      : () async {
                          final ok = await c.authenticateSession();
                          if (ok) {
                            await c.syncTime();
                            await c.listFiles();
                          }
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AccentButton(
                  label: '清除密钥',
                  icon: Icons.delete_outline_rounded,
                  filled: false,
                  color: AppColors.textSecondary,
                  onPressed: busy ? null : () => c.clearAuthCredentials(),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _maskId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}…${id.substring(id.length - 6)}';
  }
}

Future<void> _showAuthImportDialog(
  BuildContext context,
  RecorderController controller,
) async {
  final existing = controller.authCredentials;
  final accountCtrl = TextEditingController(text: existing?.accountId ?? '');
  final keyCtrl = TextEditingController(text: existing?.bindingKeyHex ?? '');
  final emailCtrl = TextEditingController(text: existing?.email ?? '');
  var inputIsSharedSecret = false;
  String? formError;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('导入固件绑定密钥'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '可从 Android 的 btsnoop_hci.log 自动提取 0B/87 账号 ID 与 0B/88 共享密钥，或手动填入十六进制密钥。',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                AccentButton(
                  label: '从 btsnoop_hci.log 提取',
                  icon: Icons.folder_open_rounded,
                  filled: false,
                  onPressed: () async {
                    try {
                      final file = await openFile();
                      if (file == null) return;
                      final bytes = await file.readAsBytes();
                      final extracted = controller.parseBtsnoopBytes(bytes);
                      if (extracted.accountId == null &&
                          extracted.bindingKey == null) {
                        setState(() {
                          formError = '未在文件中找到 0B/87 或 0B/88 绑定帧';
                        });
                        return;
                      }
                      setState(() {
                        if (extracted.accountId != null) {
                          accountCtrl.text = extracted.accountId!;
                        }
                        if (extracted.bindingKey != null) {
                          keyCtrl.text = DeviceCrypto.toHex(
                            extracted.bindingKey!,
                          );
                          inputIsSharedSecret = false;
                        }
                        if (extracted.email != null) {
                          emailCtrl.text = extracted.email!;
                        }
                        formError = extracted.isComplete
                            ? null
                            : '仅提取到部分信息，请补全剩余字段';
                      });
                    } catch (e) {
                      setState(() => formError = '读取文件失败：$e');
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: accountCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Account ID（40 位十六进制）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: keyCtrl,
                  decoration: InputDecoration(
                    labelText: inputIsSharedSecret
                        ? '0B/88 Shared Secret（64 位十六进制）'
                        : 'Binding Key（64 位十六进制）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                CheckboxListTile(
                  value: inputIsSharedSecret,
                  onChanged: (v) =>
                      setState(() => inputIsSharedSecret = v == true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '输入的是 0B/88 原始 shared_secret（自动 HKDF 派生）',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                TextField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(
                    labelText: '账号邮箱（可选，用于 0B/03）',
                    isDense: true,
                  ),
                ),
                if (formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    formError!,
                    style: const TextStyle(
                      color: AppColors.coral,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final accountId = accountCtrl.text.trim();
              final parsed = DeviceCrypto.parseHex(keyCtrl.text);
              if (accountId.isEmpty) {
                setState(() => formError = '请填写 Account ID');
                return;
              }
              if (parsed == null || parsed.length != 32) {
                setState(() => formError = '密钥必须是 32 字节（64 位十六进制）');
                return;
              }
              final email = emailCtrl.text.trim();
              final creds = inputIsSharedSecret
                  ? DeviceAuthCredentials.fromSharedSecret(
                      accountId: accountId,
                      sharedSecret: parsed,
                      email: email.isEmpty ? null : email,
                    )
                  : DeviceAuthCredentials(
                      accountId: accountId,
                      bindingKeyHex: DeviceCrypto.toHex(parsed),
                      email: email.isEmpty ? null : email,
                    );
              Navigator.pop(ctx);
              await controller.saveAuthCredentials(creds);
            },
            child: const Text('保存并认证'),
          ),
        ],
      ),
    ),
  );
  accountCtrl.dispose();
  keyCtrl.dispose();
  emailCtrl.dispose();
}

class _DeviceSection extends StatelessWidget {
  const _DeviceSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(0, 12, 0, 16),
    this.borderColor = AppColors.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DeviceInfoRow extends StatelessWidget {
  const _DeviceInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Disconnected Device tab: still show last known / bound unit.
class _OfflineDeviceView extends StatelessWidget {
  const _OfflineDeviceView({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final d = c.displayDevice;

    return GradientScaffold(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
          children: [
            if (d != null) ...[
              SurfaceCard(
                glow: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: _OfflineProductImage()),
                    const SizedBox(height: 10),
                    Text(
                      d.displayName,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    if (c.bound || d.isBoundAdvertised) ...[
                      const SizedBox(height: 10),
                      Center(
                        child: StatusPill(
                          label: c.bound ? '已绑定' : '广告已绑定',
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                    if (d.macAddress != null && d.macAddress!.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        d.macAddress!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    const Text(
                      '设备已断开。点下方按钮扫描并重新连接。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    AccentButton(
                      label: '扫描并连接',
                      icon: Icons.radar_rounded,
                      onPressed: () => showScanDevicesSheet(context),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 48),
              SurfaceCard(
                glow: true,
                child: Column(
                  children: [
                    const Icon(
                      Icons.devices_other_rounded,
                      size: 48,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '尚未连接设备',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '扫描附近的 soundcore Work（D3200）并连接。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    AccentButton(
                      label: '扫描设备',
                      icon: Icons.radar_rounded,
                      onPressed: () => showScanDevicesSheet(context),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OfflineProductImage extends StatelessWidget {
  const _OfflineProductImage();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: '设备离线，蓝牙连接已断开',
      child: SizedBox(
        width: 220,
        height: 142,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0.62,
              child: ColorFiltered(
                colorFilter: const ColorFilter.matrix([
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0.2126,
                  0.7152,
                  0.0722,
                  0,
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                ]),
                child: Image.asset(
                  'assets/product/d3200_device_connected_white.webp',
                  height: 132,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.headphones_rounded,
                    size: 64,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 7,
              right: 27,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.coral.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.coral.withValues(alpha: 0.24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.coral.withValues(alpha: 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.bluetooth_disabled_rounded,
                  size: 24,
                  color: AppColors.coral,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
