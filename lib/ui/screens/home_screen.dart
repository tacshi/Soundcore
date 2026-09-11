import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/scan_sheet.dart';
import '../widgets/widgets.dart';
import 'files_screen.dart';

/// A stable recording library; live and saved reading happens in detail routes.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loadedFiles = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFiles) return;
    _loadedFiles = true;
    final c = context.read<RecorderController>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.refreshFilesOnTabEnter();
    });
  }

  @override
  Widget build(BuildContext context) {
    return GradientScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConnectionHeader(onScan: () => showScanDevicesSheet(context)),
          const Expanded(
            child: FilesBody(
              key: ValueKey('files'),
              padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionHeader extends StatelessWidget {
  const _ConnectionHeader({required this.onScan});

  final VoidCallback onScan;

  /// Prefer real connection/STT status; never keep a stale "正在播放" line.
  static String _idleStatus(RecorderController c) {
    final m = c.statusMessage;
    if (m == null || m.isEmpty) return '已连接';
    if (m.startsWith('正在播放') || m.startsWith('正在准备播放')) {
      return '已连接';
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final online = c.connected;
    final live = c.isLiveSession;
    final name = c.displayDeviceName;

    return Container(
      color: AppColors.bgCard,
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        20,
        16,
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: (online ? AppColors.mint : AppColors.accent).withValues(
                alpha: 0.12,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: online
                ? Image.asset(
                    'assets/product/d3200_device_white.webp',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.headphones_rounded,
                      color: AppColors.mint,
                    ),
                  )
                : const Icon(Icons.link_off_rounded, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? name : (c.displayDevice != null ? name : '未连接设备'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!live) ...[
                  const SizedBox(height: 2),
                  Text(
                    online
                        ? (c.isPlaying
                              ? (c.statusMessage?.startsWith('正在播放') == true
                                    ? c.statusMessage!
                                    : '正在播放')
                              : _idleStatus(c))
                        : '点「扫描」查找 soundcore Work',
                    style: TextStyle(
                      fontSize: 12,
                      color: c.isPlaying
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (!online)
            IconButton(
              tooltip: '扫描',
              onPressed: onScan,
              style: IconButton.styleFrom(
                foregroundColor: AppColors.accent,
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(Icons.radar_rounded, size: 44),
            ),
        ],
      ),
    );
  }
}
