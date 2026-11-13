import 'dart:async';
import 'dart:io';

import 'package:anker_recorder/ble/realtime_stream.dart';
import 'package:anker_recorder/crypto/device_crypto.dart';
import 'package:anker_recorder/protocol/commands.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Builds an RX frame whose status byte reads success.
DecodedPacket _rx(int cmdType, int cmdId, List<int> payload) {
  final length = 10 + payload.length;
  final body = <int>[
    0x09, 0xFF, 0x00, 0x00, 0x01, //
    cmdType, cmdId, length & 0xFF, length >> 8,
    ...payload,
  ];
  return DecodedPacket.fromBytes([...body, ProtocolFrame.checksum(body)]);
}

File _export(int fileId) => File(
  p.join(Directory.systemTemp.path, 'AnkerRecorder', 'exports', '$fileId.opus'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a lone FF payload is a refusal even with a success status byte', () {
    // Captured from firmware 03.56: 09 FF 00 00 01 1B 0E 0B 00 FF 3C
    final refused = _rx(0x1B, 0x0E, const [0xFF]);
    expect(refused.raw.last, 0x3C);
    expect(refused.isRejected, isTrue);
    expect(refused.isSuccess, isFalse);

    final empty = _rx(0x0B, 0x87, const []);
    expect(empty.isRejected, isFalse);
    expect(empty.isSuccess, isTrue);

    final list = _rx(0x1B, 0x0E, const [0xFF, 0x00]);
    expect(list.isRejected, isFalse);
  });

  test('refused realtime request leaves no empty export', () async {
    const fileId = 1700000101;
    final packets = StreamController<DecodedPacket>.broadcast();
    final stream = RealtimeBleStream(
      packets: packets.stream,
      write: (_) async {},
      crypto: DeviceCrypto(),
    );
    addTearDown(() async {
      await stream.dispose();
      await packets.close();
      if (await _export(fileId).exists()) await _export(fileId).delete();
    });

    await stream.startForFile(fileId);
    expect(await _export(fileId).exists(), isTrue);

    final settled = stream.stateStream.firstWhere((s) => !s.active);
    packets.add(_rx(RxCmd.transportType, RxCmd.fileHeadId, const [0xFF]));
    final state = await settled.timeout(const Duration(seconds: 5));

    expect(state.message, isNotEmpty);
    expect(await _export(fileId).exists(), isFalse);
  });

  test('stopping before any audio arrives leaves no empty export', () async {
    const fileId = 1700000102;
    final packets = StreamController<DecodedPacket>.broadcast();
    final stream = RealtimeBleStream(
      packets: packets.stream,
      write: (_) async {},
      crypto: DeviceCrypto(),
    );
    addTearDown(() async {
      await stream.dispose();
      await packets.close();
      if (await _export(fileId).exists()) await _export(fileId).delete();
    });

    await stream.startForFile(fileId);
    expect(await stream.stop(), isNull);
    expect(await _export(fileId).exists(), isFalse);
  });
}
