import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the Android process eligible to finish an active recorder sync after
/// the UI moves to the background. Apple platforms use Core Bluetooth's
/// background mode and state restoration instead.
class BackgroundSyncService {
  static const _channel = MethodChannel(
    'com.anker.anker_recorder/background_sync',
  );

  static bool _running = false;

  static Future<void> start() async {
    if (!Platform.isAndroid || _running) return;
    try {
      await _channel.invokeMethod<void>('start');
      _running = true;
    } on PlatformException catch (error) {
      debugPrint('[BackgroundSync] Could not start: $error');
    } on MissingPluginException catch (error) {
      debugPrint('[BackgroundSync] Native bridge unavailable: $error');
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      debugPrint('[BackgroundSync] Could not stop: $error');
    } on MissingPluginException catch (error) {
      debugPrint('[BackgroundSync] Native bridge unavailable: $error');
    } finally {
      _running = false;
    }
  }
}
