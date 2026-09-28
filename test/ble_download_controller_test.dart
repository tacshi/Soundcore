import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anker_recorder/ble/ble_service.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Ble ble;
  late RecorderController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ble-download-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    ble = _Ble();
    controller = RecorderController(loadPersistedState: false, ble: ble)
      ..connected = true
      ..encryptReady = true
      ..phase = AppPhase.ready;
  });

  tearDown(() async {
    controller.autoRealtime = false;
    ble.finish();
    await _until(
      () =>
          !controller.autoTransferActive &&
          controller.downloadingFileId == null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  Future<void> startBacklog() async {
    final exports = await Directory(
      '${directory.path}/AnkerRecorder/exports',
    ).create(recursive: true);
    await File('${exports.path}/101.wav').writeAsBytes(List.filled(200, 0));
    await controller.listFiles();
    ble.filePage([103, 102, 101]);
    await _until(() => ble.downloads.isNotEmpty);
    expect(ble.downloads.first, 103);
  }

  test(
    'auto transfer counts completed device recordings, not batch attempts',
    () async {
      await startBacklog();
      expect(controller.statusMessage, startsWith('自动传输 1/3'));
      ble.finish();
      await _until(() => ble.downloads.length == 2);
      expect(controller.statusMessage, startsWith('自动传输 2/3'));
    },
  );

  test('manual download takes priority over a running BLE backlog', () async {
    await startBacklog();
    final requested = controller.files.singleWhere((f) => f.fileId == 102);
    final work = controller.downloadFileOverBle(requested);
    expect(controller.downloadingFileId, 102);
    await _until(() => ble.downloads.contains(102));
    ble.finish();
    await work;
    expect(controller.localPathFor(102), isNotNull);
    expect(controller.downloadingFileId, isNull);
    await _until(() => ble.downloads.length == 3);
    expect(ble.downloads, [103, 102, 103]);
  });

  test(
    'failed automatic downloads do not increment the completed count',
    () async {
      ble.failDownloads.add(103);
      await startBacklog();
      await _until(() => ble.downloads.length == 2);
      expect(controller.statusMessage, startsWith('自动传输 1/3'));
      expect(controller.localPathFor(103), isNull);
    },
  );

  test(
    'manual request during backlog preparation reserves the BLE puller',
    () async {
      Future<void>? manual;
      void request() {
        if (!controller.autoTransferActive || manual != null) return;
        controller.removeListener(request);
        manual = controller.downloadFileOverBle(
          controller.files.singleWhere((file) => file.fileId == 102),
        );
      }

      controller.addListener(request);
      await controller.listFiles();
      ble.filePage([103, 102]);
      await _until(() => ble.downloads.isNotEmpty);
      expect(ble.downloads, [102]);
      expect(controller.downloadingFileId, 102);
      ble.finish();
      await manual;
      await _until(() => ble.downloads.length == 2);
      expect(ble.downloads, [102, 103]);
    },
  );
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    ready(),
    isTrue,
    reason: 'BLE operation did not reach the expected state',
  );
}

class _Ble extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final downloads = <int>[];
  final failDownloads = <int>{};

  void filePage(List<int> ids) {
    final data = ByteData(2 + ids.length * 12)
      ..setUint16(0, ids.length, Endian.little);
    for (var i = 0; i < ids.length; i++) {
      data.setUint32(2 + i * 12, ids[i], Endian.little);
      data.setUint32(6 + i * 12, ids[i] + 1, Endian.little);
      data.setUint32(10 + i * 12, 160, Endian.little);
    }
    _packets.add(
      DecodedPacket(
        raw: Uint8List(0),
        statusByte: 1,
        cmdType: 0x1B,
        cmdId: 0x0E,
        payload: data.buffer.asUint8List(),
      ),
    );
  }

  void finish() {
    final raw = Uint8List(175)..fillRange(14, 174, 1);
    _emit(0x08, raw);
    _emit(0x0A, Uint8List(10));
  }

  void _emit(int id, Uint8List raw) => _packets.add(
    DecodedPacket(
      raw: raw,
      statusByte: 1,
      cmdType: 0x1A,
      cmdId: id,
      payload: Uint8List(0),
    ),
  );

  @override
  Stream<DecodedPacket> get packets => _packets.stream;
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {
    if (frame[5] == 0x1A && frame[6] == 0x07) {
      final id = readU32Le(Uint8List.fromList(frame), 13);
      downloads.add(id);
      if (failDownloads.contains(id)) throw StateError('BLE request failed');
      _emit(0x07, Uint8List(10));
    }
  }

  @override
  Future<void> dispose() => _packets.close();
}
