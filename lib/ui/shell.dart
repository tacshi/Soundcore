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

    final live = c.isLiveSession;
    if (live && _index != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _index != 0) setState(() => _index = 0);
      });
    }

    final pages = [
      const HomeScreen(),
      const DeviceScreen(),
      const SettingsScreen(),
    ];

    return Stack(
      children: [
        IndexedStack(index: live ? 0 : _index, children: pages),
        if (!live)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _NavBar(
              index: _index,
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
  const _NavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bgCard,
      child: SafeArea(
        top: false,
        child: Container(
          key: const ValueKey('bottom-navigation-bar'),
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 3),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              _NavItem(
                key: const ValueKey('nav-home'),
                icon: Icons.home_rounded,
                label: '首页',
                selected: index == 0,
                onTap: () => onSelect(0),
              ),
              _NavItem(
                key: const ValueKey('nav-device'),
                icon: Icons.devices_rounded,
                label: '设备',
                selected: index == 1,
                onTap: () => onSelect(1),
              ),
              _NavItem(
                key: const ValueKey('nav-settings'),
                icon: Icons.settings_rounded,
                label: '设置',
                selected: index == 2,
                onTap: () => onSelect(2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textMuted;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedContainer(
                key: selected ? const ValueKey('active-tab-indicator') : null,
                duration: const Duration(milliseconds: 180),
                width: selected ? 22 : 0,
                height: 2,
                color: selected ? AppColors.accent : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
