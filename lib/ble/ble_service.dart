import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../protocol/frame.dart';
import '../protocol/models.dart';
import 'advertisement.dart';
import 'uuids.dart';

/// BLE scan / connect / notify pipeline for D3200.
///
/// Discovery matches Feishu: passive BLE advertisement scan (no classic pairing).
/// Connection is a direct GATT connect to WRITE/NOTIFY characteristics.
class BleService {
  final _rxBuffer = <int>[];
  final _packetController = StreamController<DecodedPacket>.broadcast();
  final _scanController = StreamController<List<ScannedDevice>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _logController = StreamController<String>.broadcast();
  final _otaController = StreamController<Uint8List>.broadcast();

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _otaNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _otaChar;

  /// True only after write/notify characteristics are ready.
  bool _fullyReady = false;

  /// True while [connect] is in progress (suppresses spurious disconnect UI).
  bool _connecting = false;

  /// When true (default), only show D3200 / soundcore family advertisements.
  bool filterSoundcoreOnly = true;

  /// Raw ads seen this scan (for diagnostics).
  int adsSeen = 0;

  final Map<String, ScannedDevice> _found = {};
  final Set<String> _loggedIds = {};

  Stream<DecodedPacket> get packets => _packetController.stream;
  Stream<List<ScannedDevice>> get scanResults => _scanController.stream;
  Stream<bool> get connectionState => _connectionController.stream;
  Stream<String> get logs => _logController.stream;
  Stream<Uint8List> get otaNotifications => _otaController.stream;

  bool get isConnected => _device != null && _writeChar != null && _fullyReady;
  bool get supportsOta => isConnected && _otaChar != null;
  bool get isConnecting => _connecting;
  BluetoothDevice? get device => _device;

  void _log(String msg) {
    debugPrint('[BLE] $msg');
    if (!_logController.isClosed) _logController.add(msg);
  }

  void _emitConnection(bool up) {
    if (!_connectionController.isClosed) {
      _connectionController.add(up);
    }
  }

  Future<bool> ensurePermissions() async {
    if (Platform.isMacOS) {
      // macOS uses entitlements + system prompt on first CBCentral use.
      return true;
    }
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      return statuses.values.every((s) => s.isGranted || s.isLimited);
    }
    if (Platform.isIOS) {
      final s = await Permission.bluetooth.request();
      return s.isGranted || s.isLimited || s.isRestricted;
    }
    return true;
  }

  /// Wait until CoreBluetooth / the adapter leaves the transient `unknown`
  /// state. macOS often reports `unknown` for a few hundred ms even when
  /// Control Center already shows Bluetooth On — treating that as "off"
  /// was a false negative.
  Future<BluetoothAdapterState> _waitForStableAdapterState({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Kick the platform channel so macOS creates CBCentralManager.
    final stream = FlutterBluePlus.adapterState;

    try {
      return await stream
          .where(
            (s) =>
                s != BluetoothAdapterState.unknown &&
                s != BluetoothAdapterState.turningOn &&
                s != BluetoothAdapterState.turningOff,
          )
          .first
          .timeout(timeout);
    } on TimeoutException {
      final now = FlutterBluePlus.adapterStateNow;
      _log('Adapter state still unsettled after ${timeout.inSeconds}s → $now');
      return now;
    }
  }

  /// Ensures we can scan/connect. Throws a human-readable [Exception] on hard fail.
  Future<void> ensureBluetoothReady() async {
    if (!await FlutterBluePlus.isSupported) {
      throw Exception('此设备不支持蓝牙低功耗（BLE）。');
    }

    var state = await _waitForStableAdapterState();
    _log('Adapter state: $state');

    if (state == BluetoothAdapterState.on) return;

    if (state == BluetoothAdapterState.unauthorized) {
      throw Exception(
        Platform.isMacOS
            ? 'Anker 录音机未获得蓝牙权限。\n'
                  '系统设置 → 隐私与安全性 → 蓝牙 → 启用本应用后重试。'
            : '蓝牙权限被拒绝。请允许 Anker 录音机使用蓝牙后重试。',
      );
    }

    if (state == BluetoothAdapterState.unavailable) {
      throw Exception('此设备上蓝牙不可用。');
    }

    if (state == BluetoothAdapterState.off) {
      // Android can request turn-on; macOS must be toggled in Control Center.
      if (Platform.isAndroid) {
        try {
          _log('Requesting Bluetooth turnOn…');
          await FlutterBluePlus.turnOn(timeout: 20);
          state = await _waitForStableAdapterState(
            timeout: const Duration(seconds: 15),
          );
          if (state == BluetoothAdapterState.on) return;
        } catch (e) {
          _log('turnOn failed: $e');
        }
      }
      throw Exception(
        '应用检测到蓝牙似乎已关闭。\n'
        '请在控制中心确认蓝牙已开启，然后重新扫描。\n'
        '若仍卡住：完全退出应用后重开（macOS 权限提示）。',
      );
    }

    // Still unknown after wait — on macOS try scanning anyway (CB may work).
    if (state == BluetoothAdapterState.unknown &&
        (Platform.isMacOS || Platform.isIOS)) {
      _log('Proceeding with uncertain adapter state on Apple platform');
      return;
    }

    throw Exception('蓝牙未就绪（状态：$state）。');
  }

  Future<void> startScan({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await ensurePermissions();
    await ensureBluetoothReady();

    _found.clear();
    _loggedIds.clear();
    adsSeen = 0;
    _scanController.add([]);
    await _stopScanAndWait();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        adsSeen++;
        final id = r.device.remoteId.str;

        // Log each unique peripheral once (helps debug empty D3200 filter).
        if (_loggedIds.add(id)) {
          _log('ADV ${AdvertisementParser.debugSummary(r)}');
        }

        final parsed = AdvertisementParser.tryParse(r);
        if (parsed != null) {
          _found[parsed.id] = parsed;
          _log(
            'MATCH ${parsed.displayName} mac=${parsed.macAddress} '
            'uuid=${parsed.serviceUuid} rssi=${parsed.rssi}',
          );
        } else if (!filterSoundcoreOnly) {
          // Show everything (debug mode).
          if (r.rssi < -95) continue;
          _found[id] = AdvertisementParser.fromAny(r);
        }
      }
      final list = _found.values.toList()
        ..sort((a, b) {
          final sa = a.isD3200 ? 0 : (a.looksLikeSoundcore ? 1 : 2);
          final sb = b.isD3200 ? 0 : (b.looksLikeSoundcore ? 1 : 2);
          if (sa != sb) return sa - sb;
          return b.rssi.compareTo(a.rssi);
        });
      _scanController.add(list);
    });

    // IMPORTANT: on macOS, `withServices: [D3200]` often returns **zero**
    // results without error (service UUID only in scan response / not filtered).
    // Always open-scan and filter in software — matches practical Feishu behavior
    // when the OS filter is unreliable.
    _log(
      'Open BLE scan (software filter for ${AnkerUuids.d3200Service.str128}, '
      'soundcoreOnly=$filterSoundcoreOnly)…',
    );
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidUsesFineLocation: true,
      // continuousDuplicates helps catch intermittent ads on Apple platforms
      continuousUpdates: true,
    );
  }

  Future<void> stopScan() async {
    await _stopScanAndWait();
  }

  /// Stop scan and wait until the central reports not scanning.
  /// Concurrent scan + connect is a common cause of flaky first GATT connect.
  Future<void> _stopScanAndWait() async {
    final wasScanning = FlutterBluePlus.isScanningNow || _scanSub != null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;

    if (!wasScanning) return;

    // Wait for platform scan to fully stop (macOS/iOS especially).
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (FlutterBluePlus.isScanningNow && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Extra settle so CoreBluetooth releases the radio for connect.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  Future<void> connect(String remoteId, {String? serviceUuidHint}) async {
    if (_connecting) {
      _log('Connect already in progress — ignoring concurrent request');
      // Wait for the in-flight connect to finish rather than racing.
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (_connecting && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (isConnected && _device?.remoteId.str == remoteId) return;
      if (_connecting) {
        throw StateError('连接进行中，请稍候');
      }
      // If previous failed, fall through to a fresh attempt.
    }

    _connecting = true;
    try {
      // Stop scanning first — concurrent scan often breaks GATT on macOS/iOS.
      await _stopScanAndWait();

      // Tear down any previous session without broadcasting false disconnect
      // storms if we were never fully ready.
      await _cleanupSession(emitDisconnect: _fullyReady);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final device = BluetoothDevice.fromId(remoteId);
      _device = device;

      Object? lastError;
      const maxAttempts = 4;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          await _connectOnce(
            device,
            attempt: attempt,
            maxAttempts: maxAttempts,
          );
          _fullyReady = true;
          _emitConnection(true);
          return;
        } catch (e) {
          lastError = e;
          _log('Connect attempt $attempt/$maxAttempts failed: $e');
          _writeChar = null;
          _otaChar = null;
          _fullyReady = false;
          try {
            await device.disconnect();
          } catch (_) {}
          await _connSub?.cancel();
          _connSub = null;
          await _notifySub?.cancel();
          _notifySub = null;
          await _otaNotifySub?.cancel();
          _otaNotifySub = null;
          if (attempt < maxAttempts) {
            // Longer backoff: radio / peripheral often needs 1–2s after a fail.
            final delayMs = 600 * attempt;
            _log('Retrying in ${delayMs}ms…');
            await Future<void>.delayed(Duration(milliseconds: delayMs));
          }
        }
      }

      _device = null;
      _fullyReady = false;
      _emitConnection(false);
      throw StateError(_friendlyConnectError(lastError));
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectOnce(
    BluetoothDevice device, {
    required int attempt,
    required int maxAttempts,
  }) async {
    _log(
      'GATT connect to ${device.remoteId.str} '
      '(attempt $attempt/$maxAttempts, no classic pairing)…',
    );

    // Wire connection listener BEFORE connect so we never miss the event.
    await _connSub?.cancel();
    final linkUp = Completer<void>();
    _connSub = device.connectionState.listen((s) {
      final up = s == BluetoothConnectionState.connected;
      _log('connectionState → $s');
      if (up && !linkUp.isCompleted) {
        linkUp.complete();
      }
      // Only broadcast *true* after GATT is fully ready (_fullyReady).
      // Emitting false while connected-but-not-ready was resetting UI phase
      // mid-connect and allowing multi-tap races.
      if (!up) {
        _writeChar = null;
        if (_fullyReady) {
          _fullyReady = false;
          _emitConnection(false);
        }
      }
    });

    // Already linked from a previous partial attempt?
    if (device.isConnected) {
      _log('Device already reports connected — discovering services');
      if (!linkUp.isCompleted) linkUp.complete();
    } else {
      try {
        // Direct BLE connect — equivalent to Feishu "dock" one-tap connect.
        await device.connect(
          license: License.nonprofit,
          autoConnect: false,
          mtu: null,
          timeout: const Duration(seconds: 25),
        );
      } catch (e) {
        // FBP may throw if already connecting/connected — recover if link is up.
        final msg = e.toString().toLowerCase();
        if (device.isConnected ||
            msg.contains('already_connected') ||
            msg.contains('already connected')) {
          _log('connect() reported already connected: $e');
          if (!linkUp.isCompleted) linkUp.complete();
        } else {
          rethrow;
        }
      }
    }

    // Wait until CoreBluetooth reports connected (connect() can return early).
    if (device.isConnected) {
      if (!linkUp.isCompleted) linkUp.complete();
    } else {
      await linkUp.future.timeout(
        const Duration(seconds: 18),
        onTimeout: () {
          throw TimeoutException('Timed out waiting for GATT connected state');
        },
      );
    }

    // Give the link a moment to stabilize before service discovery.
    // Fixes PlatformException(discoverServices, device is disconnected, …).
    await Future<void>.delayed(
      Duration(milliseconds: Platform.isMacOS || Platform.isIOS ? 500 : 350),
    );
    if (!device.isConnected) {
      throw StateError('Device dropped right after connect');
    }

    if (Platform.isAndroid) {
      try {
        await device.requestMtu(247);
      } catch (_) {}
    }

    final services = await _discoverServicesWithRetry(device);

    for (final s in services) {
      _log('  service ${s.uuid}');
    }

    BluetoothCharacteristic? write;
    BluetoothCharacteristic? notify;
    BluetoothCharacteristic? ota;

    // Prefer characteristics under the D3200 service when present.
    final preferred = <BluetoothService>[
      ...services.where((s) => AnkerUuids.isD3200Service(s.uuid)),
      ...services,
    ];

    for (final svc in preferred) {
      for (final c in svc.characteristics) {
        if (ota == null && AnkerUuids.isOta(c.uuid)) {
          ota = c;
        }
        if (write == null &&
            AnkerUuids.isWrite(c.uuid) &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          write = c;
        }
        if (notify == null &&
            AnkerUuids.isRead(c.uuid) &&
            (c.properties.notify ||
                c.properties.indicate ||
                c.properties.read)) {
          notify = c;
        }
      }
    }

    if (write == null || notify == null) {
      for (final svc in services) {
        for (final c in svc.characteristics) {
          write ??= (c.properties.write || c.properties.writeWithoutResponse)
              ? c
              : null;
          notify ??= (c.properties.notify || c.properties.indicate) ? c : null;
        }
      }
    }

    if (write == null) {
      throw StateError('Write characteristic not found (expected …7777…)');
    }
    if (notify == null) {
      throw StateError('Notify characteristic not found (expected …8888…)');
    }

    _writeChar = write;
    _otaChar = ota;
    _rxBuffer.clear();

    // Enable notify with a short retry — occasional macOS flake.
    Object? notifyErr;
    for (var i = 0; i < 3; i++) {
      try {
        await notify.setNotifyValue(true);
        notifyErr = null;
        break;
      } catch (e) {
        notifyErr = e;
        _log('setNotifyValue failed ($e), retry ${i + 1}/3');
        await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
        if (!device.isConnected) {
          throw StateError('Device disconnected while enabling notify');
        }
      }
    }
    if (notifyErr != null) throw notifyErr;

    await _notifySub?.cancel();
    _notifySub = notify.onValueReceived.listen(_onBytes);
    device.cancelWhenDisconnected(_notifySub!);

    if (ota != null && (ota.properties.notify || ota.properties.indicate)) {
      try {
        await ota.setNotifyValue(true);
        await _otaNotifySub?.cancel();
        _otaNotifySub = ota.onValueReceived.listen((data) {
          if (data.isEmpty) return;
          final bytes = Uint8List.fromList(data);
          _log('OTA RX ${bytes.toHex()}');
          if (!_otaController.isClosed) _otaController.add(bytes);
        });
        device.cancelWhenDisconnected(_otaNotifySub!);
      } catch (e) {
        _log('OTA notifications unavailable: $e');
        _otaChar = null;
      }
    }

    _log(
      'Connected. write=${write.uuid} notify=${notify.uuid} '
      'ota=${_otaChar?.uuid ?? "none"} services=${services.length}',
    );
  }

  Future<List<BluetoothService>> _discoverServicesWithRetry(
    BluetoothDevice device,
  ) async {
    Object? lastError;
    for (var i = 0; i < 4; i++) {
      if (!device.isConnected) {
        throw StateError('Device disconnected during service discovery');
      }
      try {
        _log('Discovering services (try ${i + 1}/4)…');
        final services = await device.discoverServices();
        if (services.isNotEmpty) return services;
        lastError = StateError('discoverServices returned empty list');
        _log('Empty services list — retrying…');
      } catch (e) {
        lastError = e;
        _log('discoverServices failed ($e)');
      }
      // Increasing settle: 400 → 700 → 1000 ms
      await Future<void>.delayed(Duration(milliseconds: 400 + i * 300));
    }
    throw lastError ?? StateError('Service discovery failed');
  }

  static String _friendlyConnectError(Object? e) {
    final s = e?.toString() ?? 'unknown error';
    if (s.contains('discoverServices') && s.contains('disconnected')) {
      return '建立 GATT 时连接中断。\n'
          '请将录音豆靠近电脑并保持唤醒，然后重试。\n'
          '提示：先关闭占用设备的其他应用（如飞书）再试。';
    }
    if (s.contains('Timeout') || s.contains('timeout')) {
      return '连接超时。请靠近设备后重试。';
    }
    return s
        .replaceFirst(RegExp(r'^PlatformException\([^,]*,\s*'), '')
        .replaceFirst(RegExp(r',.*\)$'), '')
        .replaceFirst(
          RegExp(r'^(Exception|StateError|TimeoutException):\s*'),
          '',
        );
  }

  void _onBytes(List<int> data) {
    if (data.isEmpty) return;
    _rxBuffer.addAll(data);
    final packets = ProtocolFrame.processBuffer(_rxBuffer);
    for (final p in packets) {
      _log('RX $p  ${p.raw.toHex()}');
      _packetController.add(p);
    }
  }

  Future<void> writeCommand(List<int> frame) async {
    final c = _writeChar;
    if (c == null || !_fullyReady) throw StateError('未连接');
    _log('TX ${frame.toHex()}');
    final withoutResp = c.properties.writeWithoutResponse;
    await c.write(frame, withoutResponse: withoutResp);
  }

  /// Ask for the largest practical ATT MTU before a firmware transfer.
  Future<void> prepareOta() async {
    final device = _device;
    if (device == null || !_fullyReady) throw StateError('未连接');
    if (_otaChar == null) throw StateError('设备未提供 OTA GATT 服务');
    if (Platform.isAndroid) {
      try {
        await device.requestMtu(512);
      } catch (e) {
        _log('OTA MTU 512 request failed; using ${device.mtuNow}: $e');
      }
    }
    _log('OTA ready: mtu=${device.mtuNow}, payload=$otaPayloadSize');
  }

  /// Maximum BES 0x85 payload that fits one ATT characteristic write.
  int get otaPayloadSize {
    final mtu = _device?.mtuNow ?? 23;
    // ATT value is MTU-3; BES command+length header is 5 bytes.
    return (mtu - 8).clamp(12, 504).toInt();
  }

  Future<void> writeOtaCommand(List<int> command) async {
    final c = _otaChar;
    if (c == null || !_fullyReady) throw StateError('OTA 通道未就绪');
    final maxWrite = ((_device?.mtuNow ?? 23) - 3).clamp(17, 509).toInt();
    if (command.length > maxWrite) {
      throw StateError('OTA 数据包 ${command.length}B 超过当前 BLE 上限 ${maxWrite}B');
    }
    _log('OTA TX ${command.toHex()}');
    final withoutResponse = c.properties.writeWithoutResponse;
    await c.write(command, withoutResponse: withoutResponse);
  }

  Future<void> _cleanupSession({required bool emitDisconnect}) async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _otaNotifySub?.cancel();
    _otaNotifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _writeChar = null;
    _otaChar = null;
    _rxBuffer.clear();
    final wasReady = _fullyReady;
    _fullyReady = false;
    if (emitDisconnect && wasReady) {
      _emitConnection(false);
    }
  }

  Future<void> disconnect() async {
    await _cleanupSession(emitDisconnect: true);
    // Always notify UI we are down (even if never fully ready).
    if (!_fullyReady) {
      _emitConnection(false);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await stopScan();
    await _packetController.close();
    await _scanController.close();
    await _connectionController.close();
    await _logController.close();
    await _otaController.close();
  }
}
