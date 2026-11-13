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
      sizeBytes: 80, // 4 frames
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

  test(
    'list size is converted to payload bytes when no head key arrives',
    () async {
      final packets = StreamController<DecodedPacket>();
      final scheduled = <Future<void>>[];
      final file = OfflineFileEntry(fileId: 1700000001, sizeBytes: 160);
      final pull = BleFilePull(
        packets: packets.stream,
        write: (_) async {
          packets.add(_packet(RxCmd.fileHeadId, Uint8List(10)));
          for (var i = 0; i < 8; i++) {
            scheduled.add(
              Future<void>.delayed(Duration(milliseconds: 10 * (i + 1)), () {
                packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(i)));
              }),
            );
          }
          scheduled.add(
            Future<void>.delayed(const Duration(milliseconds: 120), () {
              packets.add(_packet(RxCmd.fileDoneId, Uint8List(10)));
            }),
          );
        },
        crypto: DeviceCrypto(),
      );

      final path = await pull.pullFile(file);
      addTearDown(() async {
        await Future.wait(scheduled);
        await packets.close();
        final output = File(path);
        if (await output.exists()) await output.delete();
      });

      expect(await File(path).length(), 8 * 160);
    },
  );

  test('head size is converted from transport to payload bytes', () async {
    final packets = StreamController<DecodedPacket>();
    final scheduled = <Future<void>>[];
    // The list deliberately reports fewer frames than the head.
    final file = OfflineFileEntry(fileId: 1700000002, sizeBytes: 20);
    final pull = BleFilePull(
      packets: packets.stream,
      write: (_) async {
        packets.add(
          _packet(RxCmd.fileHeadId, _headFrame(file.fileId, 4 * 166)),
        );
        for (var i = 0; i < 4; i++) {
          scheduled.add(
            Future<void>.delayed(Duration(milliseconds: 10 * (i + 1)), () {
              packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(i)));
            }),
          );
        }
      },
      crypto: DeviceCrypto(),
    );

    final path = await pull.pullFile(
      file,
      timeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async {
      await Future.wait(scheduled);
      await packets.close();
      final output = File(path);
      if (await output.exists()) await output.delete();
    });

    expect(await File(path).length(), 4 * 160);
  });

  test('a head for another file is rejected', () async {
    final packets = StreamController<DecodedPacket>();
    final file = OfflineFileEntry(fileId: 1700000003, sizeBytes: 20);
    final pull = BleFilePull(
      packets: packets.stream,
      write: (_) async {
        packets.add(_packet(RxCmd.fileHeadId, _headFrame(1700000099, 166)));
        packets.add(_packet(RxCmd.fileSliceId, _sliceFrame(0)));
        packets.add(_packet(RxCmd.fileDoneId, Uint8List(10)));
      },
      crypto: DeviceCrypto(),
    );
    addTearDown(packets.close);

    await expectLater(pull.pullFile(file), throwsStateError);
  });

  test('file list values map to frames, duration, and payload', () {
    final entry = OfflineFileEntry(fileId: 1, sizeBytes: 1032580);
    expect(entry.frameCount, 51629);
    expect(entry.durationMs, 1032580);
    expect(entry.payloadBytes, 51629 * 160);
    expect(OfflineFileEntry.payloadBytesForHeadSize(8570414), 51629 * 160);
  });
}

Uint8List _headFrame(int fileId, int headSize) {
  final raw = Uint8List(97);
  raw.setRange(9, 13, u32Le(fileId));
  raw.setRange(13, 17, u32Le(headSize));
  return raw;
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
