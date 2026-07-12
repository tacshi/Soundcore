import 'dart:typed_data';

/// BES OTA commands used by the D3200 firmware updater.
///
/// This mirrors `BesOtaProtocol` / `OtaEventSendManager` from the bundled
/// soundcore SDK. OTA characteristic packets are raw BES messages, not normal
/// `08 EE` application frames.
class D3200OtaProtocol {
  D3200OtaProtocol._();

  static const magic = <int>[0x42, 0x45, 0x53, 0x54]; // "BEST"
  static const segmentSize = 32 * 1024;

  static Uint8List protocolVersion() =>
      _packet(0x99, const [0x00, 0x00, 0x00, 0x01]);

  static Uint8List setOtaUser() => _packet(0x97, const [0x01]);

  static Uint8List hardwareInfo() => _packet(0x8E, magic);

  static Uint8List setUpgradeType() => _packet(0x9D, const [0x02]);

  static Uint8List roleSwitchRandomId() => _packet(0x9B);

  static Uint8List selectSide() => _packet(0x90, const [0x00]);

  static Uint8List checkBreakpoint() {
    final body = Uint8List(32 + 4);
    body.setRange(32, 36, const [1, 2, 3, 4]);
    return _packet(0x8C, [...magic, ...body, ...u32Le(crc32(body))]);
  }

  static Uint8List start({required int firmwareSize, required int crc}) =>
      _packet(0x80, [...magic, ...u32Le(firmwareSize), ...u32Le(crc)]);

  /// The 92-byte BES configuration block. The first three bytes of the final
  /// four firmware bytes are copied into the image-offset field by the SDK.
  static Uint8List configure(Uint8List firmware) {
    if (firmware.length < 4) {
      throw ArgumentError.value(firmware.length, 'firmware', 'too short');
    }
    final body = Uint8List(92);
    body.setRange(0, 4, u32Le(88));
    body.setRange(
      4,
      7,
      firmware.sublist(firmware.length - 4, firmware.length - 1),
    );
    body.setRange(88, 92, u32Le(crc32(Uint8List.sublistView(body, 0, 88))));
    return _packet(0x86, body);
  }

  static Uint8List data(Uint8List bytes) => _packet(0x85, bytes);

  static Uint8List segmentCrc(Uint8List bytes) =>
      _packet(0x82, [...magic, ...u32Le(crc32(bytes))]);

  static Uint8List wholeCrc() => _packet(0x88);

  static Uint8List applyImage() => _packet(0x92, magic);

  static Uint8List _packet(int command, [List<int> payload = const []]) =>
      Uint8List.fromList([
        command & 0xFF,
        ...u32Le(payload.length),
        ...payload,
      ]);

  static Uint8List u32Le(int value) => Uint8List.fromList([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);

  /// Standard reflected CRC-32 (polynomial 0xEDB88320), matching the SDK.
  static int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final value in data) {
      crc ^= value & 0xFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
