import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ogg_opus.dart';

/// Reads duration metadata from the local audio formats produced by the app.
class AudioDuration {
  AudioDuration._();

  static Future<Duration?> read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0) return null;

      final input = await file.open();
      try {
        final header = Uint8List.fromList(
          await input.read(math.min(length, 44)),
        );
        if (OggOpus.isWav(header)) {
          return _wavDuration(header, length);
        }
        if (OggOpus.isOgg(header)) {
          final tailLength = math.min(length, 64 * 1024);
          await input.setPosition(length - tailLength);
          return _oggDuration(Uint8List.fromList(await input.read(tailLength)));
        }
        if (path.endsWith('.opus') || path.endsWith('.opus.bin')) {
          final frames = (length + OggOpus.frameSize - 1) ~/ OggOpus.frameSize;
          return Duration(milliseconds: frames * 20);
        }
      } finally {
        await input.close();
      }
    } catch (_) {}
    return null;
  }

  static Duration? _wavDuration(Uint8List header, int fileLength) {
    if (header.length < 44) return null;
    final data = ByteData.sublistView(header);
    final byteRate = data.getUint32(28, Endian.little);
    if (byteRate <= 0) return null;
    final declaredDataLength = data.getUint32(40, Endian.little);
    final availableDataLength = math.max(0, fileLength - 44);
    final dataLength = math.min(declaredDataLength, availableDataLength);
    if (dataLength <= 0) return null;
    return Duration(
      microseconds: (dataLength * Duration.microsecondsPerSecond / byteRate)
          .round(),
    );
  }

  static Duration? _oggDuration(Uint8List tail) {
    final data = ByteData.sublistView(tail);
    for (var i = tail.length - 27; i >= 0; i--) {
      if (tail[i] != 0x4f ||
          tail[i + 1] != 0x67 ||
          tail[i + 2] != 0x67 ||
          tail[i + 3] != 0x53) {
        continue;
      }
      final granule = data.getUint64(i + 6, Endian.little);
      if (granule <= 0) continue;
      return Duration(
        microseconds:
            (granule * Duration.microsecondsPerSecond / OggOpus.sampleRate)
                .round(),
      );
    }
    return null;
  }
}
