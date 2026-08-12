import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/recorder_controller.dart';
import '../theme/app_theme.dart';
import 'screens/device_screen.dart';
import 'screens/communication_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  int _handledShortcutNavigationRevision = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final shortcutRevision = c.shortcutNavigationRevision;
    if (shortcutRevision != _handledShortcutNavigationRevision) {
      _handledShortcutNavigationRevision = shortcutRevision;
      if (_index != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _index != 0) setState(() => _index = 0);
        });
      }
    }

    if (c.isCommunicationLiveSession) {
      return const CommunicationScreen();
    }

    final pages = [
      const HomeScreen(),
      const DeviceScreen(),
      const SettingsScreen(),
    ];

    return Stack(
      children: [
        IndexedStack(index: _index, children: pages),
        Positioned(
          left: 24,
          right: 24,
          bottom: 12,
          child: _NavBar(
            index: _index,
            live: c.isLiveSession,
            onSelect: (i) {
              setState(() => _index = i);
              final ctrl = context.read<RecorderController>();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                // Home: refresh offline file inventory when not mid live take.
                if (i == 0 && !ctrl.isLiveSession) {
                  ctrl.refreshFilesOnTabEnter();
                }
                // Device: pull fresh battery / info on every visit.
                if (i == 1) {
                  ctrl.refreshInfoOnDeviceTabEnter();
                }
              });
            },
          ),
        ),
      ],
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.index,
    required this.onSelect,
    required this.live,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.bgCard.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            _NavItem(
              icon: live ? Icons.graphic_eq_rounded : Icons.home_rounded,
              label: live ? '转写' : '首页',
              selected: index == 0,
              badge: live,
              badgeColor: AppColors.coral,
              onTap: () => onSelect(0),
            ),
            _NavItem(
              icon: Icons.devices_rounded,
              label: '设备',
              selected: index == 1,
              onTap: () => onSelect(1),
            ),
            _NavItem(
              icon: Icons.settings_rounded,
              label: '设置',
              selected: index == 2,
              onTap: () => onSelect(2),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = false,
    this.badgeColor = AppColors.mint,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool badge;
  final Color badgeColor;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textMuted;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: color, size: 20),
                  if (badge)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: badgeColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
