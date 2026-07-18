import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anker_recorder/ble/ble_file_pull.dart';
import 'package:anker_recorder/crypto/device_crypto.dart';
import 'package:anker_recorder/protocol/commands.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('active BLE transfer can outlive the inactivity timeout', () async {
    final packets = StreamController<DecodedPacket>();
    final scheduledPackets = <Future<void>>[];
    final file = OfflineFileEntry(
      fileId: DateTime.now().microsecondsSinceEpoch,
      sizeBytes: 640,
    );
    final pull = BleFilePull(
      packets: packets.stream,
      write: (_) async {
        packets.add(_packet(RxCmd.fileHeadId, Uint8List(10)));
        for (var i = 0; i < 4; i++) {
          scheduledPackets.add(
            Future<void>.delayed(Duration(milliseconds: 25 * (i + 1)), () {
              packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(i)));
            }),
          );
        }
      },
      crypto: DeviceCrypto(),
    );

    final path = await pull.pullFile(
      file,
      timeout: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      await Future.wait(scheduledPackets);
      await packets.close();
      final output = File(path);
      if (await output.exists()) await output.delete();
    });

    expect(await File(path).length(), 640);
  });
}

DecodedPacket _packet(int commandId, Uint8List raw) {
  return DecodedPacket(
    raw: raw,
    statusByte: 1,
    cmdType: RxCmd.transportType,
    cmdId: commandId,
    payload: Uint8List(0),
  );
}

Uint8List _sliceFrame(int sequence) {
  final raw = Uint8List(175);
  final sequenceBytes = u32Le(sequence);
  raw.setRange(9, 13, sequenceBytes);
  raw[13] = 0;
  raw.fillRange(14, 174, sequence + 1);
  return raw;
}
