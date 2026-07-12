import 'dart:typed_data';

/// Binary framing for soundcore Work / D3200 (see PROTOCOL.md §4).
class ProtocolFrame {
  ProtocolFrame._();

  static const List<int> txMagic = [0x08, 0xEE, 0x00, 0x00, 0x00];
  static const List<int> rxMagic = [0x09, 0xFF, 0x00, 0x00];

  /// Build phone → device command.
  ///
  /// Layout:
  /// `08 EE 00 00 00 | cmdType | cmdId | len_lo | len_hi | [payload...] | checksum`
  static Uint8List encode({
    required int cmdType,
    required int cmdId,
    List<int> payload = const [],
  }) {
    final bodyLen =
        5 + 2 + 2 + payload.length + 1; // magic+type+id + len + payload + csum
    final out = BytesBuilder(copy: false);
    out.add(txMagic);
    out.addByte(cmdType & 0xFF);
    out.addByte(cmdId & 0xFF);
    out.addByte(bodyLen & 0xFF);
    out.addByte((bodyLen >> 8) & 0xFF);
    if (payload.isNotEmpty) {
      out.add(payload);
    }
    final withoutCsum = out.toBytes();
    final csum = checksum(withoutCsum);
    return Uint8List.fromList([...withoutCsum, csum]);
  }

  static int checksum(List<int> data) {
    var sum = 0;
    for (final b in data) {
      sum = (sum + (b & 0xFF)) & 0xFF;
    }
    return sum;
  }

  static bool verifyChecksum(List<int> packet) {
    if (packet.length < 2) return false;
    final expected = packet.last & 0xFF;
    return checksum(packet.sublist(0, packet.length - 1)) == expected;
  }

  static bool isRxHeader(List<int> data, [int offset = 0]) {
    if (data.length < offset + 4) return false;
    return data[offset] == 0x09 &&
        data[offset + 1] == 0xFF &&
        data[offset + 2] == 0x00 &&
        data[offset + 3] == 0x00;
  }

  /// Reassemble complete RX packets from a stream buffer.
  static List<DecodedPacket> processBuffer(List<int> buffer) {
    final results = <DecodedPacket>[];
    var i = 0;
    while (i + 10 <= buffer.length) {
      // hunt for header
      var found = -1;
      for (var j = i; j <= buffer.length - 10; j++) {
        if (isRxHeader(buffer, j)) {
          found = j;
          break;
        }
      }
      if (found < 0) break;
      i = found;
      if (i + 9 > buffer.length) break;
      final totalLen = (buffer[i + 7] & 0xFF) | ((buffer[i + 8] & 0xFF) << 8);
      if (totalLen < 10) {
        i++;
        continue;
      }
      if (i + totalLen > buffer.length) break; // incomplete
      final slice = buffer.sublist(i, i + totalLen);
      if (verifyChecksum(slice)) {
        results.add(DecodedPacket.fromBytes(slice));
      }
      i += totalLen;
    }
    // compact consumed
    if (i > 0 && i <= buffer.length) {
      buffer.removeRange(0, i);
    }
    return results;
  }
}

class DecodedPacket {
  DecodedPacket({
    required this.raw,
    required this.statusByte,
    required this.cmdType,
    required this.cmdId,
    required this.payload,
  });

  final Uint8List raw;
  final int statusByte;
  final int cmdType;
  final int cmdId;
  final Uint8List payload;

  int get successFlag => statusByte & 0x0F;
  int get highNibble => (statusByte & 0xF0) >> 4;
  bool get isSuccess => successFlag == 1 || statusByte == 1;

  factory DecodedPacket.fromBytes(List<int> bytes) {
    final raw = Uint8List.fromList(bytes);
    final payload = bytes.length > 10
        ? Uint8List.fromList(bytes.sublist(9, bytes.length - 1))
        : Uint8List(0);
    return DecodedPacket(
      raw: raw,
      statusByte: bytes[4] & 0xFF,
      cmdType: bytes[5] & 0xFF,
      cmdId: bytes[6] & 0xFF,
      payload: payload,
    );
  }

  @override
  String toString() =>
      'Packet(type=0x${cmdType.toRadixString(16)}, id=0x${cmdId.toRadixString(16)}, '
      'ok=$isSuccess, payload=${payload.length}B)';
}

extension ByteHelpers on List<int> {
  String toHex([String sep = ' ']) => map(
    (b) => (b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase(),
  ).join(sep);
}

int readU16Le(List<int> b, int o) => (b[o] & 0xFF) | ((b[o + 1] & 0xFF) << 8);

int readU32Le(List<int> b, int o) =>
    (b[o] & 0xFF) |
    ((b[o + 1] & 0xFF) << 8) |
    ((b[o + 2] & 0xFF) << 16) |
    ((b[o + 3] & 0xFF) << 24);

Uint8List u16Le(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

Uint8List u32Le(int v) => Uint8List.fromList([
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
]);
