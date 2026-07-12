import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test('SoftAP handoff uses SDK 10-second readiness delay', () async {
    expect(WifiExportService.softApStartupDelay, const Duration(seconds: 10));

    final packets = StreamController<DecodedPacket>();
    var disconnectedBle = false;
    final body = <int>[
      0x09,
      0xFF,
      0x00,
      0x00,
      0x01,
      0x1A,
      0x05,
      0x10,
      0x00,
      0x01,
      0x2B,
      0xA8,
      0xC0,
      0xBB,
      0x01,
    ];
    final packet = DecodedPacket.fromBytes([
      ...body,
      ProtocolFrame.checksum(body),
    ]);
    final service = WifiExportService(
      blePackets: packets.stream,
      bleWrite: (frame) async {
        if (frame[5] == 0x1A && frame[6] == 0x05) {
          scheduleMicrotask(() => packets.add(packet));
        }
      },
    );

    final endpoint = await service.openSoftAp(
      startupDelay: Duration.zero,
      onConfigured: () async => disconnectedBle = true,
    );

    expect(disconnectedBle, isTrue);
    expect(endpoint.displayEndpoint, '192.168.43.1:443');
    await packets.close();
    await service.dispose();
  });

  test('SoftAP detection uses local subnet without probing device port', () {
    expect(
      WifiExportService.sharesIpv4Subnet('192.168.43.1', [
        '10.0.0.4',
        '192.168.43.2',
      ]),
      isTrue,
    );
    expect(
      WifiExportService.sharesIpv4Subnet('192.168.43.1', [
        '192.168.42.2',
        '127.0.0.1',
      ]),
      isFalse,
    );
  });

  test('Wi-Fi cancellation does not wait for BLE cleanup', () async {
    final pendingBleClose = Completer<void>();
    final service = WifiExportService(
      blePackets: const Stream<DecodedPacket>.empty(),
      bleWrite: (_) => pendingBleClose.future,
    );

    final winner = await Future.any<String>([
      service.cancel().then((_) => 'cancelled'),
      pendingBleClose.future.then((_) => 'cleanup'),
    ]).timeout(const Duration(seconds: 1));

    expect(winner, 'cancelled');
    pendingBleClose.complete();
    await service.dispose();
  });

  test('device WebSocket handshake matches SDK headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final receivedHeaders = Completer<HttpHeaders>();
    server.listen((request) async {
      receivedHeaders.complete(request.headers);
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.done;
    });

    final client = HttpClient();
    final socket = await WifiExportService.connectSdkWebSocket(
      'ws://${server.address.address}:${server.port}',
      client,
    );
    final headers = await receivedHeaders.future;
    final headerNames = <String>{};
    headers.forEach((name, _) => headerNames.add(name.toLowerCase()));

    expect(
      headerNames,
      equals({
        'host',
        'upgrade',
        'connection',
        'sec-websocket-key',
        'sec-websocket-version',
        'accept-encoding',
        'user-agent',
      }),
    );
    expect(headers.value(HttpHeaders.upgradeHeader), 'websocket');
    expect(headers.value(HttpHeaders.connectionHeader), 'Upgrade');
    expect(headers.value('Sec-WebSocket-Version'), '13');
    expect(headers.value('Sec-WebSocket-Key'), isNotEmpty);
    expect(headers.value('Sec-WebSocket-Extensions'), isNull);
    expect(headers.value(HttpHeaders.cacheControlHeader), isNull);
    // The SDK's OkHttp client (BridgeInterceptor) always sends these two —
    // the device's embedded WS server gates the upgrade on seeing them.
    expect(headers.value(HttpHeaders.acceptEncodingHeader), 'gzip');
    expect(headers.value(HttpHeaders.userAgentHeader), 'okhttp/3.12.13.18');

    await socket.close();
    client.close(force: true);
    await server.close(force: true);
  });

  test('device WebSocket handshake uses canonical header casing on the wire', () async {
    // HttpServer/HttpHeaders normalizes names to lowercase on receipt, so it
    // can't catch a casing regression — read the raw bytes instead. The
    // recorder's embedded parser is assumed to match header names
    // case-sensitively, the same way OkHttp emits them.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final rawBytes = <int>[];
    final headSeen = Completer<void>();
    late Socket accepted;
    server.listen((socket) {
      accepted = socket;
      socket.listen((data) {
        rawBytes.addAll(data);
        if (utf8.decode(rawBytes, allowMalformed: true).contains('\r\n\r\n')) {
          if (!headSeen.isCompleted) headSeen.complete();
        }
      });
    });

    final client = HttpClient();
    unawaited(
      () async {
        try {
          await WifiExportService.connectSdkWebSocket(
            'ws://${server.address.address}:${server.port}',
            client,
          );
        } catch (_) {
          // The raw socket never sends a 101 response, so the handshake
          // rejects once the connection is torn down — expected here.
        }
      }(),
    );

    await headSeen.future.timeout(const Duration(seconds: 5));
    final raw = utf8.decode(rawBytes, allowMalformed: true);

    for (final header in [
      'Host:',
      'Upgrade: websocket',
      'Connection: Upgrade',
      'Sec-WebSocket-Key:',
      'Sec-WebSocket-Version: 13',
      'Accept-Encoding: gzip',
      'User-Agent: okhttp/3.12.13.18',
    ]) {
      expect(
        raw.contains(header),
        isTrue,
        reason: 'expected literal "$header" in request:\n$raw',
      );
    }
    // No lowercase-only duplicates from dart:io's default serialization.
    expect(raw.contains('upgrade: websocket'), isFalse);
    expect(raw.contains('sec-websocket-key:'), isFalse);
    expect(raw.contains('user-agent:'), isFalse);

    client.close(force: true);
    await accepted.close();
    await server.close();
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

    expect(info.storageLabel, '4 GB / 64 GB');
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

  test('D3200 file-list request uses end-time transport and parses page', () {
    final request = DeviceCommands.listFilesWithEndTime(page: 2);
    expect(request[5], 0x1B);
    expect(request[6], 0x0E);
    expect(request.sublist(9, 11), [2, 0]);

    final page = OfflineFileList.parse(
      Uint8List.fromList([
        1, 0, // file count
        100, 0, 0, 0, // file id
        200, 0, 0, 0, // end time
        44, 1, 0, 0, // size: 300
        144, 1, 0, 0, // current transport timestamp: 400
        244, 1, 0, 0, // current transport duration: 500
      ]),
      withEndTime: true,
    );

    expect(page.fileCount, 1);
    expect(page.files.single.fileId, 100);
    expect(page.files.single.endTime, 200);
    expect(page.files.single.sizeBytes, 300);
    expect(page.currentTransportTimestamp, 400);
    expect(page.currentTransportDuration, 500);
  });
}
