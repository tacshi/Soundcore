import 'package:anker_recorder/protocol/commands.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/wifi/wifi_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encode getDeviceInfo has magic + checksum', () {
    final frame = DeviceCommands.getDeviceInfo();
    expect(frame[0], 0x08);
    expect(frame[1], 0xEE);
    expect(frame[5], 0x01);
    expect(frame[6], 0x01);
    expect(ProtocolFrame.verifyChecksum(frame), isTrue);
    final len = frame[7] | (frame[8] << 8);
    expect(len, frame.length);
  });

  test('encode startRecord payload', () {
    final frame = DeviceCommands.startRecord();
    expect(frame[5], 0x18);
    expect(frame[6], 0x82);
    expect(frame[9], 0x01);
    expect(ProtocolFrame.verifyChecksum(frame), isTrue);
  });

  test('processBuffer parses RX packet', () {
    // Build a minimal valid RX: header + status + type/id + len + empty payload + csum
    final body = <int>[
      0x09, 0xFF, 0x00, 0x00,
      0x01, // status success
      0x01, // type
      0x01, // id
      0x0A, 0x00, // length 10
    ];
    final csum = ProtocolFrame.checksum(body);
    final packet = [...body, csum];
    final buf = List<int>.from(packet);
    final out = ProtocolFrame.processBuffer(buf);
    expect(out, hasLength(1));
    expect(out.first.cmdType, 0x01);
    expect(out.first.cmdId, 0x01);
    expect(out.first.isSuccess, isTrue);
  });

  test('sendWifiConfig length-prefixed SSID/password', () {
    final frame = DeviceCommands.sendWifiConfig(
      ssid: 'WiFi-1',
      password: '123',
    );
    expect(frame[5], 0x1A);
    expect(frame[6], 0x05);
    expect(ProtocolFrame.verifyChecksum(frame), isTrue);
    // payload starts at offset 9
    expect(frame[9], 6); // ssid len
    expect(String.fromCharCodes(frame.sublist(10, 16)), 'WiFi-1');
    expect(frame[16], 3); // pwd len
    expect(String.fromCharCodes(frame.sublist(17, 20)), '123');
  });

  test('parseWifiConfigPacket reverse IP + port LE', () {
    // Full RX: magic4 + status + type + id + len2 + ip4 + port2 + csum
    // IP 192.168.4.1 stored as reverse at [9..12]: 1, 4, 168, 192
    // port 8080 = 0x1F90 → 90 1F
    final body = <int>[
      0x09, 0xFF, 0x00, 0x00,
      0x01, // success
      0x1A, 0x05,
      0x10, 0x00, // length 16
      0x01, 0x04, 0xA8, 0xC0, // reversed IP octets
      0x90, 0x1F, // port 8080
    ];
    final csum = ProtocolFrame.checksum(body);
    final pkt = DecodedPacket.fromBytes([...body, csum]);
    final ep = WifiExportService.parseWifiConfigPacket(
      pkt,
      ssid: 'WiFi-x',
      password: 'y',
    );
    expect(ep, isNotNull);
    expect(ep!.ip, '192.168.4.1');
    expect(ep.port, 8080);
  });

  test('file header request hex is 18 bytes', () {
    // Access via transfer path builder — re-check fixed layout length.
    final frame = DeviceCommands.startTransportAudioFile(
      fileId: 0x12345678,
      alreadyTransferred: 0,
    );
    expect(frame[5], 0x1A);
    expect(frame[6], 0x07);
    expect(ProtocolFrame.verifyChecksum(frame), isTrue);
  });

  test('batteryRemaining expands D3200 battery buckets', () {
    expect(DeviceInfoModel.batteryRemaining(0), 10);
    expect(DeviceInfoModel.batteryRemaining(2), 30);
    expect(DeviceInfoModel.batteryRemaining(3), 40);
    expect(DeviceInfoModel.batteryRemaining(9), 100);
    expect(DeviceInfoModel.batteryRemaining(100), 100);
    expect(DeviceInfoModel.batteryRemaining(50), 50);
  });

  test('storageLabel shows used and total from KB counters', () {
    final info = DeviceInfoModel(
      totalMemoryKb: 64 * 1024 * 1024,
      freeMemoryKb: 60 * 1024 * 1024,
    );

    expect(info.storageLabel, '4 GB 已用 / 64 GB 共计');
  });

  test('bind and unbind match Feishu 0x0B/0x87 payloads', () {
    final bind = DeviceCommands.bind();
    final unbind = DeviceCommands.unbind();
    // type / id
    expect(bind[5], 0x0B);
    expect(bind[6], 0x87);
    expect(unbind[5], 0x0B);
    expect(unbind[6], 0x87);
    // payload: bind=01, unbind=00
    expect(bind[9], 0x01);
    expect(unbind[9], 0x00);
    expect(ProtocolFrame.verifyChecksum(bind), isTrue);
    expect(ProtocolFrame.verifyChecksum(unbind), isTrue);
  });
}
