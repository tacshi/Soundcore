import 'dart:async';
import 'dart:typed_data';

import '../ble/ble_service.dart';
import 'ota_protocol.dart';

enum FirmwareOtaPhase {
  idle,
  validating,
  preparing,
  transferring,
  verifying,
  applying,
  completed,
  cancelled,
  failed,
}

class FirmwareOtaState {
  const FirmwareOtaState({
    this.phase = FirmwareOtaPhase.idle,
    this.fileName,
    this.sentBytes = 0,
    this.totalBytes = 0,
    this.message = '',
    this.error,
  });

  final FirmwareOtaPhase phase;
  final String? fileName;
  final int sentBytes;
  final int totalBytes;
  final String message;
  final String? error;

  double get fraction =>
      totalBytes <= 0 ? 0 : (sentBytes / totalBytes).clamp(0.0, 1.0).toDouble();

  bool get active => switch (phase) {
    FirmwareOtaPhase.validating ||
    FirmwareOtaPhase.preparing ||
    FirmwareOtaPhase.transferring ||
    FirmwareOtaPhase.verifying ||
    FirmwareOtaPhase.applying => true,
    _ => false,
  };
}

/// Stateful D3200 Bluetooth-firmware OTA transfer.
class FirmwareOtaService {
  FirmwareOtaService(this._ble) {
    _notificationSub = _ble.otaNotifications.listen(_onNotification);
  }

  final BleService _ble;
  final _states = StreamController<FirmwareOtaState>.broadcast();
  StreamSubscription<Uint8List>? _notificationSub;

  FirmwareOtaState _state = const FirmwareOtaState();
  Completer<Uint8List>? _responseCompleter;
  Set<int> _expectedResponses = const {};
  bool _cancelRequested = false;

  Stream<FirmwareOtaState> get states => _states.stream;
  FirmwareOtaState get state => _state;

  Future<void> start({
    required String fileName,
    required Uint8List firmware,
  }) async {
    if (_state.active) throw StateError('固件更新已在进行中');
    _cancelRequested = false;
    _emit(
      FirmwareOtaState(
        phase: FirmwareOtaPhase.validating,
        fileName: fileName,
        totalBytes: firmware.length,
        message: '正在校验固件…',
      ),
    );

    try {
      if (!_ble.isConnected) throw StateError('设备未连接');
      if (!_ble.supportsOta) throw StateError('设备未提供 OTA GATT 服务');
      if (firmware.length < 4) throw const FormatException('固件文件过短');
      if (firmware.length > 64 * 1024 * 1024) {
        throw const FormatException('固件文件超过 64 MB，拒绝传输');
      }
      if (firmware.every((byte) => byte == 0x00 || byte == 0xFF)) {
        throw const FormatException('固件文件内容无效');
      }

      final wholeCrc = D3200OtaProtocol.crc32(firmware);
      _emit(_copy(phase: FirmwareOtaPhase.preparing, message: '正在进入 OTA 模式…'));
      await _ble.prepareOta();

      await _request(D3200OtaProtocol.protocolVersion(), {0x9A});
      await _request(D3200OtaProtocol.setOtaUser(), {0x98});
      await _request(D3200OtaProtocol.hardwareInfo(), {0x8F});
      // The SDK does not gate these two commands on their informational ACKs;
      // it spaces them by 200 ms, then waits for side selection (0x91).
      await _ble.writeOtaCommand(D3200OtaProtocol.setUpgradeType());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _ble.writeOtaCommand(D3200OtaProtocol.roleSwitchRandomId());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _request(D3200OtaProtocol.selectSide(), {0x91});
      await _request(D3200OtaProtocol.checkBreakpoint(), {0x8D});
      await _request(
        D3200OtaProtocol.start(firmwareSize: firmware.length, crc: wholeCrc),
        {0x81},
      );
      await _request(D3200OtaProtocol.configure(firmware), {0x87});

      _emit(_copy(phase: FirmwareOtaPhase.transferring, message: '正在传输固件…'));
      await _transfer(firmware);
      _checkCancelled();

      _emit(
        _copy(
          phase: FirmwareOtaPhase.verifying,
          sentBytes: firmware.length,
          message: '正在校验完整固件…',
        ),
      );
      final wholeResponse = await _request(D3200OtaProtocol.wholeCrc(), {0x84});
      if (wholeResponse.length < 6 ||
          wholeResponse[1] == 0 ||
          wholeResponse[5] != 1) {
        throw StateError('设备报告完整固件 CRC 校验失败');
      }

      _emit(
        _copy(
          phase: FirmwareOtaPhase.applying,
          sentBytes: firmware.length,
          message: '正在写入固件，请勿断开设备…',
        ),
      );
      await _request(D3200OtaProtocol.applyImage(), {
        0x93,
      }, timeout: const Duration(seconds: 20));

      _emit(
        _copy(
          phase: FirmwareOtaPhase.completed,
          sentBytes: firmware.length,
          message: '固件更新完成，设备将自动重启',
        ),
      );
    } on _OtaCancelled {
      _emit(_copy(phase: FirmwareOtaPhase.cancelled, message: '固件传输已取消'));
    } catch (error) {
      _emit(
        _copy(
          phase: FirmwareOtaPhase.failed,
          message: '固件更新失败',
          error: _cleanError(error),
        ),
      );
      rethrow;
    } finally {
      _responseCompleter = null;
      _expectedResponses = const {};
    }
  }

  Future<void> _transfer(Uint8List firmware) async {
    final chunkSize = _ble.otaPayloadSize;
    var segmentStart = 0;
    while (segmentStart < firmware.length) {
      _checkCancelled();
      final segmentEnd = (segmentStart + D3200OtaProtocol.segmentSize)
          .clamp(0, firmware.length)
          .toInt();
      final segment = Uint8List.sublistView(firmware, segmentStart, segmentEnd);
      var confirmed = false;

      for (var attempt = 1; attempt <= 3 && !confirmed; attempt++) {
        var offset = segmentStart;
        while (offset < segmentEnd) {
          _checkCancelled();
          final end = (offset + chunkSize).clamp(0, segmentEnd).toInt();
          await _ble.writeOtaCommand(
            D3200OtaProtocol.data(Uint8List.sublistView(firmware, offset, end)),
          );
          offset = end;
          _emit(
            _copy(
              phase: FirmwareOtaPhase.transferring,
              sentBytes: offset,
              message: '正在传输固件… ${(offset * 100 / firmware.length).floor()}%',
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        final response = await _request(D3200OtaProtocol.segmentCrc(segment), {
          0x83,
        });
        confirmed = _isSuccessfulCrcResponse(response);
        if (!confirmed && attempt < 3) {
          _emit(
            _copy(
              phase: FirmwareOtaPhase.transferring,
              sentBytes: segmentStart,
              message: '分段校验失败，正在重试（$attempt/3）…',
            ),
          );
        }
      }

      if (!confirmed) {
        throw StateError('固件分段 CRC 校验连续失败 3 次');
      }
      segmentStart = segmentEnd;
    }
  }

  Future<Uint8List> _request(
    Uint8List command,
    Set<int> expected, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _checkCancelled();
    if (_responseCompleter != null) {
      throw StateError('OTA 请求重叠');
    }
    final completer = Completer<Uint8List>();
    _responseCompleter = completer;
    _expectedResponses = expected;
    try {
      await _ble.writeOtaCommand(command);
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          '等待 OTA 响应超时（${expected.map(_hex).join('/')}）',
        ),
      );
    } finally {
      if (identical(_responseCompleter, completer)) {
        _responseCompleter = null;
        _expectedResponses = const {};
      }
    }
  }

  void _onNotification(Uint8List bytes) {
    if (bytes.isEmpty) return;
    final completer = _responseCompleter;
    if (completer != null &&
        !completer.isCompleted &&
        _expectedResponses.contains(bytes.first)) {
      completer.complete(bytes);
    }
  }

  bool _isSuccessfulCrcResponse(Uint8List response) =>
      response.length >= 6 && response[5] != 0;

  void cancel() {
    if (!_state.active || _state.phase == FirmwareOtaPhase.applying) return;
    _cancelRequested = true;
    final completer = _responseCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _OtaCancelled());
    }
  }

  void _checkCancelled() {
    if (_cancelRequested) throw const _OtaCancelled();
  }

  void _emit(FirmwareOtaState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  FirmwareOtaState _copy({
    FirmwareOtaPhase? phase,
    int? sentBytes,
    String? message,
    String? error,
  }) => FirmwareOtaState(
    phase: phase ?? _state.phase,
    fileName: _state.fileName,
    sentBytes: sentBytes ?? _state.sentBytes,
    totalBytes: _state.totalBytes,
    message: message ?? _state.message,
    error: error,
  );

  static String _hex(int value) =>
      '0x${value.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  static String _cleanError(Object error) => error.toString().replaceFirst(
    RegExp(
      r'^(Bad state|Exception|StateError|FormatException|TimeoutException):\s*',
    ),
    '',
  );

  Future<void> dispose() async {
    cancel();
    await _notificationSub?.cancel();
    await _states.close();
  }
}

class _OtaCancelled implements Exception {
  const _OtaCancelled();
}
