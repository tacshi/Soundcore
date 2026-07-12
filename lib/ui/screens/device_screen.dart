import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
            const SizedBox(width: 8),
            StatusPill(
              label: c.connected ? '在线' : '离线',
              color: c.connected ? AppColors.mint : AppColors.coral,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '扫描设备',
            onPressed: () => showScanDevicesSheet(context),
            icon: const Icon(Icons.bluetooth_searching_rounded),
          ),
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
            SurfaceCard(
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
            const SectionLabel('设备信息'),
            SurfaceCard(
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
                  const Divider(),
                  _DeviceInfoRow(
                    label: '充电盒 MAC',
                    value: info?.boxMac.isNotEmpty == true ? info!.boxMac : '—',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('录音'),
            SurfaceCard(
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
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    c.bound ? '当前状态：已绑定' : '当前状态：未绑定（本地控制通常仍可用）',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: AccentButton(
                          label: c.bound ? '已绑定' : '绑定',
                          icon: Icons.link_rounded,
                          onPressed: c.bound || c.phase == AppPhase.busy
                              ? null
                              : c.bindDevice,
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
                                        '将向设备发送解绑指令（与飞书相同）。\n'
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
                ],
              ),
            ),
            const SizedBox(height: 18),
            const SectionLabel('危险操作'),
            SurfaceCard(
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
    final info = c.lastKnownInfo;

    return GradientScaffold(
      appBar: AppBar(
        title: Text(c.displayDeviceName),
        actions: [
          IconButton(
            tooltip: '扫描设备',
            onPressed: () => showScanDevicesSheet(context),
            icon: const Icon(Icons.bluetooth_searching_rounded),
          ),
        ],
      ),
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
                    Center(
                      child: Image.asset(
                        'assets/product/d3200_device_connected_white.webp',
                        height: 120,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.headphones_rounded,
                          size: 64,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      d.displayName,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        const StatusPill(label: '离线', color: AppColors.coral),
                        if (c.bound)
                          const StatusPill(
                            label: '已绑定',
                            color: AppColors.accent,
                          )
                        else if (d.isBoundAdvertised)
                          const StatusPill(
                            label: '广告已绑定',
                            color: AppColors.accent,
                          ),
                        if (d.isD3200)
                          const StatusPill(
                            label: 'D3200',
                            color: AppColors.mint,
                          ),
                      ],
                    ),
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
              if (info != null) ...[
                const SizedBox(height: 18),
                const SectionLabel('上次设备信息'),
                SurfaceCard(
                  child: Column(
                    children: [
                      InfoRow(
                        label: '序列号',
                        value: info.serialNumber.isNotEmpty
                            ? info.serialNumber
                            : '—',
                      ),
                      const Divider(),
                      InfoRow(
                        label: '固件版本',
                        value: info.firmwareVersion.isNotEmpty
                            ? info.firmwareVersion
                            : '—',
                      ),
                      const Divider(),
                      InfoRow(
                        label: '麦克风电量',
                        value: info.battery != null ? '${info.battery}%' : '—',
                      ),
                      const Divider(),
                      InfoRow(
                        label: '充电盒电量',
                        value: info.boxBattery != null
                            ? '${info.boxBattery}%'
                            : '—',
                      ),
                      const Divider(),
                      const InfoRow(label: '产品', value: 'D3200'),
                    ],
                  ),
                ),
              ],
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
