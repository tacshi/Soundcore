import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// GATT / advertisement identifiers from PROTOCOL.md + BlueDeviceModelHelper.
class AnkerUuids {
  AnkerUuids._();

  /// Advertised primary service for soundcore Work (D3200).
  /// Feishu: `getProductCodeByDevice` matches this → "D3200".
  static final d3200Service = Guid('020cf5da-0000-1000-8000-00805f9b34fb');

  static final write = Guid('00007777-0000-1000-8000-00805F9B34FB');
  static final readNotify = Guid('00008888-0000-1000-8000-00805F9B34FB');
  static final cccd = Guid('00002902-0000-1000-8000-00805f9b34fb');

  static bool isD3200Service(Guid g) {
    final s = g.str128.toLowerCase().replaceAll('-', '');
    return s.contains('020cf5da') ||
        g == d3200Service ||
        g.str128.toLowerCase() == d3200Service.str128.toLowerCase();
  }

  /// Short-form matches flutter_blue sometimes reports.
  static bool isWrite(Guid g) =>
      g == write || g.str128.toUpperCase().contains('00007777');

  static bool isRead(Guid g) =>
      g == readNotify || g.str128.toUpperCase().contains('00008888');
}
