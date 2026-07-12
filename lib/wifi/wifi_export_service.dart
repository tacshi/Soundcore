import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/device_crypto.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';

/// SoftAP credentials + endpoint returned by the device after 1A05.
class WifiEndpoint {
  WifiEndpoint({
    required this.ssid,
    required this.password,
    required this.ip,
    required this.port,
  });

  final String ssid;
  final String password;
  final String ip;
  final int port;

  String get displayEndpoint => '$ip:$port';

  @override
  String toString() => 'WifiEndpoint($ssid → $displayEndpoint)';
}

enum ExportPhase {
  idle,
  openingSoftAp,
  awaitJoin,
  connectingWs,
  transferring,
  closing,
  done,
  error,
}

class ExportProgress {
  ExportProgress({
    this.phase = ExportPhase.idle,
    this.message = '',
    this.ssid,
    this.password,
    this.endpoint,
    this.currentFileId,
    this.currentFileIndex = 0,
    this.totalFiles = 0,
    this.bytesReceived = 0,
    this.bytesExpected = 0,
    this.savedPaths = const [],
    this.error,
  });

  final ExportPhase phase;
  final String message;
  final String? ssid;
  final String? password;
  final WifiEndpoint? endpoint;
  final int? currentFileId;
  final int currentFileIndex;
  final int totalFiles;
  final int bytesReceived;
  final int bytesExpected;
  final List<String> savedPaths;
  final String? error;

  double get fileFraction {
    if (bytesExpected <= 0) return 0;
    return (bytesReceived / bytesExpected).clamp(0.0, 1.0);
  }

  double get batchFraction {
    if (totalFiles <= 0) return 0;
    final done = currentFileIndex.clamp(0, totalFiles);
    final partial = fileFraction / totalFiles;
    return ((done / totalFiles) + partial).clamp(0.0, 1.0);
  }

  ExportProgress copyWith({
    ExportPhase? phase,
    String? message,
    String? ssid,
    String? password,
    WifiEndpoint? endpoint,
    int? currentFileId,
    int? currentFileIndex,
    int? totalFiles,
    int? bytesReceived,
    int? bytesExpected,
    List<String>? savedPaths,
    String? error,
    bool clearError = false,
  }) {
    return ExportProgress(
      phase: phase ?? this.phase,
      message: message ?? this.message,
      ssid: ssid ?? this.ssid,
      password: password ?? this.password,
      endpoint: endpoint ?? this.endpoint,
      currentFileId: currentFileId ?? this.currentFileId,
      currentFileIndex: currentFileIndex ?? this.currentFileIndex,
      totalFiles: totalFiles ?? this.totalFiles,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesExpected: bytesExpected ?? this.bytesExpected,
      savedPaths: savedPaths ?? this.savedPaths,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Wi‑Fi SoftAP + WebSocket fast transfer (PROTOCOL.md §6.4–6.5).
///
/// Flow:
/// 1. BLE `1A05` with phone-chosen SSID/password (`WiFi-{ts}` / `{ts}`)
/// 2. Device replies `1A05` with IP:port over BLE
/// 3. User joins SoftAP (manual on macOS/iOS; Android may auto-join later)
/// 4. WebSocket `ws|wss://ip:port` + UDP keepalive `:32003`
/// 5. For each file: hex text `1A07` request → `1A07` head → `1A08` slices → `1A0A`
/// 6. Text `FINISH` + BLE `1A02` close
class WifiExportService {
  WifiExportService({
    required this.blePackets,
    required this.bleWrite,
    DeviceCrypto? crypto,
  }) : crypto = crypto ?? DeviceCrypto();

  final Stream<DecodedPacket> blePackets;
  final Future<void> Function(List<int> frame) bleWrite;
  final DeviceCrypto crypto;

  /// Soundcore SDK default `wifiConnectionDelayMS` for D3200 SoftAP startup.
  static const softApStartupDelay = Duration(seconds: 10);
  static const webSocketReadyTimeout = Duration(seconds: 6);
  static const webSocketRetryDelay = Duration(milliseconds: 500);

  /// Detect the device subnet without opening its single embedded WSS listener.
  /// The Soundcore SDK checks the joined Wi-Fi network before connecting; a raw
  /// TCP probe can occupy port 443 while the device waits for a TLS handshake.
  static Future<bool> isOnSoftApNetwork(WifiEndpoint ep) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return sharesIpv4Subnet(
        ep.ip,
        interfaces.expand(
          (interface) => interface.addresses.map((a) => a.address),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static bool sharesIpv4Subnet(String deviceIp, Iterable<String> localIps) {
    final device = InternetAddress.tryParse(deviceIp);
    if (device == null || device.type != InternetAddressType.IPv4) return false;
    final target = device.rawAddress;
    return localIps.any((address) {
      final local = InternetAddress.tryParse(address);
      if (local == null || local.type != InternetAddressType.IPv4) return false;
      final bytes = local.rawAddress;
      return bytes[0] == target[0] &&
          bytes[1] == target[1] &&
          bytes[2] == target[2] &&
          bytes[3] != target[3];
    });
  }

  /// Match the exact RFC 6455 handshake emitted by the SDK's OkHttp client
  /// (`okhttp/3.12.13.18` — see decompiled `vv7.d.a()` /
  /// `WiFiWebSocketManager`), byte-for-byte. Two things about `dart:io`'s
  /// [HttpClient] diverge from that on the wire:
  ///  - `HttpHeaders.xxxHeader` constants (and any name set without
  ///    `preserveHeaderCase`) are serialized lowercase (`upgrade:`,
  ///    `sec-websocket-key:`, …). A minimal embedded HTTP/WS parser on the
  ///    recorder doing case-sensitive matching (e.g. `strstr("Upgrade:")`)
  ///    would never recognize the request as an upgrade and reply 400 —
  ///    every header below must be set with its real HTTP casing.
  ///  - Dart's client adds `Cache-Control` and omits `Accept-Encoding`/
  ///    `User-Agent`; OkHttp's `BridgeInterceptor` does the opposite.
  @visibleForTesting
  static Future<WebSocket> connectSdkWebSocket(
    String url,
    HttpClient client,
  ) async {
    final wsUri = Uri.parse(url);
    final httpUri = wsUri.replace(
      scheme: wsUri.scheme == 'wss' ? 'https' : 'http',
    );
    final nonce = Uint8List(16);
    final random = Random.secure();
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = random.nextInt(256);
    }
    final key = base64Encode(nonce);

    client.autoUncompress = false;
    final request = await client.openUrl('GET', httpUri);
    request.followRedirects = false;
    request.headers
      ..removeAll(HttpHeaders.cacheControlHeader)
      ..set(
        'Host',
        httpUri.hasPort ? '${httpUri.host}:${httpUri.port}' : httpUri.host,
        preserveHeaderCase: true,
      )
      ..set('Upgrade', 'websocket', preserveHeaderCase: true)
      ..set('Connection', 'Upgrade', preserveHeaderCase: true)
      ..set('Sec-WebSocket-Key', key, preserveHeaderCase: true)
      ..set('Sec-WebSocket-Version', '13', preserveHeaderCase: true)
      ..set('Accept-Encoding', 'gzip', preserveHeaderCase: true)
      ..set(
        'User-Agent',
        'okhttp/3.12.13.18',
        preserveHeaderCase: true,
      );

    final response = await request.close();
    if (response.statusCode != HttpStatus.switchingProtocols ||
        response.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() !=
            'websocket' ||
        !(response.headers[HttpHeaders.connectionHeader] ?? const []).any(
          (value) => value.toLowerCase() == 'upgrade',
        )) {
      final status = response.statusCode;
      await response.drain<void>();
      throw WebSocketException(
        'SDK-compatible WebSocket upgrade failed (HTTP $status)',
        status,
      );
    }

    const guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    final digest = SHA1Digest().process(
      Uint8List.fromList(utf8.encode('$key$guid')),
    );
    final expectedAccept = base64Encode(digest);
    if (response.headers.value('Sec-WebSocket-Accept') != expectedAccept) {
      await response.drain<void>();
      throw const WebSocketException('Invalid Sec-WebSocket-Accept response');
    }

    final socket = await response.detachSocket();
    return WebSocket.fromUpgradedSocket(
      socket,
      serverSide: false,
      compression: CompressionOptions.compressionOff,
    );
  }

  final _progressController = StreamController<ExportProgress>.broadcast();
  Stream<ExportProgress> get progress => _progressController.stream;

  ExportProgress _progress = ExportProgress();
  ExportProgress get current => _progress;

  Completer<WifiEndpoint>? _wifiConfigCompleter;
  StreamSubscription<DecodedPacket>? _bleSub;
  WebSocketChannel? _ws;
  HttpClient? _wsClient;
  StreamSubscription? _wsSub;
  RawDatagramSocket? _udp;
  Timer? _udpTimer;
  final _rxBuffer = <int>[];
  Completer<void>? _fileDone;
  Completer<FileHeadInfo>? _fileHead;
  IOSink? _fileSink;
  int _sliceBytes = 0;
  int _expectedSize = 0;
  bool _cancelled = false;
  Completer<void> _cancelSignal = Completer<void>();
  String? _activeFileId;
  bool _decryptEnabled = false;
  int _decryptedChunks = 0;
  int _rawFallbackChunks = 0;

  void _emit(ExportProgress p) {
    _progress = p;
    if (!_progressController.isClosed) _progressController.add(p);
  }

  void _log(String m) => debugPrint('[WiFiExport] $m');

  /// Generate Feishu-style credentials: SSID `WiFi-{ms}`, password `{ms}`.
  static ({String ssid, String password}) generateCredentials() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    return (ssid: 'WiFi-$ms', password: '$ms');
  }

  /// Parse device 1A05 success payload (full frame offsets 9..14).
  static WifiEndpoint? parseWifiConfigPacket(
    DecodedPacket p, {
    required String ssid,
    required String password,
  }) {
    if (p.cmdType != RxCmd.transportType || p.cmdId != RxCmd.wifiConfigId) {
      return null;
    }
    if (!p.isSuccess) return null;
    // Prefer absolute offsets on full frame (WifiMessageDispatch).
    final data = p.raw;
    if (data.length < 15) return null;
    final ip =
        '${data[12] & 0xFF}.${data[11] & 0xFF}.${data[10] & 0xFF}.${data[9] & 0xFF}';
    final port = (data[13] & 0xFF) | ((data[14] & 0xFF) << 8);
    if (port <= 0 || port > 65535) return null;
    return WifiEndpoint(ssid: ssid, password: password, ip: ip, port: port);
  }

  /// Step 1–2: open SoftAP over BLE and wait for IP:port.
  Future<WifiEndpoint> openSoftAp({
    String? ssid,
    String? password,
    Duration timeout = const Duration(seconds: 45),
    Duration startupDelay = softApStartupDelay,
    Future<void> Function()? onConfigured,
  }) async {
    _cancelled = false;
    _cancelSignal = Completer<void>();
    final creds = generateCredentials();
    final s = ssid ?? creds.ssid;
    final pw = password ?? creds.password;

    _emit(
      ExportProgress(
        phase: ExportPhase.openingSoftAp,
        message: '正在开启设备 SoftAP…',
        ssid: s,
        password: pw,
      ),
    );

    await _bleSub?.cancel();
    _wifiConfigCompleter = Completer<WifiEndpoint>();
    _bleSub = blePackets.listen((pkt) {
      final ep = parseWifiConfigPacket(pkt, ssid: s, password: pw);
      if (ep != null && !(_wifiConfigCompleter?.isCompleted ?? true)) {
        _log('SoftAP ready: $ep');
        _wifiConfigCompleter!.complete(ep);
      } else if (pkt.cmdType == RxCmd.transportType &&
          pkt.cmdId == RxCmd.wifiConfigId &&
          !pkt.isSuccess) {
        if (!(_wifiConfigCompleter?.isCompleted ?? true)) {
          _wifiConfigCompleter!.completeError(
            StateError('设备拒绝 Wi‑Fi 配置（flag=${pkt.successFlag}）'),
          );
        }
      }
    });

    final frame = DeviceCommands.sendWifiConfig(ssid: s, password: pw);
    await bleWrite(frame);
    _log('Sent 1A05 SSID=$s');

    try {
      final ep = await _wifiConfigCompleter!.future.timeout(timeout);
      _emit(
        _progress.copyWith(
          phase: ExportPhase.awaitJoin,
          message: '设备热点启动中…',
          endpoint: ep,
          ssid: s,
          password: pw,
        ),
      );
      await _bleSub?.cancel();
      _bleSub = null;
      await onConfigured?.call();
      await Future.any<void>([
        Future<void>.delayed(startupDelay),
        _cancelSignal.future,
      ]);
      if (_cancelled) throw StateError('已取消 Wi-Fi 导出');
      _emit(_progress.copyWith(message: '设备热点已就绪，请加入「$s」'));
      return ep;
    } on TimeoutException {
      _emit(
        _progress.copyWith(
          phase: ExportPhase.error,
          error: '等待 SoftAP IP（1A05）超时。请保持 BLE 连接。',
          message: 'SoftAP 超时',
        ),
      );
      rethrow;
    }
  }

  /// Step 4–6: after user joined SoftAP, pull [files] over WebSocket.
  Future<List<String>> transferFiles({
    required WifiEndpoint endpoint,
    required List<OfflineFileEntry> files,
    bool useSsl = true,
  }) async {
    if (files.isEmpty) return const [];
    if (_cancelled) throw StateError('已取消 Wi-Fi 导出');
    final saved = <String>[];

    _emit(
      _progress.copyWith(
        phase: ExportPhase.connectingWs,
        message: '正在连接 WebSocket ${endpoint.displayEndpoint}…',
        endpoint: endpoint,
        totalFiles: files.length,
        currentFileIndex: 0,
        clearError: true,
      ),
    );

    try {
      await _connectWs(endpoint, useSsl: useSsl);
      _startUdpKeepalive(endpoint.ip);

      final outDir = await _exportDir();
      _log('Export dir: ${outDir.path}');

      for (var i = 0; i < files.length; i++) {
        if (_cancelled) break;
        final f = files[i];
        _emit(
          _progress.copyWith(
            phase: ExportPhase.transferring,
            message: '正在传输 ${f.title}…',
            currentFileId: f.fileId,
            currentFileIndex: i,
            totalFiles: files.length,
            bytesReceived: 0,
            bytesExpected: f.sizeBytes,
          ),
        );
        final path = await _transferOne(f, outDir);
        if (path != null) {
          saved.add(path);
          _emit(
            _progress.copyWith(
              savedPaths: List.unmodifiable(saved),
              message: '已保存 ${p.basename(path)}',
              currentFileIndex: i + 1,
              bytesReceived: f.sizeBytes,
            ),
          );
        }
      }

      if (_cancelled) return saved;

      // Close transfer session
      try {
        _ws?.sink.add('FINISH');
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        _ws?.sink.add(_buildTransferCompleteHex());
      } catch (_) {}

      _emit(
        _progress.copyWith(
          phase: ExportPhase.done,
          message: saved.isEmpty ? '未保存任何文件' : '已导出 ${saved.length} 个文件',
          currentFileIndex: files.length,
          savedPaths: List.unmodifiable(saved),
        ),
      );
      return saved;
    } catch (e) {
      if (_cancelled) {
        _emit(
          _progress.copyWith(
            phase: ExportPhase.idle,
            message: '已取消导出',
            clearError: true,
          ),
        );
        return saved;
      }
      _emit(
        _progress.copyWith(
          phase: ExportPhase.error,
          message: '导出失败',
          error: '$e',
          savedPaths: List.unmodifiable(saved),
        ),
      );
      rethrow;
    } finally {
      await _teardownLink(closeDeviceWifi: true);
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    if (!(_wifiConfigCompleter?.isCompleted ?? true)) {
      _wifiConfigCompleter!.completeError(StateError('cancelled'));
    }
    if (!(_fileDone?.isCompleted ?? true)) {
      _fileDone!.complete();
    }
    _emit(_progress.copyWith(phase: ExportPhase.idle, message: '已取消导出'));
    // UI cancellation must not wait for a pending TLS handshake, WebSocket
    // close frame, or BLE write after the Wi-Fi handoff dropped GATT.
    unawaited(
      _teardownLink(closeDeviceWifi: true).catchError((Object e) {
        _log('cancel cleanup: $e');
      }),
    );
  }

  Future<void> closeSoftApOnly() async {
    try {
      await bleWrite(DeviceCommands.closeWifiMode());
    } catch (e) {
      _log('closeWifiMode failed: $e');
    }
  }

  Future<Directory> _exportDir() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder', 'exports'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _connectWs(WifiEndpoint ep, {required bool useSsl}) async {
    // Match the Soundcore SDK: retry the configured protocol three times, two
    // seconds apart. Port 443 is WSS; falling back to plain WS only adds long
    // waits and predictable connection resets.
    final schemes = [useSsl ? 'wss' : 'ws'];
    Object? lastErr;
    for (final scheme in schemes) {
      for (var attempt = 1; attempt <= 3; attempt++) {
        if (_cancelled) throw StateError('cancelled');
        final url = '$scheme://${ep.ip}:${ep.port}';
        _log('WS connect $url attempt $attempt/3');
        _emit(
          _progress.copyWith(
            phase: ExportPhase.connectingWs,
            message: '正在连接 WebSocket ${ep.displayEndpoint}…（$attempt/3）',
          ),
        );
        WebSocketChannel? candidate;
        HttpClient? client;
        try {
          client = HttpClient();
          client.badCertificateCallback = (cert, host, port) => true;
          client.connectionTimeout = const Duration(seconds: 12);
          _wsClient = client;
          final socket = connectSdkWebSocket(url, client);
          candidate = IOWebSocketChannel(socket);
          _ws = candidate;
          await Future.any<void>([
            candidate.ready.timeout(webSocketReadyTimeout),
            _cancelSignal.future,
          ]);
          if (_cancelled) throw StateError('cancelled');
          _rxBuffer.clear();
          _wsSub = candidate.stream.listen(
            _onWsData,
            onError: (e) => _log('WS error: $e'),
            onDone: () => _log('WS closed'),
            cancelOnError: false,
          );
          _log('WS connected via $url');
          return;
        } catch (e) {
          lastErr = e;
          _log('WS $url attempt $attempt failed: $e');
          try {
            await candidate?.sink.close().timeout(const Duration(seconds: 1));
          } catch (_) {}
          client?.close(force: true);
          if (identical(_wsClient, client)) _wsClient = null;
          if (identical(_ws, candidate)) _ws = null;
          if (_cancelled) throw StateError('cancelled');
          if (attempt < 3) {
            await Future.any<void>([
              Future<void>.delayed(webSocketRetryDelay),
              _cancelSignal.future,
            ]);
            if (_cancelled) throw StateError('cancelled');
          }
        }
      }
    }
    throw StateError('WebSocket connect failed: $lastErr');
  }

  void _startUdpKeepalive(String ip) {
    () async {
      try {
        _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final addr = InternetAddress(ip);
        final payload = utf8.encode('soundcore-keep-alive-unicast');
        void ping() {
          try {
            _udp?.send(payload, addr, 32003);
          } catch (e) {
            _log('UDP ping fail: $e');
          }
        }

        ping();
        _udpTimer = Timer.periodic(const Duration(seconds: 2), (_) => ping());
      } catch (e) {
        _log('UDP keepalive unavailable: $e');
      }
    }();
  }

  void _onWsData(dynamic data) {
    if (data is String) {
      final t = data.trim();
      if (t.toUpperCase() == 'ACK' ||
          t.toUpperCase() == 'OK' ||
          t.toUpperCase() == 'PONG') {
        return;
      }
      // Some stacks may echo hex text; ignore short control strings.
      if (t.length < 20 && !t.startsWith('09')) {
        _log('WS text: $t');
        return;
      }
      // Hex-encoded binary frame as text
      try {
        final bytes = _hexToBytes(t);
        if (bytes != null) _ingestBytes(bytes);
      } catch (e) {
        _log('WS text parse: $e');
      }
      return;
    }
    if (data is List<int>) {
      _ingestBytes(data);
    } else if (data is Uint8List) {
      _ingestBytes(data);
    }
  }

  void _ingestBytes(List<int> chunk) {
    _rxBuffer.addAll(chunk);
    final packets = ProtocolFrame.processBuffer(_rxBuffer);
    for (final pkt in packets) {
      _handleTransportPacket(pkt);
    }
  }

  void _handleTransportPacket(DecodedPacket pkt) {
    if (pkt.cmdType != RxCmd.transportType &&
        pkt.cmdType != RxCmd.transportTypeAlt) {
      return;
    }

    if (pkt.cmdId == RxCmd.fileHeadId) {
      final head = FileHeadInfo.parse(pkt);
      _log('File head: $head');
      _setupDecryptor(head, pkt.raw);
      if (!(_fileHead?.isCompleted ?? true)) {
        _fileHead!.complete(head);
      }
      if (head.fileSize > 0) {
        _expectedSize = head.fileSize;
        _emit(_progress.copyWith(bytesExpected: head.fileSize));
      }
      return;
    }

    if (pkt.cmdId == RxCmd.fileSliceId || pkt.cmdId == RxCmd.fileSliceMarkId) {
      _writeSlices(pkt.raw);
      return;
    }

    if (pkt.cmdId == RxCmd.fileDoneId) {
      _log('File done signal');
      if (!(_fileDone?.isCompleted ?? true)) {
        _fileDone!.complete();
      }
    }
  }

  void _setupDecryptor(FileHeadInfo head, Uint8List raw) {
    final secret = AudioFileSecretKey.parseFrame(raw);
    if (secret == null) {
      _log('File head too short for keys — writing raw chunks');
      _decryptEnabled = false;
      return;
    }
    final id = '${secret.fileId}';
    _activeFileId = id;
    final ok = crypto.initFileDecrypt(
      fileId: id,
      encryptedFileKey: secret.encryptedFileKey,
      sessionNonce: secret.sessionNonce,
      nonce: secret.nonce,
    );
    _decryptEnabled = ok;
    if (!ok) {
      _log('Decrypt init failed (session=${crypto.hasSession}) — raw fallback');
    } else {
      _log('Decrypt ready for file $id');
    }
  }

  void _writeSlices(Uint8List frame) {
    // Layout after offset 9: repeated [seq u32 LE][flags u8][160 data][pad u8?]
    // Feishu processes 166-byte units while length allows.
    var i = 9;
    final fileId = _activeFileId;
    while (frame.length - i >= 165) {
      final seq = readU32Le(frame, i);
      i += 4;
      // flags
      i += 1;
      final dataEnd = i + 160;
      if (dataEnd > frame.length) break;
      final chunk = Uint8List.fromList(frame.sublist(i, dataEnd));
      i = dataEnd;
      // optional trailing pad byte in 166-unit stride
      if (i < frame.length) {
        i += 1;
      }

      Uint8List out = chunk;
      if (_decryptEnabled && fileId != null) {
        final plain = crypto.decryptChunk(
          fileId: fileId,
          sequence: seq,
          data: chunk,
        );
        if (plain != null) {
          out = plain;
          _decryptedChunks++;
        } else {
          _rawFallbackChunks++;
        }
      }

      _fileSink?.add(out);
      _sliceBytes += out.length;
      _emit(
        _progress.copyWith(
          bytesReceived: _sliceBytes,
          bytesExpected: _expectedSize > 0
              ? _expectedSize
              : _progress.bytesExpected,
        ),
      );
    }
  }

  Future<String?> _transferOne(OfflineFileEntry file, Directory outDir) async {
    // Prefer .opus when decrypting; keep .bin suffix if forced raw.
    final baseName = '${file.fileId}';
    final pathOpus = p.join(outDir.path, '$baseName.opus');
    final pathRaw = p.join(outDir.path, '$baseName.opus.bin');
    // Start as opus; rename if we never decrypted.
    var path = pathOpus;
    final ioFile = File(path);
    _fileSink = ioFile.openWrite();
    _sliceBytes = 0;
    _expectedSize = file.sizeBytes;
    _fileHead = Completer<FileHeadInfo>();
    _fileDone = Completer<void>();
    _activeFileId = '${file.fileId}';
    _decryptEnabled = crypto.hasFileDecryptor(_activeFileId!);
    _decryptedChunks = 0;
    _rawFallbackChunks = 0;

    try {
      // Match Feishu WiFiWebSocketManager.buildFileHeaderRequestCommand:
      // fixed 18-byte frame hex (no trailing checksum byte; last payload = 0x1B).
      final reqHex = _buildFileHeaderRequestHex(
        fileId: file.fileId,
        transferredSize: 0,
      );
      _ws?.sink.add(reqHex);
      _log('Requested file ${file.fileId}');

      // Wait for header (optional — some firmwares stream immediately)
      try {
        final head = await _fileHead!.future.timeout(
          const Duration(seconds: 20),
        );
        if (head.errorCode != 0 && head.errorCode != 0xFF) {
          // Feishu treats code 1 = not exists, 2 = local error, 3 = already complete
          if (head.errorCode == 1) {
            throw StateError('设备上找不到文件 ${file.fileId}');
          }
          if (head.errorCode == 3) {
            _log('File already complete on device side');
          }
        }
        if (head.fileSize > 0) _expectedSize = head.fileSize;
      } on TimeoutException {
        _log('No file header in 20s — still waiting for slices/done');
      }

      // Wait for completion: either 1A0A or enough bytes
      final deadline = DateTime.now().add(
        Duration(seconds: 30 + (_expectedSize ~/ 8000).clamp(10, 600)),
      );
      while (!_cancelled && DateTime.now().isBefore(deadline)) {
        if (_fileDone?.isCompleted == true) break;
        if (_expectedSize > 0 && _sliceBytes >= _expectedSize) break;
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      if (_fileDone?.isCompleted != true &&
          !(_expectedSize > 0 && _sliceBytes >= _expectedSize * 0.95)) {
        if (_sliceBytes == 0) {
          throw StateError(
            '未收到文件 ${file.fileId} 的数据。'
            '请确认已加入 SoftAP ${_progress.ssid ?? ""}。',
          );
        }
        _log('Partial receive $_sliceBytes/$_expectedSize — saving anyway');
      }

      await _fileSink?.flush();
      await _fileSink?.close();
      _fileSink = null;

      if (_sliceBytes == 0) {
        try {
          await ioFile.delete();
        } catch (_) {}
        return null;
      }

      // If nothing decrypted, rename to .bin so it's obvious.
      if (_decryptedChunks == 0 && _rawFallbackChunks > 0) {
        final rawFile = File(pathRaw);
        if (await ioFile.exists()) {
          await ioFile.rename(pathRaw);
          path = pathRaw;
        } else if (await rawFile.exists()) {
          path = pathRaw;
        }
        _log('Saved raw (no decrypt) → $path');
      } else {
        _log(
          'Saved decrypted $_decryptedChunks chunks'
          '${_rawFallbackChunks > 0 ? " (+$_rawFallbackChunks raw)" : ""} → $path',
        );
      }
      if (_activeFileId != null) crypto.clearFile(_activeFileId!);
      return path;
    } catch (e) {
      try {
        await _fileSink?.close();
      } catch (_) {}
      _fileSink = null;
      if (_activeFileId != null) crypto.clearFile(_activeFileId!);
      rethrow;
    }
  }

  /// Feishu hex text for file header request (18 bytes, no separate checksum).
  static String _buildFileHeaderRequestHex({
    required int fileId,
    required int transferredSize,
  }) {
    final bytes = <int>[
      0x08,
      0xEE,
      0x00,
      0x00,
      0x00,
      0x1A,
      0x07,
      0x12,
      0x00,
      ...u32Le(transferredSize),
      ...u32Le(fileId),
      0x1B,
    ];
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Feishu transfer-complete (1A0A) as hex text.
  static String _buildTransferCompleteHex() {
    final body = <int>[
      0x08,
      0xEE,
      0x00,
      0x00,
      0x00,
      0x1A,
      0x0A,
      0x0B,
      0x00,
      0x01,
    ];
    var sum = 0;
    for (final b in body) {
      sum = (sum + b) & 0xFF;
    }
    body.add(sum);
    return body.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List? _hexToBytes(String hex) {
    final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.length < 20 || cleaned.length.isOdd) return null;
    final out = Uint8List(cleaned.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  Future<void> _teardownLink({required bool closeDeviceWifi}) async {
    _udpTimer?.cancel();
    _udpTimer = null;
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;

    final wsSub = _wsSub;
    _wsSub = null;
    final ws = _ws;
    _ws = null;
    final wsClient = _wsClient;
    _wsClient = null;
    // Force-closing the client interrupts a pending DNS/TCP/TLS handshake.
    wsClient?.close(force: true);
    try {
      await wsSub?.cancel().timeout(const Duration(seconds: 1));
    } catch (_) {}
    try {
      await ws?.sink.close().timeout(const Duration(seconds: 1));
    } catch (_) {}

    if (closeDeviceWifi) {
      try {
        await bleWrite(
          DeviceCommands.closeWifiMode(),
        ).timeout(const Duration(seconds: 1));
      } catch (e) {
        _log('closeWifiMode: $e');
      }
    }

    await _bleSub?.cancel();
    _bleSub = null;
  }

  Future<void> dispose() async {
    await cancel();
    await _progressController.close();
  }
}

class FileHeadInfo {
  FileHeadInfo({
    required this.fileId,
    required this.fileSize,
    this.errorCode = 0,
    this.hasKeys = false,
  });

  final int fileId;
  final int fileSize;
  final int errorCode;
  final bool hasKeys;

  /// From full frame: timestamp @9, size @13, error @95 when long enough.
  factory FileHeadInfo.parse(DecodedPacket p) {
    final raw = p.raw;
    if (raw.length < 17) {
      return FileHeadInfo(fileId: 0, fileSize: 0, errorCode: -1);
    }
    final fileId = readU32Le(raw, 9);
    final fileSize = readU32Le(raw, 13);
    var err = 0;
    if (raw.length > 95) {
      err = raw[95] & 0xFF;
    }
    return FileHeadInfo(
      fileId: fileId,
      fileSize: fileSize,
      errorCode: err,
      hasKeys: raw.length >= 97,
    );
  }

  @override
  String toString() =>
      'FileHeadInfo(id=$fileId, size=$fileSize, err=$errorCode, keys=$hasKeys)';
}
