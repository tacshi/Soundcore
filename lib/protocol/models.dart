import 'dart:convert';
import 'dart:typed_data';

import 'frame.dart';

class DeviceInfoModel {
  DeviceInfoModel({
    this.connectStatus,
    this.battery,
    this.charging = false,
    this.firmwareVersion = '',
    this.serialNumber = '',
    this.totalMemoryKb,
    this.freeMemoryKb,
    this.boxBattery,
    this.boxCharging = false,
    this.boxMac = '',
    this.boxFirmware = '',
    this.wifiFirmware = '',
    this.recording = false,
    this.rawHex = '',
  });

  final int? connectStatus;

  /// Mic / earbud battery 0–100 (PROTOCOL deviceBattery).
  final int? battery;
  final bool charging;
  final String firmwareVersion;
  final String serialNumber;
  final int? totalMemoryKb;
  final int? freeMemoryKb;

  /// Charge case battery 0–100.
  final int? boxBattery;
  final bool boxCharging;
  final String boxMac;
  final String boxFirmware;
  final String wifiFirmware;
  final bool recording;
  final String rawHex;

  bool get hasIdentity => serialNumber.isNotEmpty || firmwareVersion.isNotEmpty;

  /// Prefer mic battery; fall back to case if mic missing.
  int get displayBatteryPercent {
    final mic = _clampPct(battery);
    final box = _clampPct(boxBattery);
    if (mic != null) return mic;
    if (box != null) return box;
    return 0;
  }

  String get storageLabel {
    if (totalMemoryKb == null || freeMemoryKb == null) return '—';
    final total = totalMemoryKb!.clamp(0, 0xFFFFFFFF);
    final free = freeMemoryKb!.clamp(0, total);
    final used = total - free;
    return '${_formatStorageKb(used)} 已用 / ${_formatStorageKb(total)} 共计';
  }

  DeviceInfoModel copyWith({
    int? connectStatus,
    int? battery,
    bool? charging,
    String? firmwareVersion,
    String? serialNumber,
    int? totalMemoryKb,
    int? freeMemoryKb,
    int? boxBattery,
    bool? boxCharging,
    String? boxMac,
    String? boxFirmware,
    String? wifiFirmware,
    bool? recording,
    String? rawHex,
  }) {
    return DeviceInfoModel(
      connectStatus: connectStatus ?? this.connectStatus,
      battery: battery ?? this.battery,
      charging: charging ?? this.charging,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      serialNumber: serialNumber ?? this.serialNumber,
      totalMemoryKb: totalMemoryKb ?? this.totalMemoryKb,
      freeMemoryKb: freeMemoryKb ?? this.freeMemoryKb,
      boxBattery: boxBattery ?? this.boxBattery,
      boxCharging: boxCharging ?? this.boxCharging,
      boxMac: boxMac ?? this.boxMac,
      boxFirmware: boxFirmware ?? this.boxFirmware,
      wifiFirmware: wifiFirmware ?? this.wifiFirmware,
      recording: recording ?? this.recording,
      rawHex: rawHex ?? this.rawHex,
    );
  }

  /// Parse using Feishu absolute offsets on the **full** frame
  /// (`DeviceInfoDispatch.onParseDeviceInfo`, index starts at 9).
  factory DeviceInfoModel.parsePacket(Uint8List raw) {
    final hex = raw.toHex();
    if (raw.length < 20) {
      return DeviceInfoModel(rawHex: hex);
    }

    var o = 9;
    int u8() {
      if (o >= raw.length) throw RangeError('u8 @$o');
      return raw[o++] & 0xFF;
    }

    Uint8List take(int n) {
      final end = (o + n).clamp(0, raw.length);
      final s = raw.sublist(o, end);
      o = end;
      return s;
    }

    String ascii(Uint8List b) {
      final end = b.indexWhere((c) => c == 0);
      final slice = end < 0 ? b : b.sublist(0, end);
      return utf8.decode(slice, allowMalformed: true).trim();
    }

    try {
      final connectStatus = u8();
      final batteryRaw = u8();
      final battery = batteryRemaining(batteryRaw) ?? 0;
      final chargingStatus = u8();
      final fw = ascii(take(5));
      final sn = ascii(take(16)).toLowerCase();
      final totalMem = _readU32(raw, o);
      o += 4;
      final freeMem = _readU32(raw, o);
      o += 4;

      final boxChargingFlag = u8();
      final boxFw = ascii(take(5));
      final boxBatteryRaw = u8();
      final macBytes = take(6);
      final boxMac = _formatMac(macBytes);

      // Optional trailing fields (color, auto-off, lights, recording, wifi FW…)
      String wifiFw = '';
      var recording = false;
      if (o + 5 + 1 <= raw.length - 1) {
        u8(); // deviceColor
        u8(); // autoPowerOffSwitch
        u8(); // autoPowerOffIndex
        u8(); // pickupIndicatorLight
        u8(); // box indicator light
        if (o < raw.length - 1) {
          recording = u8() == 1;
        }
        if (o + 5 <= raw.length - 1) {
          wifiFw = ascii(take(5));
        }
      }

      return DeviceInfoModel(
        connectStatus: connectStatus,
        battery: battery,
        charging: chargingStatus == 1,
        firmwareVersion: fw,
        serialNumber: sn,
        totalMemoryKb: totalMem,
        freeMemoryKb: freeMem,
        boxBattery: batteryRemaining(boxBatteryRaw),
        boxCharging: boxChargingFlag == 1,
        boxMac: boxMac,
        boxFirmware: boxFw,
        wifiFirmware: wifiFw,
        recording: recording,
        rawHex: hex,
      );
    } catch (_) {
      // Fallback: early fields only (mic battery is first bytes of payload).
      return DeviceInfoModel.parsePayload(
        raw.length > 10 ? raw.sublist(9, raw.length - 1) : Uint8List(0),
        rawHex: hex,
      );
    }
  }

  /// Payload-only parse (tests / fallback). Payload starts at frame offset 9.
  factory DeviceInfoModel.parsePayload(
    Uint8List payload, {
    String rawHex = '',
  }) {
    if (payload.length < 3) {
      return DeviceInfoModel(rawHex: rawHex);
    }
    var o = 0;
    int u8() => payload[o++] & 0xFF;
    Uint8List take(int n) {
      final end = (o + n).clamp(0, payload.length);
      final s = payload.sublist(o, end);
      o = end;
      return s;
    }

    String ascii(Uint8List b) {
      final end = b.indexWhere((c) => c == 0);
      final slice = end < 0 ? b : b.sublist(0, end);
      return utf8.decode(slice, allowMalformed: true).trim();
    }

    final connectStatus = u8();
    final battery = batteryRemaining(u8()) ?? 0;
    final chargingStatus = u8();
    final fw = payload.length >= 8 ? ascii(take(5)) : '';
    final sn = payload.length >= 24 ? ascii(take(16)).toLowerCase() : '';

    int? totalMem;
    int? freeMem;
    var boxCharging = false;
    var boxFw = '';
    int? boxBattery;
    var boxMac = '';

    if (o + 8 <= payload.length) {
      totalMem = readU32Le(payload, o);
      o += 4;
      freeMem = readU32Le(payload, o);
      o += 4;
    }
    if (o < payload.length) boxCharging = u8() == 1;
    if (o + 5 <= payload.length) boxFw = ascii(take(5));
    if (o < payload.length) boxBattery = batteryRemaining(u8());
    if (o + 6 <= payload.length) boxMac = _formatMac(take(6));

    return DeviceInfoModel(
      connectStatus: connectStatus,
      battery: battery,
      charging: chargingStatus == 1,
      firmwareVersion: fw,
      serialNumber: sn,
      totalMemoryKb: totalMem,
      freeMemoryKb: freeMem,
      boxBattery: boxBattery,
      boxCharging: boxCharging,
      boxMac: boxMac,
      boxFirmware: boxFw,
      rawHex: rawHex,
    );
  }

  /// Backward-compatible name used by older call sites.
  factory DeviceInfoModel.parse(Uint8List payload) =>
      DeviceInfoModel.parsePayload(payload);

  static int _readU32(Uint8List raw, int o) {
    if (o + 4 > raw.length) return 0;
    return readU32Le(raw, o);
  }

  static int? _clampPct(int? v) {
    if (v == null) return null;
    if (v < 0) return 0;
    if (v > 100) {
      // Some firmwares set high bits; keep low 7 bits if that lands in range.
      final masked = v & 0x7F;
      if (masked <= 100) return masked;
      return 100;
    }
    return v;
  }

  /// Convert a raw battery byte to a display percentage.
  ///
  /// D3200 reports one of ten battery buckets: 0 means 10%, through 9 meaning
  /// 100%. This is also consistent with the reference SDK's low-battery checks
  /// (`< 3` / `< 4`). Preserve literal percentages from any firmware that
  /// reports values above the bucket range.
  static int? batteryRemaining(int? raw) {
    final clamped = _clampPct(raw);
    if (clamped == null) return null;
    if (clamped <= 9) return (clamped + 1) * 10;
    return clamped;
  }

  static String _formatMac(List<int> macBytes) {
    if (macBytes.length < 6) return '';
    // Reject obvious padding / garbage (e.g. 21:21:21:21:21:21).
    final allSame = macBytes.take(6).every((b) => b == macBytes[0]);
    final allZero = macBytes.take(6).every((b) => (b & 0xFF) == 0);
    if (allSame || allZero) return '';
    return macBytes
        .take(6)
        .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  /// DeviceInfoDispatch names both counters `*MemoryKB`; keep that unit when
  /// scaling. Treating a ~60 million KB capacity as bytes produced the old
  /// incorrect 58 MB total for a 64 GB device.
  static String _formatStorageKb(int value) {
    if (value <= 0) return '0 MB';
    if (value >= 1024 * 1024) {
      return '${_compactDecimal(value / (1024 * 1024))} GB';
    }
    if (value >= 1024) {
      return '${_compactDecimal(value / 1024)} MB';
    }
    return '$value KB';
  }

  static String _compactDecimal(num value) {
    final fixed = value.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }
}

class OfflineFileEntry {
  OfflineFileEntry({
    required this.fileId,
    required this.sizeBytes,
    this.endTime,
  });

  final int fileId;
  final int sizeBytes;
  final int? endTime;

  int get estimatedDurationMs =>
      sizeBytes > 0 ? ((sizeBytes / 20) * 166).round() : 0;

  DateTime? get fileIdAsDate {
    if (fileId > 1e9 && fileId < 2e10) {
      return DateTime.fromMillisecondsSinceEpoch(fileId * 1000);
    }
    return null;
  }

  String get title {
    final d = fileIdAsDate;
    if (d != null) {
      return '${d.year}-${_p(d.month)}-${_p(d.day)} ${_p(d.hour)}:${_p(d.minute)}';
    }
    return '文件 $fileId';
  }

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  static String _p(int n) => n.toString().padLeft(2, '0');
}

class OfflineFileList {
  OfflineFileList({
    required this.files,
    this.fileCount = 0,
    this.currentTransportTimestamp,
    this.currentTransportDuration,
  });

  final List<OfflineFileEntry> files;
  final int fileCount;
  final int? currentTransportTimestamp;
  final int? currentTransportDuration;

  factory OfflineFileList.parse(Uint8List payload, {bool withEndTime = false}) {
    if (payload.length < 2) {
      return OfflineFileList(files: const []);
    }

    final count = readU16Le(payload, 0);
    var o = 2;
    final files = <OfflineFileEntry>[];
    final entrySize = withEndTime ? 12 : 8;

    for (var i = 0; i < count; i++) {
      if (o + entrySize > payload.length) break;
      final fileId = readU32Le(payload, o);
      o += 4;
      int? endTime;
      if (withEndTime) {
        endTime = readU32Le(payload, o);
        o += 4;
      }
      final size = readU32Le(payload, o);
      o += 4;
      if (size > 0) {
        files.add(
          OfflineFileEntry(fileId: fileId, sizeBytes: size, endTime: endTime),
        );
      }
    }

    int? currTs;
    int? currDur;
    if (o + 8 <= payload.length) {
      currTs = readU32Le(payload, o);
      currDur = readU32Le(payload, o + 4);
    }

    return OfflineFileList(
      files: files,
      fileCount: count,
      currentTransportTimestamp: currTs,
      currentTransportDuration: currDur,
    );
  }
}

class ScannedDevice {
  ScannedDevice({
    required this.id,
    required this.name,
    required this.rssi,
    this.advName,
    this.productCode,
    this.serviceUuid,
    this.macAddress,
    this.deviceColor,
    this.channelId,
    this.isBoundAdvertised = false,
    this.isD3200 = false,
    this.manufacturerMark,
  });

  final String id;
  final String name;
  final int rssi;
  final String? advName;
  final String? productCode;
  final String? serviceUuid;
  final String? macAddress;
  final String? deviceColor;
  final String? channelId;
  final bool isBoundAdvertised;
  final bool isD3200;
  final String? manufacturerMark;

  String get displayName =>
      name.isNotEmpty ? name : (advName?.isNotEmpty == true ? advName! : id);

  String get subtitle {
    final parts = <String>[];
    if (productCode != null) parts.add(productCode!);
    if (macAddress != null && macAddress!.isNotEmpty) {
      parts.add(macAddress!);
    } else if (id.isNotEmpty) {
      parts.add(_shortId(id));
    }
    if (isBoundAdvertised) parts.add('已绑定');
    return parts.join(' · ');
  }

  bool get looksLikeSoundcore =>
      isD3200 ||
      productCode == 'D3200' ||
      productCode == 'SOUNDCORE' ||
      (serviceUuid?.toLowerCase().contains('020cf5da') ?? false) ||
      displayName.toLowerCase().contains('soundcore') ||
      displayName.toLowerCase().contains('work');

  static String _shortId(String id) {
    if (id.length <= 12) return id;
    if (id.contains('-') && id.length >= 36) {
      return '${id.substring(0, 8)}…${id.substring(id.length - 4)}';
    }
    return '${id.substring(0, 6)}…${id.substring(id.length - 4)}';
  }
}
