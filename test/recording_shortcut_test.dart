import 'dart:async';

import 'package:anker_recorder/ble/ble_service.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/state/device_store.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/wifi/wifi_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recording shortcut', () {
    test('connected recorder starts exactly once', () async {
      final ble = _FakeBleService()..ready = true;
      final controller = _controller(ble)
        ..connected = true
        ..phase = AppPhase.ready
        ..encryptReady = true;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();

      expect(controller.recording, isTrue);
      expect(controller.recordingShortcutPending, isFalse);
      expect(ble.startRecordWrites, 1);
    });

    test(
      'duplicate requests coalesce while start write is in flight',
      () async {
        final ble = _FakeBleService()
          ..ready = true
          ..blockStartWrite = true;
        final controller = _controller(ble)
          ..connected = true
          ..phase = AppPhase.ready
          ..encryptReady = true;
        _disposeAfterSettling(controller);

        final first = controller.requestRecordingFromShortcut();
        await ble.startWriteEntered.future;
        await controller.requestRecordingFromShortcut();

        expect(ble.startRecordWrites, 1);
        ble.releaseStartWrite();
        await first;
        expect(controller.recording, isTrue);
      },
    );

    test('already-recording invocation sends no command', () async {
      final ble = _FakeBleService()..ready = true;
      final controller = _controller(ble)
        ..connected = true
        ..phase = AppPhase.ready
        ..recording = true;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();

      expect(ble.startRecordWrites, 0);
      expect(controller.statusMessage, '录音中');
    });

    test('failed BLE write never sets optimistic recording state', () async {
      final ble = _FakeBleService()
        ..ready = true
        ..failStartWrite = true;
      final controller = _controller(ble)
        ..connected = true
        ..phase = AppPhase.ready;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();

      expect(controller.recording, isFalse);
      expect(controller.recordingShortcutPending, isFalse);
      expect(controller.statusMessage, '快捷录音未开始');
      expect(controller.errorMessage, contains('start write failed'));
    });

    test('waits for persisted device state before reconnecting', () async {
      final ble = _FakeBleService();
      final loaded = Completer<PersistedDeviceState>();
      final controller = RecorderController(
        ble: ble,
        loadPersistedState: false,
        persistedDeviceLoader: () => loaded.future,
        recordingShortcutScanTimeout: const Duration(seconds: 1),
      );
      _disposeAfterSettling(controller);

      final request = controller.requestRecordingFromShortcut();
      await Future<void>.delayed(Duration.zero);
      expect(ble.startScanCalls, 0);

      loaded.complete((bound: true, device: _device, info: null));
      await request;
      await Future<void>.delayed(Duration.zero);

      expect(controller.recordingShortcutPending, isTrue);
      expect(ble.startScanCalls, 1);
    });

    test('offline paired recorder reconnects and starts', () async {
      final ble = _FakeBleService();
      final controller = _controller(ble)
        ..bound = true
        ..lastKnownDevice = _device
        ..activeDevice = _device;
      _disposeAfterSettling(controller);

      await controller.requestRecordingFromShortcut();
      expect(controller.recordingShortcutPending, isTrue);
      ble.emitScan([_device]);
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(ble.connectCalls, 1);
      expect(ble.startRecordWrites, 1);
      expect(controller.recording, isTrue);
      expect(controller.recordingShortcutPending, isFalse);
    });

    test('unpaired, busy, and exporting states fail without writing', () async {
      final unpairedBle = _FakeBleService();
      final unpaired = _controller(unpairedBle);
      _disposeAfterSettling(unpaired);
      await unpaired.requestRecordingFromShortcut();
      expect(unpaired.errorMessage, contains('已绑定'));

      final busyBle = _FakeBleService()..ready = true;
      final busy = _controller(busyBle)
        ..connected = true
        ..phase = AppPhase.busy;
      _disposeAfterSettling(busy);
      await busy.requestRecordingFromShortcut();
      expect(busy.errorMessage, contains('设备正忙'));

      final exportingBle = _FakeBleService()..ready = true;
      final exporting = _controller(exportingBle)
        ..connected = true
        ..phase = AppPhase.ready
        ..exportProgress = ExportProgress(phase: ExportPhase.transferring);
      _disposeAfterSettling(exporting);
      await exporting.requestRecordingFromShortcut();
      expect(exporting.errorMessage, contains('正在导出'));

      expect(unpairedBle.startRecordWrites, 0);
      expect(busyBle.startRecordWrites, 0);
      expect(exportingBle.startRecordWrites, 0);
    });

    test(
      'scan timeout clears request so later reconnect cannot record',
      () async {
        final ble = _FakeBleService();
        final controller =
            RecorderController(
                ble: ble,
                loadPersistedState: false,
                recordingShortcutScanTimeout: const Duration(milliseconds: 20),
              )
              ..bound = true
              ..lastKnownDevice = _device;
        _disposeAfterSettling(controller);

        await controller.requestRecordingFromShortcut();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(controller.recordingShortcutPending, isFalse);
        expect(controller.errorMessage, contains('30 秒'));

        ble.ready = true;
        ble.emitConnection(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(ble.startRecordWrites, 0);
      },
    );
  });
}

RecorderController _controller(_FakeBleService ble) => RecorderController(
  ble: ble,
  loadPersistedState: false,
  recordingShortcutScanTimeout: const Duration(seconds: 1),
);

void _disposeAfterSettling(RecorderController controller) {
  addTearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}

final _device = ScannedDevice(
  id: 'D3200-test',
  name: 'soundcore Work',
  rssi: -40,
  productCode: 'D3200',
  isBoundAdvertised: true,
  isD3200: true,
);

class _FakeBleService extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scanResults = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionState = StreamController<bool>.broadcast();
  final _logs = StreamController<String>.broadcast();
  final writtenFrames = <List<int>>[];

  bool ready = false;
  bool failStartWrite = false;
  bool blockStartWrite = false;
  int startScanCalls = 0;
  int connectCalls = 0;
  Completer<void> startWriteEntered = Completer<void>();
  Completer<void>? _startWriteRelease;

  int get startRecordWrites => writtenFrames
      .where(
        (frame) =>
            frame.length > 9 &&
            frame[5] == 0x18 &&
            frame[6] == 0x82 &&
            frame[9] == 0x01,
      )
      .length;

  @override
  Stream<DecodedPacket> get packets => _packets.stream;

  @override
  Stream<List<ScannedDevice>> get scanResults => _scanResults.stream;

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  bool get isConnected => ready;

  @override
  bool get isConnecting => false;

  @override
  Future<bool> isD3200ConnectedToSystem(String remoteId) async => false;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    startScanCalls++;
  }

  @override
  Future<void> connect(String remoteId, {String? serviceUuidHint}) async {
    connectCalls++;
    ready = true;
    _connectionState.add(true);
  }

  @override
  Future<void> writeCommand(List<int> frame) async {
    writtenFrames.add(List<int>.from(frame));
    final isStart =
        frame.length > 9 &&
        frame[5] == 0x18 &&
        frame[6] == 0x82 &&
        frame[9] == 0x01;
    if (isStart) {
      if (!startWriteEntered.isCompleted) startWriteEntered.complete();
      if (failStartWrite) throw StateError('start write failed');
      if (blockStartWrite) {
        _startWriteRelease ??= Completer<void>();
        await _startWriteRelease!.future;
      }
    }
    // Keep reconnect tests fast: the controller treats a failed optional ECDH
    // handshake as non-fatal and continues to the recording request.
    if (frame.length > 6 && frame[5] == 0x2E) {
      throw StateError('encryption unavailable in test');
    }
  }

  void releaseStartWrite() {
    if (!(_startWriteRelease?.isCompleted ?? true)) {
      _startWriteRelease!.complete();
    }
  }

  void emitScan(List<ScannedDevice> devices) => _scanResults.add(devices);

  void emitConnection(bool connected) => _connectionState.add(connected);

  @override
  Future<void> dispose() async {
    await _packets.close();
    await _scanResults.close();
    await _connectionState.close();
    await _logs.close();
  }
}
