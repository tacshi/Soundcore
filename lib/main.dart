import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'state/recorder_controller.dart';
import 'platform/recording_shortcut_service.dart';
import 'theme/app_theme.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    try {
      // Must be set before RecorderController creates BleService. This lets
      // Core Bluetooth restore active connections after background eviction.
      await FlutterBluePlus.setOptions(restoreState: true);
    } catch (error) {
      debugPrint('[BLE] State restoration setup failed: $error');
    }
  }
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  final controller = RecorderController();
  runApp(SoundcoreManagerApp(controller: controller));
  unawaited(
    RecordingShortcutService.instance.initialize(
      onStartRecording: controller.requestRecordingFromShortcut,
    ),
  );
}

class SoundcoreManagerApp extends StatelessWidget {
  const SoundcoreManagerApp({super.key, this.controller});

  final RecorderController? controller;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: '安克录音豆',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const AppShell(),
    );
    final controller = this.controller;
    if (controller != null) {
      return ChangeNotifierProvider.value(value: controller, child: app);
    }
    return ChangeNotifierProvider(
      create: (_) => RecorderController(),
      child: app,
    );
  }
}
