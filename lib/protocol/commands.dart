import 'dart:convert';
import 'dart:typed_data';

import 'frame.dart';

/// High-level command builders (PROTOCOL.md §5).
class DeviceCommands {
  DeviceCommands._();

  // ── Device info (type 0x01) ──────────────────────────────────────────
  static Uint8List getDeviceInfo() =>
      ProtocolFrame.encode(cmdType: 0x01, cmdId: 0x01);

  static Uint8List resetDevice() =>
      ProtocolFrame.encode(cmdType: 0x01, cmdId: 0xB8);

  /// UTC unix seconds + timezone offset byte (hours, signed).
  static Uint8List syncTime({DateTime? when, int? timezoneHours}) {
    final t = when ?? DateTime.now();
    final tz = timezoneHours ?? t.timeZoneOffset.inHours;
    final payload = BytesBuilder(copy: false)
      ..add(u32Le(t.millisecondsSinceEpoch ~/ 1000))
      ..addByte(tz & 0xFF);
    return ProtocolFrame.encode(
      cmdType: 0x01,
      cmdId: 0xA6,
      payload: payload.toBytes(),
    );
  }

  // ── Audio control (type 0x18 id 0x82) ────────────────────────────────
  static Uint8List startRecord() =>
      ProtocolFrame.encode(cmdType: 0x18, cmdId: 0x82, payload: const [0x01]);

  static Uint8List pauseRecord() =>
      ProtocolFrame.encode(cmdType: 0x18, cmdId: 0x82, payload: const [0x02]);

  // ── File transport (type 0x1A) ───────────────────────────────────────
  static Uint8List listFiles({int page = 0}) =>
      ProtocolFrame.encode(cmdType: 0x1A, cmdId: 0x0E, payload: u16Le(page));

  static Uint8List listFilesWithEndTime({int page = 0}) =>
      ProtocolFrame.encode(cmdType: 0x1B, cmdId: 0x0E, payload: u16Le(page));

  static Uint8List deleteFile(int fileId) =>
      ProtocolFrame.encode(cmdType: 0x1A, cmdId: 0x10, payload: u32Le(fileId));

  static Uint8List startBtTransport({bool isIos = false}) =>
      ProtocolFrame.encode(
        cmdType: 0x1A,
        cmdId: 0x0F,
        payload: [isIos ? 0x01 : 0x00],
      );

  static Uint8List stopBtTransport({bool isIos = false}) =>
      ProtocolFrame.encode(
        cmdType: 0x1A,
        cmdId: 0x11,
        payload: [isIos ? 0x01 : 0x00],
      );

  static Uint8List startTransportAudioFile({
    required int fileId,
    int alreadyTransferred = 0,
    int realtimeFlag = 0,
  }) {
    final payload = BytesBuilder(copy: false)
      ..add(u32Le(alreadyTransferred))
      ..add(u32Le(fileId))
      ..addByte(realtimeFlag & 0xFF);
    return ProtocolFrame.encode(
      cmdType: 0x1A,
      cmdId: 0x07,
      payload: payload.toBytes(),
    );
  }

  /// SoftAP credentials: `[ssid_len][ssid][pwd_len][pwd]` via BLE (type 0x1A id 0x05).
  /// Device opens hotspot with these credentials and replies with IP:port.
  static Uint8List sendWifiConfig({
    required String ssid,
    required String password,
  }) {
    final ssidBytes = utf8.encode(ssid);
    final pwdBytes = utf8.encode(password);
    final payload = BytesBuilder(copy: false)
      ..addByte(ssidBytes.length & 0xFF)
      ..add(ssidBytes)
      ..addByte(pwdBytes.length & 0xFF)
      ..add(pwdBytes);
    return ProtocolFrame.encode(
      cmdType: 0x1A,
      cmdId: 0x05,
      payload: payload.toBytes(),
    );
  }

  /// Close Wi‑Fi SoftAP / transfer mode (type 0x1A id 0x02).
  static Uint8List closeWifiMode() =>
      ProtocolFrame.encode(cmdType: 0x1A, cmdId: 0x02);

  // ── Encrypt (type 0x2E) ──────────────────────────────────────────────
  /// Notify device of app ECDH public key (hex→bytes of uncompressed P-256).
  static Uint8List notifyEncryptPublicKey(List<int> publicKeyBytes) =>
      ProtocolFrame.encode(cmdType: 0x2E, cmdId: 0x01, payload: publicKeyBytes);

  // ── Binding (type 0x0B) ──────────────────────────────────────────────
  /// Feishu/Anker SDK sends `01` to bind and `00` to unbind. Unbind always
  /// uses the stock one-byte payload so recordings remain on the device.
  ///
  /// The optional bind byte is retained for experimental post-bind prompts.
  static Uint8List bind({bool broadcastTone = false}) {
    final payload = <int>[0x01];
    if (broadcastTone) payload.add(0x01);
    return ProtocolFrame.encode(
      cmdType: 0x0B,
      cmdId: 0x87,
      payload: payload,
    );
  }

  static Uint8List unbind() => ProtocolFrame.encode(
    cmdType: 0x0B,
    cmdId: 0x87,
    payload: const [0x00],
  );

  /// Raw multi-byte bind/unbind for ad-hoc probes (any payload after op).
  static Uint8List bindRaw(List<int> payload) => ProtocolFrame.encode(
        cmdType: 0x0B,
        cmdId: 0x87,
        payload: payload,
      );

  // ── More settings (type 0x10) ────────────────────────────────────────
  static Uint8List setFindMy(bool enable) => ProtocolFrame.encode(
    cmdType: 0x10,
    cmdId: 0xA2,
    payload: [enable ? 0x01 : 0x00],
  );
}

/// Known RX type/id pairs for dispatch.
class RxCmd {
  static const deviceInfoType = 0x01;
  static const deviceInfoId = 0x01;
  static const batteryId = 0x03;
  static const chargingId = 0x04;
  static const syncTimeId = 0xA6;
  static const resetId = 0xB8;

  static const audioType = 0x18;
  static const audioControlId = 0x82;

  static const transportType = 0x1A;
  static const transportTypeAlt = 0x1B;
  static const wifiCloseId = 0x02;
  static const wifiConfigId = 0x05;

  /// New file / transport status while recording (Feishu realtime).
  static const recordStatusId = 0x06;
  static const fileHeadId = 0x07;
  static const fileSliceId = 0x08;
  static const fileDoneId = 0x0A;
  static const fileListId = 0x0E;
  static const btStatusId = 0x0F;
  static const deleteId = 0x10;
  static const fileSliceMarkId = 0x12;

  static const bindType = 0x0B;
  static const bindResultId = 0x87;
  static const bindConfirmId = 0x88;

  static const encryptType = 0x2E;
  static const encryptHandshakeId = 0x01;
}
