import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anker_recorder/ble/ble_service.dart';
import 'package:anker_recorder/crypto/btsnoop_parser.dart';
import 'package:anker_recorder/crypto/device_crypto.dart';
import 'package:anker_recorder/protocol/commands.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/device_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sampleAccountId = '0123456789abcdef0123456789abcdef01234567';

  group('DeviceCrypto binding & 0B/8B auth', () {
    test('buildAuthPayload builds 62-byte AES-256-CTR frame and round-trips', () {
      final sharedSecret = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final bindingKey = DeviceCrypto.deriveBindingKey(sharedSecret);
      expect(bindingKey.length, 32);

      final nonce = Uint8List.fromList(List.generate(16, (i) => 0xA0 + i));
      const ts = 0x67123456;
      final payload = DeviceCrypto.buildAuthPayload(
        accountId: sampleAccountId,
        bindingKey: bindingKey,
        timestampSeconds: ts,
        nonce: nonce,
      );
      expect(payload, isNotNull);
      expect(payload!.length, 62);
      expect(payload[0], 0x2C); // 44 bytes ciphertext
      expect(payload[45], 0x10); // 16 bytes nonce
      expect(payload.sublist(46, 62), nonce);

      final ct = payload.sublist(1, 45);
      final plain = DeviceCrypto.aesCtrDecrypt(
        data: ct,
        key: bindingKey,
        iv: nonce,
      )!;
      expect(ascii.decode(plain.sublist(0, 40)), sampleAccountId);
      expect(readU32Le(plain, 40), ts);
    });

    test('BindConfirmPayload parses 0B/88 and rejects short legacy payloads', () {
      final devPair = DeviceCrypto.generateKeyPair();
      final shared = Uint8List.fromList(List.generate(32, (i) => 0x50 + i));
      final rawPayload = Uint8List.fromList([
        0x01,
        0x41,
        ...devPair.publicKey,
        0x20,
        ...shared,
      ]);
      final parsed = BindConfirmPayload.parse(rawPayload);
      expect(parsed, isNotNull);
      expect(parsed!.flag, 0x01);
      expect(parsed.devicePublicKey, devPair.publicKey);
      expect(parsed.sharedSecret, shared);
      expect(
        parsed.deriveBindingKey(),
        DeviceCrypto.deriveBindingKey(shared),
      );

      expect(BindConfirmPayload.parse(Uint8List.fromList([0x01])), isNull);
    });

    test('DeviceCommands encodes 0B/03, extended 0B/87, and 0B/8B', () {
      final emailFrame = DeviceCommands.sendAccount('user@example.com');
      expect(ProtocolFrame.verifyChecksum(emailFrame), isTrue);
      expect(emailFrame[5], 0x0B);
      expect(emailFrame[6], 0x03);
      expect(emailFrame[9], 'user@example.com'.length);

      final pair = DeviceCrypto.generateKeyPair();
      final bindFrame = DeviceCommands.bindWithKey(
        accountId: sampleAccountId,
        publicKey: pair.publicKey,
        timestampSeconds: 1700000000,
      );
      expect(ProtocolFrame.verifyChecksum(bindFrame), isTrue);
      expect(bindFrame[5], 0x0B);
      expect(bindFrame[6], 0x87);
      // Payload: [01][40][id_40B][ts_4B][65][pub_65B] = 112B -> total 122B
      expect(bindFrame.length, 10 + 112);
      expect(bindFrame[9], 0x01);
      expect(bindFrame[10], 40);
      expect(bindFrame[9 + 2 + 40 + 4], 0x41);

      final authPayload = Uint8List(62);
      final authFrame = DeviceCommands.authenticate(authPayload);
      expect(ProtocolFrame.verifyChecksum(authFrame), isTrue);
      expect(authFrame[5], 0x0B);
      expect(authFrame[6], 0x8B);
      expect(authFrame.length, 72);
    });
  });

  group('BtsnoopParser', () {
    test('extracts accountId, email, and shared secret from fragmented btsnoop', () {
      final appPair = DeviceCrypto.generateKeyPair();
      final devPair = DeviceCrypto.generateKeyPair();
      final shared = DeviceCrypto.computeSharedSecret(
        appPair.privateKey,
        devPair.publicKey,
      )!;

      final txEmail = DeviceCommands.sendAccount('alice@example.com');
      final txBind = DeviceCommands.bindWithKey(
        accountId: sampleAccountId,
        publicKey: appPair.publicKey,
        timestampSeconds: 1700000123,
      );
      final rxBindConfirm = _rxFrame(
        cmdType: 0x0B,
        cmdId: 0x88,
        payload: [0x01, 0x41, ...devPair.publicKey, 0x20, ...shared],
      );

      final btsnoop = _buildBtsnoopH4([
        ..._attChunks(txEmail, isRx: false, attHandle: 0x0012, mtuChunk: 20),
        ..._attChunks(txBind, isRx: false, attHandle: 0x0012, mtuChunk: 20),
        ..._attChunks(
          rxBindConfirm,
          isRx: true,
          attHandle: 0x0015,
          mtuChunk: 20,
        ),
      ]);

      final extracted = BtsnoopParser.extract(btsnoop);
      expect(extracted.isComplete, isTrue);
      expect(extracted.accountId, sampleAccountId);
      expect(extracted.email, 'alice@example.com');
      expect(extracted.sharedSecret, shared);
      expect(extracted.bindingKey, DeviceCrypto.deriveBindingKey(shared));
    });
  });

  group('RecorderController 0B/87 & 0B/8B flows', () {
    test('authenticateSession sends 0B/03 + 0B/8B and handles 00 / FF / FD', () async {
      final ble = _FakeAuthBle();
      final controller = RecorderController(loadPersistedState: false, ble: ble)
        ..connected = true
        ..encryptReady = true
        ..phase = AppPhase.ready;
      addTearDown(() {
        controller.dispose();
        ble.close();
      });

      final shared = Uint8List.fromList(List.generate(32, (i) => i + 7));
      final creds = DeviceAuthCredentials.fromSharedSecret(
        accountId: sampleAccountId,
        sharedSecret: shared,
        email: 'bob@example.com',
      );
      await controller.saveAuthCredentials(creds, authenticateNow: false);

      // 1. Success (0x00)
      ble.nextAuthResult = 0x00;
      expect(await controller.authenticateSession(), isTrue);
      expect(controller.authState, DeviceAuthState.authenticated);
      expect(controller.authReady, isTrue);
      expect(ble.sentCmds, contains('0B/03'));
      expect(ble.sentCmds, contains('0B/8B'));

      // Verify the 0B/8B payload decrypts with the binding key.
      final authFrame = ble.lastFrame('0B/8B')!;
      final authPayload = authFrame.sublist(9, authFrame.length - 1);
      expect(authPayload.length, 62);
      final plain = DeviceCrypto.aesCtrDecrypt(
        data: authPayload.sublist(1, 45),
        key: creds.bindingKey!,
        iv: authPayload.sublist(46, 62),
      )!;
      expect(ascii.decode(plain.sublist(0, 40)), sampleAccountId);

      // 2. Rejected (0xFF)
      ble.nextAuthResult = 0xFF;
      expect(await controller.authenticateSession(), isFalse);
      expect(controller.authState, DeviceAuthState.failed);
      expect(controller.errorMessage, contains('0xFF'));

      // 3. No binding key on device (0xFD)
      ble.nextAuthResult = 0xFD;
      expect(await controller.authenticateSession(), isFalse);
      expect(controller.authState, DeviceAuthState.noBindingKey);
      expect(controller.errorMessage, contains('0xFD'));
    });

    test('bindDeviceWithKey completes 0B/87 -> 0B/88 and auto-authenticates', () async {
      final ble = _FakeAuthBle()..autoCompleteBind = true;
      final controller = RecorderController(loadPersistedState: false, ble: ble)
        ..connected = true
        ..encryptReady = true
        ..phase = AppPhase.ready;
      addTearDown(() {
        controller.dispose();
        ble.close();
      });

      final ok = await controller.bindDeviceWithKey(accountId: sampleAccountId);
      expect(ok, isTrue);
      expect(controller.bound, isTrue);
      expect(controller.hasAuthCredentials, isTrue);
      expect(controller.authCredentials!.accountId, sampleAccountId);
      expect(controller.authState, DeviceAuthState.authenticated);
      expect(ble.sentCmds, containsAllInOrder(['0B/87', '0B/8B', '01/A6']));
    });

    testWidgets('DeviceScreen displays firmware auth panel', (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = RecorderController(loadPersistedState: false)
        ..connected = true
        ..authState = DeviceAuthState.authenticated;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: DeviceScreen()),
        ),
      );

      expect(find.byKey(const ValueKey('device-auth-panel')), findsOneWidget);
      expect(find.text('已认证'), findsOneWidget);
      expect(find.text('密钥绑定'), findsOneWidget);
      expect(find.text('导入密钥'), findsOneWidget);
    });
  });
}

Uint8List _rxFrame({
  required int cmdType,
  required int cmdId,
  int status = 0x01,
  List<int> payload = const [],
}) {
  final totalLen = 10 + payload.length;
  final body = <int>[
    0x09,
    0xFF,
    0x00,
    0x00,
    status & 0xFF,
    cmdType & 0xFF,
    cmdId & 0xFF,
    totalLen & 0xFF,
    (totalLen >> 8) & 0xFF,
    ...payload,
  ];
  return Uint8List.fromList([...body, ProtocolFrame.checksum(body)]);
}

List<({bool isRx, Uint8List h4Packet})> _attChunks(
  Uint8List value, {
  required bool isRx,
  required int attHandle,
  int mtuChunk = 20,
  int connHandle = 0x0040,
}) {
  final out = <({bool isRx, Uint8List h4Packet})>[];
  for (var off = 0; off < value.length; off += mtuChunk) {
    final end = (off + mtuChunk > value.length) ? value.length : off + mtuChunk;
    final chunk = value.sublist(off, end);
    final att = Uint8List.fromList([
      isRx ? 0x1B : 0x52, // Notification vs Write Command
      attHandle & 0xFF,
      (attHandle >> 8) & 0xFF,
      ...chunk,
    ]);
    final l2cap = Uint8List.fromList([
      att.length & 0xFF,
      (att.length >> 8) & 0xFF,
      0x04,
      0x00, // ATT CID 0x0004
      ...att,
    ]);
    final aclHeader = Uint8List.fromList([
      0x02, // H4 ACL indicator
      connHandle & 0xFF,
      ((connHandle >> 8) & 0x0F) | (isRx ? 0x20 : 0x00), // PB=2 RX / 0 TX
      l2cap.length & 0xFF,
      (l2cap.length >> 8) & 0xFF,
    ]);
    out.add((isRx: isRx, h4Packet: Uint8List.fromList([...aclHeader, ...l2cap])));
  }
  return out;
}

Uint8List _buildBtsnoopH4(List<({bool isRx, Uint8List h4Packet})> records) {
  final out = BytesBuilder(copy: false);
  // RFC 1761 header: "btsnoop\0", version=1, datalink=1002 (H4)
  out.add([0x62, 0x74, 0x73, 0x6E, 0x6F, 0x6F, 0x70, 0x00]);
  final hdr = ByteData(8)
    ..setUint32(0, 1, Endian.big)
    ..setUint32(4, 1002, Endian.big);
  out.add(hdr.buffer.asUint8List());

  for (final r in records) {
    final rec = ByteData(24)
      ..setUint32(0, r.h4Packet.length, Endian.big)
      ..setUint32(4, r.h4Packet.length, Endian.big)
      ..setUint32(8, r.isRx ? 1 : 0, Endian.big)
      ..setUint32(12, 0, Endian.big)
      ..setUint64(16, 0, Endian.big);
    out.add(rec.buffer.asUint8List());
    out.add(r.h4Packet);
  }
  return out.toBytes();
}

class _FakeAuthBle extends BleService {
  final _packets = StreamController<DecodedPacket>.broadcast();
  final List<Uint8List> _sent = [];
  final List<String> sentCmds = [];
  int nextAuthResult = 0x00;
  bool autoCompleteBind = false;

  @override
  bool get isConnected => true;

  @override
  Stream<DecodedPacket> get packets => _packets.stream;

  Uint8List? lastFrame(String cmd) {
    for (var i = _sent.length - 1; i >= 0; i--) {
      if (sentCmds[i] == cmd) return _sent[i];
    }
    return null;
  }

  @override
  Future<void> writeCommand(List<int> frame) async {
    final bytes = Uint8List.fromList(frame);
    final cmd =
        '${bytes[5].toRadixString(16).padLeft(2, '0').toUpperCase()}/'
        '${bytes[6].toRadixString(16).padLeft(2, '0').toUpperCase()}';
    _sent.add(bytes);
    sentCmds.add(cmd);

    if (cmd == '0B/03') {
      scheduleMicrotask(() {
        _packets.add(
          DecodedPacket.fromBytes(
            _rxFrame(cmdType: 0x0B, cmdId: 0x03, payload: const [0xFF]),
          ),
        );
      });
    } else if (cmd == '0B/8B') {
      final result = nextAuthResult;
      scheduleMicrotask(() {
        _packets.add(
          DecodedPacket.fromBytes(
            _rxFrame(cmdType: 0x0B, cmdId: 0x8B, payload: [result]),
          ),
        );
      });
    } else if (cmd == '0B/87' && autoCompleteBind) {
      // Extract client pubkey from TX 0B/87 and reply with valid 0B/88 ECDH.
      final payload = bytes.sublist(9, bytes.length - 1);
      final idLen = payload[1] & 0xFF;
      final pubStart = 2 + idLen + 4 + 1;
      final clientPub = Uint8List.fromList(
        payload.sublist(pubStart, pubStart + 65),
      );
      final devPair = DeviceCrypto.generateKeyPair();
      final shared = DeviceCrypto.computeSharedSecret(
        devPair.privateKey,
        clientPub,
      )!;
      scheduleMicrotask(() {
        _packets.add(
          DecodedPacket.fromBytes(
            _rxFrame(cmdType: 0x0B, cmdId: 0x87, payload: const [0x00]),
          ),
        );
        _packets.add(
          DecodedPacket.fromBytes(
            _rxFrame(
              cmdType: 0x0B,
              cmdId: 0x88,
              payload: [0x01, 0x41, ...devPair.publicKey, 0x20, ...shared],
            ),
          ),
        );
      });
    } else if (cmd == '01/A6') {
      scheduleMicrotask(() {
        _packets.add(
          DecodedPacket.fromBytes(_rxFrame(cmdType: 0x01, cmdId: 0xA6)),
        );
      });
    }
  }

  void close() {
    unawaited(_packets.close());
  }
}
