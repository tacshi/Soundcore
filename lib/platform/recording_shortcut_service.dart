import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Consumes the iOS App Intent action after Flutter is ready.
///
/// The native side keeps the action persisted until this service consumes it,
/// so an intent delivered during a cold launch cannot be lost between native
/// app startup and Dart method-channel registration.
class RecordingShortcutService {
  RecordingShortcutService({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.capyvibe.soundcore/recording_shortcut');

  static final instance = RecordingShortcutService();

  final MethodChannel _channel;
  Future<void> Function()? _onStartRecording;
  bool _consuming = false;
  bool _consumeAgain = false;

  Future<void> initialize({
    required Future<void> Function() onStartRecording,
  }) async {
    if (!Platform.isIOS) return;
    _onStartRecording = onStartRecording;
    _channel.setMethodCallHandler(_handleNativeCall);
    await _consumePendingAction();
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'pendingStartRecording') {
      await _consumePendingAction();
    }
    return null;
  }

  Future<void> _consumePendingAction() async {
    if (_consuming) {
      _consumeAgain = true;
      return;
    }
    _consuming = true;
    try {
      do {
        _consumeAgain = false;
        try {
          final pending =
              await _channel.invokeMethod<bool>(
                'consumePendingStartRecording',
              ) ??
              false;
          if (pending) await _onStartRecording?.call();
        } on MissingPluginException catch (error) {
          debugPrint('[RecordingShortcut] Native bridge unavailable: $error');
          return;
        } on PlatformException catch (error) {
          debugPrint('[RecordingShortcut] Could not consume action: $error');
          return;
        }
      } while (_consumeAgain);
    } finally {
      _consuming = false;
    }
  }
}
