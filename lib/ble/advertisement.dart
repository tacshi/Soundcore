import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/models.dart';
import 'uuids.dart';

/// Parse BLE advertisements similar to Feishu / Anker `BlueDeviceModelHelper`.
///
/// macOS often omits local names and sometimes delays/omits service UUIDs in
/// the first advertisement packet — matching is intentionally lenient.
class AdvertisementParser {
  AdvertisementParser._();

  /// Always build a [ScannedDevice] for UI/debug (even non-soundcore).
  static ScannedDevice fromAny(ScanResult r) {
    final soundcore = tryParse(r);
    if (soundcore != null) return soundcore;

    final adv = r.advertisementData;
    final name = _bestName(r);
    return ScannedDevice(
      id: r.device.remoteId.str,
      name: name.isNotEmpty ? name : '未知 BLE 设备',
      rssi: r.rssi,
      advName: adv.advName.isNotEmpty ? adv.advName : null,
      serviceUuid: adv.serviceUuids.isNotEmpty
          ? adv.serviceUuids.first.str128
          : null,
      isD3200: false,
    );
  }

  /// Soundcore Work / family only. Null if not a match.
  static ScannedDevice? tryParse(ScanResult r) {
    final adv = r.advertisementData;
    final serviceUuids = <Guid>[...adv.serviceUuids, ...adv.serviceData.keys];

    final name = _bestName(r);
    final nameHint = _nameLooksLikeSoundcore(name);

    // --- identity signals ---
    final isD3200 =
        serviceUuids.any(AnkerUuids.isD3200Service) ||
        serviceUuids.any((g) => _guidLooksD3200(g)) ||
        adv.serviceData.keys.any(AnkerUuids.isD3200Service);

    var isSoundcoreFamily = isD3200 || nameHint;
    for (final g in serviceUuids) {
      final pre = _preUuid(g);
      if (pre.endsWith('F5DA') ||
          pre.contains('F5DA') ||
          pre.contains('020CF5DA')) {
        isSoundcoreFamily = true;
        break;
      }
      if (_guidLooksD3200(g)) {
        isSoundcoreFamily = true;
        break;
      }
    }

    // Manufacturer raw bytes may embed "soundc" or F5DA-ish patterns.
    String? macFromMfg;
    String? productMark;
    String deviceColor = '0';
    bool boundFlag = false;
    String channelId = '0';

    for (final combined in adv.msd) {
      if (combined.length >= 6) {
        macFromMfg ??= _bytesToMac(combined, 0);
      }
      if (combined.length > 6) {
        final flags = combined[6] & 0xFF;
        deviceColor = (flags & 0x70) == 0x10 ? '1' : '0';
        boundFlag = (flags & 0x80) != 0;
        channelId = (flags & 0x0F).toString();
      }
      if (combined.length >= 14) {
        final mark = String.fromCharCodes(
          combined.sublist(8, 14).map((b) => b & 0x7F),
        );
        productMark = mark;
        final m = mark.toLowerCase();
        if (m.contains('sound') || m.contains('scor') || m == 'soundc') {
          isSoundcoreFamily = true;
        }
      }
      // Heuristic: scan whole msd hex for f5da / 020c
      final hex = combined
          .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0'))
          .join();
      if (hex.contains('f5da') || hex.contains('020cf5')) {
        isSoundcoreFamily = true;
      }
    }

    if (!isSoundcoreFamily && !isD3200) {
      return null;
    }

    final productCode = isD3200 || name.toLowerCase().contains('work')
        ? 'D3200'
        : 'SOUNDCORE';

    String? serviceUuid;
    for (final g in serviceUuids) {
      if (AnkerUuids.isD3200Service(g) || _guidLooksD3200(g)) {
        serviceUuid = g.str128;
        break;
      }
    }
    serviceUuid ??= serviceUuids.isNotEmpty ? serviceUuids.first.str128 : null;

    return ScannedDevice(
      id: r.device.remoteId.str,
      name: _friendlyName(
        localName: name.isNotEmpty ? name : null,
        productCode: productCode,
        mac: macFromMfg,
      ),
      rssi: r.rssi,
      advName: adv.advName.isNotEmpty ? adv.advName : null,
      productCode: productCode,
      serviceUuid: serviceUuid,
      macAddress: macFromMfg,
      deviceColor: deviceColor,
      channelId: channelId,
      isBoundAdvertised: boundFlag,
      isD3200: productCode == 'D3200',
      manufacturerMark: productMark,
    );
  }

  /// Compact log line for diagnostics.
  static String debugSummary(ScanResult r) {
    final adv = r.advertisementData;
    final su = adv.serviceUuids.map((g) => g.str128).join(',');
    final sd = adv.serviceData.keys.map((g) => g.str128).join(',');
    final mfg = adv.manufacturerData.entries
        .map(
          (e) =>
              '0x${e.key.toRadixString(16)}:${e.value.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join()}',
        )
        .join('|');
    final name = _bestName(r);
    return 'rssi=${r.rssi} name="$name" connectable=${adv.connectable} '
        'svc=[$su] svcData=[$sd] mfg=[$mfg] id=${r.device.remoteId.str}';
  }

  static String _bestName(ScanResult r) {
    final adv = r.advertisementData.advName.trim();
    if (adv.isNotEmpty) return adv;
    final p = r.device.platformName.trim();
    if (p.isNotEmpty) return p;
    return '';
  }

  static bool _nameLooksLikeSoundcore(String name) {
    final n = name.toLowerCase();
    return n.contains('soundcore') ||
        n.contains('soundcor') ||
        n.contains('d3200') ||
        n.contains('work') && n.contains('sound') ||
        n.contains('录音') ||
        n.contains('anker') && n.contains('record');
  }

  static bool _guidLooksD3200(Guid g) {
    final s = g.str128.toLowerCase().replaceAll('-', '');
    // full 020cf5da… or short forms / byte-reversed appearances
    return s.contains('020cf5da') ||
        s.contains('daf50c02') ||
        s == 'f5da' ||
        s.endsWith('f5da') ||
        (s.length >= 8 && s.substring(0, 8) == '020cf5da');
  }

  static String _preUuid(Guid g) {
    final head = g.str128.split('-').first.toUpperCase();
    if (head.startsWith('DAF5')) {
      return _reverseHexPairs(head);
    }
    return head;
  }

  static String _reverseHexPairs(String hex) {
    final buf = StringBuffer();
    for (var i = hex.length - 1; i > 0; i -= 2) {
      buf.write(hex[i - 1]);
      buf.write(hex[i]);
    }
    return buf.toString().toUpperCase();
  }

  static String _bytesToMac(List<int> bytes, int start) {
    if (bytes.length < start + 6) return '';
    return List.generate(6, (i) {
      return (bytes[start + i] & 0xFF)
          .toRadixString(16)
          .padLeft(2, '0')
          .toUpperCase();
    }).join(':');
  }

  static String _friendlyName({
    required String? localName,
    required String productCode,
    required String? mac,
  }) {
    if (localName != null && localName.isNotEmpty) {
      final lower = localName.toLowerCase();
      if (lower.contains('soundcore') ||
          lower.contains('work') ||
          lower.contains('d3200')) {
        return localName;
      }
      return 'soundcore Work ($localName)';
    }
    if (productCode == 'D3200') {
      if (mac != null && mac.isNotEmpty) {
        final compact = mac.replaceAll(':', '');
        final short = compact.substring(compact.length - 4);
        return 'soundcore Work · $short';
      }
      return 'soundcore Work';
    }
    if (mac != null && mac.isNotEmpty) {
      return 'soundcore · ${mac.split(':').take(3).join(':')}…';
    }
    return 'soundcore device';
  }
}
