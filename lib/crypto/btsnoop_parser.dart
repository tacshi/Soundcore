import 'dart:convert';
import 'dart:typed_data';

import '../protocol/commands.dart';
import '../protocol/frame.dart';
import 'device_crypto.dart';

/// Binding credentials recovered from an Android `btsnoop_hci.log` (or raw
/// captured BLE traffic) during a `0B/87 → 0B/88` pairing exchange.
class ExtractedBindingCredentials {
  const ExtractedBindingCredentials({
    this.accountId,
    this.email,
    this.sharedSecret,
    this.bindingKey,
  });

  final String? accountId;
  final String? email;
  final Uint8List? sharedSecret;
  final Uint8List? bindingKey;

  bool get hasBindingKey => bindingKey != null && bindingKey!.length == 32;
  bool get isComplete =>
      accountId != null && accountId!.trim().isNotEmpty && hasBindingKey;
}

/// Extracts soundcore Work (D3200) binding credentials (`0B/03` email,
/// `0B/87` account ID, and `0B/88` shared secret → HKDF binding key) from an
/// RFC 1761 `btsnoop_hci.log` file or raw BLE frame stream.
class BtsnoopParser {
  BtsnoopParser._();

  static const _magic = [0x62, 0x74, 0x73, 0x6E, 0x6F, 0x6F, 0x70, 0x00];
  static const _attCid = 0x0004;

  static ExtractedBindingCredentials extract(Uint8List bytes) {
    String? accountId;
    String? email;
    Uint8List? sharedSecret;

    if (_hasBtsnoopMagic(bytes)) {
      final streams = _extractAttStreams(bytes);
      for (final tx in streams.txStreams.values) {
        final found = _scanTxFrames(tx);
        if (found.accountId != null) accountId = found.accountId;
        if (found.email != null) email = found.email;
      }
      for (final rx in streams.rxStreams.values) {
        final secret = _scanRxFrames(rx);
        if (secret != null) sharedSecret = secret;
      }
    }

    // Fallback: scan raw bytes directly for complete checksummed frames.
    if (accountId == null || email == null) {
      final rawTx = _scanTxFrames(bytes);
      accountId ??= rawTx.accountId;
      email ??= rawTx.email;
    }
    sharedSecret ??= _scanRxFrames(bytes);

    final bindingKey = sharedSecret != null
        ? DeviceCrypto.deriveBindingKey(sharedSecret)
        : null;

    return ExtractedBindingCredentials(
      accountId: accountId,
      email: email,
      sharedSecret: sharedSecret,
      bindingKey: bindingKey,
    );
  }

  static bool _hasBtsnoopMagic(Uint8List bytes) {
    if (bytes.length < 16) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  static ({
    Map<int, Uint8List> txStreams,
    Map<int, Uint8List> rxStreams,
  }) _extractAttStreams(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final datalink = data.getUint32(12, Endian.big);

    final txBuilders = <int, BytesBuilder>{};
    final rxBuilders = <int, BytesBuilder>{};
    final l2capState = <int, _L2capReassembler>{};

    var offset = 16;
    while (offset + 24 <= bytes.length) {
      final incLen = data.getUint32(offset + 4, Endian.big);
      final flags = data.getUint32(offset + 8, Endian.big);
      offset += 24;
      if (incLen == 0 || offset + incLen > bytes.length) break;

      final pkt = Uint8List.sublistView(bytes, offset, offset + incLen);
      offset += incLen;

      final acl = _extractAclPayload(pkt, datalink: datalink, flags: flags);
      if (acl == null || acl.data.length < 4) continue;

      final aclHandleWord = (acl.data[0] & 0xFF) | ((acl.data[1] & 0xFF) << 8);
      final connHandle = aclHandleWord & 0x0FFF;
      final pbFlag = (aclHandleWord >> 12) & 0x03;
      final aclLen = (acl.data[2] & 0xFF) | ((acl.data[3] & 0xFF) << 8);
      if (4 + aclLen > acl.data.length) continue;

      final frag = Uint8List.sublistView(acl.data, 4, 4 + aclLen);
      final key = (connHandle << 1) | (acl.isRx ? 1 : 0);
      final reassembler = l2capState.putIfAbsent(key, _L2capReassembler.new);

      final sdu = reassembler.feed(pbFlag: pbFlag, fragment: frag);
      if (sdu == null || sdu.cid != _attCid || sdu.payload.length < 4) {
        continue;
      }

      final att = sdu.payload;
      final opcode = att[0] & 0xFF;
      final attHandle = (att[1] & 0xFF) | ((att[2] & 0xFF) << 8);
      final value = Uint8List.sublistView(att, 3);
      final streamKey = (connHandle << 16) | attHandle;

      // ATT Write Request (0x12) / Write Command (0x52) → host to device (TX)
      if (opcode == 0x12 || opcode == 0x52) {
        txBuilders
            .putIfAbsent(streamKey, () => BytesBuilder(copy: false))
            .add(value);
      } else if (opcode == 0x1B || opcode == 0x1D) {
        // ATT Handle Value Notification (0x1B) / Indication (0x1D) → RX
        rxBuilders
            .putIfAbsent(streamKey, () => BytesBuilder(copy: false))
            .add(value);
      }
    }

    return (
      txStreams: {for (final e in txBuilders.entries) e.key: e.value.toBytes()},
      rxStreams: {for (final e in rxBuilders.entries) e.key: e.value.toBytes()},
    );
  }

  static ({bool isRx, Uint8List data})? _extractAclPayload(
    Uint8List pkt, {
    required int datalink,
    required int flags,
  }) {
    final isRx = (flags & 0x01) != 0;
    if (datalink == 1002) {
      // H4 UART: first byte is packet indicator (0x02 = ACL Data).
      if (pkt.length < 5 || pkt[0] != 0x02) return null;
      return (isRx: isRx, data: Uint8List.sublistView(pkt, 1));
    }
    if (datalink == 1001) {
      // Unencapsulated HCI: flags bit 1 == 0 means ACL data.
      if ((flags & 0x02) != 0) return null;
      return (isRx: isRx, data: pkt);
    }
    if (datalink == 2001) {
      // Linux HCI Monitor: 4-byte header [adapter_u16_BE][opcode_u16_BE]
      // opcode 4 = ACL TX, 5 = ACL RX.
      if (pkt.length < 8) return null;
      final opcode = ((pkt[2] & 0xFF) << 8) | (pkt[3] & 0xFF);
      if (opcode != 4 && opcode != 5) return null;
      return (isRx: opcode == 5, data: Uint8List.sublistView(pkt, 4));
    }
    return null;
  }

  static ({String? accountId, String? email}) _scanTxFrames(Uint8List data) {
    String? accountId;
    String? email;
    var i = 0;
    while (i + 10 <= data.length) {
      if (data[i] != 0x08 ||
          data[i + 1] != 0xEE ||
          data[i + 2] != 0x00 ||
          data[i + 3] != 0x00 ||
          data[i + 4] != 0x00) {
        i++;
        continue;
      }
      final cmdType = data[i + 5] & 0xFF;
      final cmdId = data[i + 6] & 0xFF;
      final totalLen = (data[i + 7] & 0xFF) | ((data[i + 8] & 0xFF) << 8);
      if (totalLen < 10 || i + totalLen > data.length) {
        i++;
        continue;
      }
      final frame = Uint8List.sublistView(data, i, i + totalLen);
      if (!ProtocolFrame.verifyChecksum(frame)) {
        i++;
        continue;
      }
      final payload = Uint8List.sublistView(frame, 9, frame.length - 1);
      if (cmdType == RxCmd.bindType && cmdId == RxCmd.accountId) {
        // 0B/03: [len_1B] [email_ASCII]
        if (payload.isNotEmpty) {
          final len = payload[0] & 0xFF;
          if (len > 0 && payload.length >= 1 + len) {
            final parsed = utf8
                .decode(payload.sublist(1, 1 + len), allowMalformed: true)
                .trim();
            if (parsed.isNotEmpty) email = parsed;
          }
        }
      } else if (cmdType == RxCmd.bindType && cmdId == RxCmd.bindResultId) {
        // 0B/87: [01] [len_accountId] [accountId] [ts_4B] [0x41] [pubkey_65B]
        if (payload.length >= 2 + 1 + 4 + 1 + 65 && payload[0] == 0x01) {
          final idLen = payload[1] & 0xFF;
          final pubLenOff = 2 + idLen + 4;
          if (idLen > 0 &&
              payload.length >= pubLenOff + 1 + 65 &&
              payload[pubLenOff] == 0x41) {
            final parsed = ascii
                .decode(payload.sublist(2, 2 + idLen), allowInvalid: true)
                .trim();
            if (parsed.isNotEmpty) accountId = parsed;
          }
        }
      }
      i += totalLen;
    }
    return (accountId: accountId, email: email);
  }

  static Uint8List? _scanRxFrames(Uint8List data) {
    final buffer = List<int>.from(data);
    final packets = ProtocolFrame.processBuffer(buffer);
    Uint8List? sharedSecret;
    for (final p in packets) {
      if (p.cmdType == RxCmd.bindType && p.cmdId == RxCmd.bindConfirmId) {
        final confirm = BindConfirmPayload.parse(p.payload);
        if (confirm != null) {
          sharedSecret = confirm.sharedSecret;
        }
      }
    }
    return sharedSecret;
  }
}

class _L2capReassembler {
  int _expectedLen = 0;
  int _cid = 0;
  BytesBuilder? _buf;

  ({int cid, Uint8List payload})? feed({
    required int pbFlag,
    required Uint8List fragment,
  }) {
    if (pbFlag == 0x00 || pbFlag == 0x02) {
      // First packet of L2CAP PDU: [len_u16_LE][cid_u16_LE][payload...]
      if (fragment.length < 4) return null;
      _expectedLen = (fragment[0] & 0xFF) | ((fragment[1] & 0xFF) << 8);
      _cid = (fragment[2] & 0xFF) | ((fragment[3] & 0xFF) << 8);
      _buf = BytesBuilder(copy: false)..add(Uint8List.sublistView(fragment, 4));
    } else if (pbFlag == 0x01) {
      // Continuing fragment.
      if (_buf == null) return null;
      _buf!.add(fragment);
    } else {
      return null;
    }

    if (_buf != null && _buf!.length >= _expectedLen && _expectedLen > 0) {
      final raw = _buf!.toBytes();
      final payload = raw.length == _expectedLen
          ? raw
          : Uint8List.sublistView(raw, 0, _expectedLen);
      final cid = _cid;
      _buf = null;
      _expectedLen = 0;
      _cid = 0;
      return (cid: cid, payload: payload);
    }
    return null;
  }
}
