import 'dart:async';
import 'dart:typed_data';

import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/ble/ble_service.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pause closes Soniox and ignores its late transcript and error',
    () async {
      final ble = _PauseBleService();
      final soniox = _FakeSttStreamSession();
      final controller = RecorderController(ble: ble, loadPersistedState: false)
        ..connected = true
        ..phase = AppPhase.ready
        ..recording = true
        ..attachSttStreamForTesting(soniox);
      addTearDown(() async {
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      });

      soniox.emit(
        const SttStreamEvent(
          type: 'partial',
          text: '录音中的文字',
          speechFinal: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.transcript, '录音中的文字');

      await controller.pauseRecord();
      soniox.emit(
        const SttStreamEvent(
          type: 'partial',
          text: '暂停后不应出现',
          speechFinal: true,
        ),
      );
      soniox.emit(
        const SttStreamEvent(type: 'error', error: '408 Request timeout.'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(soniox.closeCalls, 1);
      expect(soniox.finishCalls, 0);
      expect(soniox.finalizeUtteranceCalls, 0);
      expect(controller.streamingSttActive, isFalse);
      expect(controller.transcript, '录音中的文字');
      expect(controller.transcriptError, isNull);
    },
  );
}

class _FakeSttStreamSession implements SttStreamSession {
  final _events = StreamController<SttStreamEvent>.broadcast();

  int closeCalls = 0;
  int finishCalls = 0;
  int finalizeUtteranceCalls = 0;

  void emit(SttStreamEvent event) => _events.add(event);

  @override
  Stream<SttStreamEvent> get events => _events.stream;

  @override
  bool get isOpen => closeCalls == 0;

  @override
  bool get isServerReady => closeCalls == 0;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {}

  @override
  void sendPcm(Uint8List pcm16le) {}

  @override
  void finalizeUtterance() {
    finalizeUtteranceCalls++;
  }

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    finishCalls++;
    return null;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _PauseBleService extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final _scanResults = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionState = StreamController<bool>.broadcast();
  final _logs = StreamController<String>.broadcast();

  @override
  Stream<DecodedPacket> get packets => _packets.stream;

  @override
  Stream<List<ScannedDevice>> get scanResults => _scanResults.stream;

  @override
  Stream<bool> get connectionState => _connectionState.stream;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> writeCommand(List<int> frame) async {}

  @override
  Future<void> dispose() async {
    await _packets.close();
    await _scanResults.close();
    await _connectionState.close();
    await _logs.close();
  }
}
