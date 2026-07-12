import 'dart:typed_data';

import 'package:anker_recorder/ota/ota_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CRC32 matches standard vector', () {
    expect(D3200OtaProtocol.crc32('123456789'.codeUnits), 0xCBF43926);
  });

  test('builds BES OTA setup commands', () {
    expect(
      D3200OtaProtocol.protocolVersion(),
      Uint8List.fromList([
        0x99,
        0x04,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
      ]),
    );
    expect(
      D3200OtaProtocol.hardwareInfo(),
      Uint8List.fromList([
        0x8E,
        0x04,
        0x00,
        0x00,
        0x00,
        0x42,
        0x45,
        0x53,
        0x54,
      ]),
    );
  });

  test('data packet length is little endian', () {
    final payload = Uint8List.fromList(List<int>.generate(260, (i) => i));
    final packet = D3200OtaProtocol.data(payload);

    expect(packet.sublist(0, 5), [0x85, 0x04, 0x01, 0x00, 0x00]);
    expect(packet.sublist(5), payload);
  });

  test('configure packet includes image offset and block CRC', () {
    final firmware = Uint8List.fromList([
      ...List<int>.filled(20, 0xA5),
      0x11,
      0x22,
      0x33,
      0x44,
    ]);
    final packet = D3200OtaProtocol.configure(firmware);
    final body = packet.sublist(5);

    expect(packet.length, 97);
    expect(packet.sublist(0, 5), [0x86, 92, 0, 0, 0]);
    expect(body.sublist(0, 4), [88, 0, 0, 0]);
    expect(body.sublist(4, 8), [0x11, 0x22, 0x33, 0x00]);
    final crc =
        body[88] | (body[89] << 8) | (body[90] << 16) | (body[91] << 24);
    expect(crc, D3200OtaProtocol.crc32(body.sublist(0, 88)));
  });
}
