import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../protocol/models.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import 'connect_onboarding.dart';
import 'widgets.dart';

/// Feishu-style connect sheet: scan nearby D3200 devices and let the user pick
/// one. Persisted bound devices may still reconnect through the controller.
Future<void> showScanDevicesSheet(BuildContext context) {
  final c = context.read<RecorderController>();
  if (c.phase != AppPhase.scanning && c.phase != AppPhase.connecting) {
    unawaited(c.startScan());
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => const ScanDevicesSheet(),
  );
}

class ScanDevicesSheet extends StatefulWidget {
  const ScanDevicesSheet({super.key});

  @override
  State<ScanDevicesSheet> createState() => _ScanDevicesSheetState();
}

class _ScanDevicesSheetState extends State<ScanDevicesSheet> {
  String? _connectingId;

  /// After GATT success, show Feishu success + tips carousel.
  bool _showOnboarding = false;

  // A previously bound device should just reconnect — only an unrecognized
  // device needs the user to pick it and go through bind onboarding.
  bool _autoConnectTried = false;

  @override
  void initState() {
    super.initState();
    // Retry scan if list stays empty (device may only advertise after case button).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = context.read<RecorderController>();
      if (c.phase != AppPhase.scanning && c.phase != AppPhase.connecting) {
        unawaited(c.startScan());
      }
    });
  }

  void _enterOnboarding() {
    // Pull a fresh battery snapshot for the success screen.
    final c = context.read<RecorderController>();
    unawaited(c.refreshInfo(silent: true));
    setState(() => _showOnboarding = true);
  }

  bool _isBoundMatch(RecorderController c, ScannedDevice d) {
    if (d.isBoundAdvertised) return true;
    if (!c.bound) return false;
    final saved = c.lastKnownDevice;
    if (saved == null) return false;
    if (d.id == saved.id) return true;
    return saved.macAddress != null && d.macAddress == saved.macAddress;
  }

  Future<void> _connectDevice(ScannedDevice d) async {
    final c = context.read<RecorderController>();
    _connectingId = d.id;
    setState(() {});
    await c.connect(d);
    if (!mounted) return;
    if (c.connected) {
      _enterOnboarding();
    } else {
      _connectingId = null;
      setState(() {});
    }
  }

  void _maybeAutoConnectBound(RecorderController c) {
    if (_autoConnectTried || _showOnboarding) return;
    if (c.connected || c.phase == AppPhase.connecting) return;
    for (final d in c.devices) {
      if (_isBoundMatch(c, d)) {
        _autoConnectTried = true;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_connectDevice(d)),
        );
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final scanning = c.phase == AppPhase.scanning;
    final connecting = c.phase == AppPhase.connecting;
    final height = MediaQuery.sizeOf(context).height * 0.82;

    final showDeviceList = c.devices.isNotEmpty || connecting;
    _maybeAutoConnectBound(c);

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          if (!_showOnboarding) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Text(
              '扫描设备',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: _showOnboarding
                ? ConnectOnboarding(
                    onDone: () {
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    onClose: () {
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  )
                : showDeviceList
                ? _FoundDevicesPanel(
                    devices: c.devices,
                    connecting: connecting,
                    connectingId: _connectingId ?? c.activeDevice?.id,
                    busy: connecting || c.phase == AppPhase.busy,
                    scanning: scanning,
                    error: c.errorMessage,
                    onRescan: () {
                      _connectingId = null;
                      unawaited(c.startScan());
                    },
                    onTapDevice: _connectDevice,
                  )
                : _ConnectGuidePanel(
                    scanning: scanning,
                    connecting: connecting,
                    adsSeen: c.adsSeen,
                    error: c.errorMessage,
                    onRescan: () => unawaited(c.startScan()),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Feishu-style guide: seat mic in case, short-press bottom button.
class _ConnectGuidePanel extends StatefulWidget {
  const _ConnectGuidePanel({
    required this.scanning,
    required this.connecting,
    required this.adsSeen,
    required this.onRescan,
    this.error,
  });

  final bool scanning;
  final bool connecting;
  final int adsSeen;
  final VoidCallback onRescan;
  final String? error;

  @override
  State<_ConnectGuidePanel> createState() => _ConnectGuidePanelState();
}

class _ConnectGuidePanelState extends State<_ConnectGuidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 32),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Product + soft pulse (Feishu points at case button).
          SizedBox(
            height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final t = Curves.easeInOut.transform(_pulse.value);
                    return Container(
                      width: 120 + 40 * t,
                      height: 120 + 40 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withValues(
                          alpha: 0.08 + 0.06 * t,
                        ),
                      ),
                    );
                  },
                ),
                Image.asset(
                  'assets/product/guide_connect_case.webp',
                  height: 180,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Image.asset(
                    'assets/product/d3200_chargebox_white.webp',
                    height: 180,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.headphones_battery_rounded,
                      size: 96,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
                // Hint ring near case button area (bottom-left of product).
                Positioned(
                  left: 48,
                  bottom: 36,
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) {
                      final t = Curves.easeInOut.transform(_pulse.value);
                      return Container(
                        width: 18 + 6 * t,
                        height: 18 + 6 * t,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accent.withValues(
                            alpha: 0.35 + 0.25 * t,
                          ),
                          border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.6),
                            width: 2,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            '将麦克风放入充电仓',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '短按充电仓下方按钮完成连接',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          if (widget.scanning || widget.connecting)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.connecting
                        ? AppColors.mint
                        : AppColors.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.connecting ? '正在连接设备…' : '正在等待设备广播…',
                  style: TextStyle(
                    fontSize: 13,
                    color: widget.connecting
                        ? AppColors.mint
                        : AppColors.textMuted,
                  ),
                ),
              ],
            )
          else
            TextButton.icon(
              onPressed: widget.onRescan,
              icon: const Icon(
                Icons.radar_rounded,
                size: 22,
                color: AppColors.accent,
              ),
              label: const Text('重新扫描'),
            ),
          if (widget.adsSeen > 0) ...[
            const SizedBox(height: 10),
            Text(
              '已见 ${widget.adsSeen} 条 BLE 广播',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
          if (widget.error != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.coral,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FoundDevicesPanel extends StatelessWidget {
  const _FoundDevicesPanel({
    required this.devices,
    required this.connecting,
    required this.busy,
    required this.scanning,
    required this.onTapDevice,
    required this.onRescan,
    this.connectingId,
    this.error,
  });

  final List<ScannedDevice> devices;
  final bool connecting;
  final bool busy;
  final bool scanning;
  final String? connectingId;
  final ValueChanged<ScannedDevice> onTapDevice;
  final VoidCallback onRescan;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Column(
            children: [
              Image.asset(
                'assets/product/white_03_device_connect.webp',
                height: 100,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Image.asset(
                  'assets/product/d3200_device_white.webp',
                  height: 72,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                connecting ? '正在连接…' : '发现设备，点选连接',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: connecting ? AppColors.accent : AppColors.textPrimary,
                ),
              ),
              if (scanning)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '继续扫描中…',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              error!,
              style: const TextStyle(color: AppColors.coral, fontSize: 12),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final d = devices[i];
              final isConnecting = connecting && connectingId == d.id;
              return _SheetDeviceTile(
                device: d,
                connecting: isConnecting,
                busy: busy,
                onTap: () => onTapDevice(d),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: TextButton(
            onPressed: busy ? null : onRescan,
            child: const Text('重新扫描'),
          ),
        ),
      ],
    );
  }
}

class _SheetDeviceTile extends StatelessWidget {
  const _SheetDeviceTile({
    required this.device,
    required this.onTap,
    required this.busy,
    this.connecting = false,
  });

  final ScannedDevice device;
  final VoidCallback onTap;
  final bool busy;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final match = device.looksLikeSoundcore;
    return SurfaceCard(
      onTap: busy ? null : onTap,
      borderColor: connecting
          ? AppColors.accent.withValues(alpha: 0.7)
          : match
          ? AppColors.accent.withValues(alpha: 0.3)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: match
                  ? AppColors.accent.withValues(alpha: 0.12)
                  : AppColors.bg,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: connecting
                ? const Padding(
                    padding: EdgeInsets.all(11),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: AppColors.accent,
                    ),
                  )
                : match
                ? Image.asset(
                    'assets/product/d3200_device_white.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.mic_external_on_rounded,
                      color: AppColors.accent,
                    ),
                  )
                : const Icon(
                    Icons.bluetooth_rounded,
                    color: AppColors.textMuted,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.displayName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  connecting ? '正在连接…' : device.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: connecting ? AppColors.accent : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (connecting)
            const StatusPill(label: '连接中', color: AppColors.accent)
          else if (device.isD3200)
            const StatusPill(label: 'D3200', color: AppColors.mint)
          else
            StatusPill(label: '${device.rssi} dBm', color: AppColors.textMuted),
        ],
      ),
    );
  }
}
