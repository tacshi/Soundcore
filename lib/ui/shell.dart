import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/stt_types.dart';
import '../state/recorder_controller.dart';
import '../theme/app_theme.dart';
import 'recording_navigation.dart';
import 'screens/device_screen.dart';
import 'screens/communication_screen.dart';
import 'screens/home_screen.dart';
import 'screens/recording_detail_screen.dart';
import 'screens/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _routes = _RecordingRouteObserver(_routeChanged);
  int _index = 0;
  int _handledLiveRevision = 0;
  int _handledShortcutRevision = 0;

  void _routeChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  bool _sameRecording(RecordingReference? left, RecordingReference? right) {
    if (left == null || right == null) return false;
    if (left.key == right.key) return true;
    final controller = context.read<RecorderController>();
    final leftData = controller.recordingView(left);
    final rightData = controller.recordingView(right);
    return leftData.reference.key == rightData.reference.key ||
        leftData.reference.fileId != null &&
            leftData.reference.fileId == rightData.reference.fileId ||
        leftData.path != null && leftData.path == rightData.path;
  }

  void _openRecording(RecordingReference reference) {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    if (_sameRecording(_routes.visibleReference, reference)) return;
    final existing = _routes.routes
        .where(
          (route) =>
              route.settings.arguments is RecordingReference &&
              _sameRecording(
                route.settings.arguments as RecordingReference,
                reference,
              ),
        )
        .firstOrNull;
    if (existing != null) {
      navigator.popUntil((route) => route == existing);
      return;
    }
    final controller = context.read<RecorderController>();
    final data = controller.recordingView(reference);
    navigator.push(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name: 'recording/${reference.key}',
          arguments: reference,
        ),
        builder: (_) => data.mode == SttDisplayMode.conversation && data.live
            ? CommunicationScreen(reference: reference)
            : RecordingDetailScreen(reference: reference),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final current = c.currentRecordingReference;
    final newLive = c.liveSessionRevision != _handledLiveRevision;
    final shortcut = c.shortcutNavigationRevision != _handledShortcutRevision;
    if (newLive || shortcut) {
      _handledLiveRevision = c.liveSessionRevision;
      _handledShortcutRevision = c.shortcutNavigationRevision;
      if (current != null && (newLive || c.isLiveSession)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openRecording(current);
        });
      } else if (shortcut) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _navigator.currentState?.popUntil((route) => route.isFirst);
          setState(() => _index = 0);
        });
      }
    }
    final visible = _routes.visibleReference;
    final showRecording =
        current != null && c.isLiveSession && !_sameRecording(current, visible);
    final playing = c.playingPath;
    final showPlayer =
        c.hasLoadedTrack &&
        playing != null &&
        (visible == null || c.recordingView(visible).path != playing);
    final detailVisible = _routes.routes.length > 1;

    return RecordingNavigation(
      onOpen: _openRecording,
      tabIndex: _index,
      child: PopScope(
        canPop: !detailVisible,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _navigator.currentState?.maybePop();
        },
        child: Scaffold(
          body: Navigator(
            key: _navigator,
            observers: [_routes],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'library'),
              builder: (_) => const _ShellPages(),
            ),
          ),
          // A non-null empty bar still removes the bottom MediaQuery padding
          // from the nested route. Let detail pages own their safe area when
          // there are no shared controls below them.
          bottomNavigationBar: detailVisible && !showRecording && !showPlayer
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showRecording)
                      _ActiveRecordingBar(
                        onOpen: () => _openRecording(current),
                      ),
                    if (showPlayer)
                      _CompactPlayer(
                        onOpen: () => _openRecording(
                          RecordingReference(
                            fileId: c.fileIdFromPath(playing),
                            path: playing,
                          ),
                        ),
                      ),
                    if (!detailVisible)
                      _NavBar(
                        index: _index,
                        onSelect: (index) {
                          setState(() => _index = index);
                          if (index == 0) c.refreshFilesOnTabEnter();
                          if (index == 1) c.refreshInfoOnDeviceTabEnter();
                        },
                      ),
                    if (detailVisible && (showPlayer || showRecording))
                      SizedBox(height: MediaQuery.paddingOf(context).bottom),
                  ],
                ),
        ),
      ),
    );
  }
}

// The shell route reads the inherited index because Navigator retains its route
// builder while tabs change. IndexedStack keeps each page and scroll position.
class _ShellPages extends StatelessWidget {
  const _ShellPages();
  @override
  Widget build(BuildContext context) {
    final navigation = context
        .dependOnInheritedWidgetOfExactType<RecordingNavigation>()!;
    return IndexedStack(
      index: navigation.tabIndex,
      children: const [HomeScreen(), DeviceScreen(), SettingsScreen()],
    );
  }
}

class _RecordingRouteObserver extends NavigatorObserver {
  _RecordingRouteObserver(this.changed);
  final VoidCallback changed;
  final List<Route<dynamic>> routes = [];
  RecordingReference? get visibleReference {
    final value = routes.lastOrNull?.settings.arguments;
    return value is RecordingReference ? value : null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      routes.add(route);
      changed();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        routes.removeAt(index);
      } else {
        routes[index] = newRoute;
      }
    }
    changed();
  }
}

class _ActiveRecordingBar extends StatelessWidget {
  const _ActiveRecordingBar({required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    return Material(
      color: AppColors.bgCard,
      child: Container(
        key: const ValueKey('active-recording-bar'),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: onOpen,
                icon: Icon(
                  Icons.mic_rounded,
                  color: c.recording ? AppColors.coral : AppColors.textMuted,
                ),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(c.recording ? '录音中 · 打开' : '录音已暂停 · 打开'),
                ),
              ),
            ),
            if (c.recording)
              IconButton(
                tooltip: '暂停录音',
                onPressed: c.phase == AppPhase.busy ? null : c.pauseRecord,
                icon: const Icon(Icons.pause_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _CompactPlayer extends StatelessWidget {
  const _CompactPlayer({required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final path = c.playingPath;
    final title = path == null
        ? '录音'
        : c
              .recordingView(
                RecordingReference(fileId: c.fileIdFromPath(path), path: path),
              )
              .title;
    return Material(
      color: AppColors.bgCard,
      child: Container(
        key: const ValueKey('compact-player'),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: c.isPlaying ? '暂停播放' : '继续播放',
              onPressed: c.togglePlayPause,
              icon: Icon(
                c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            IconButton(
              tooltip: '关闭播放器',
              onPressed: c.stopPlayback,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
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
    final color = selected ? AppColors.accent : AppColors.textSecondary;
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
