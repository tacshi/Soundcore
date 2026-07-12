import 'dart:io';
import 'dart:typed_data';

import 'ogg_opus.dart';
import 'opus_pcm_decoder.dart';

/// Converts the D3200's raw fixed-size Opus frames to a standard PCM WAV file.
class OpusWave {
  OpusWave._();

  static const sampleRate = 48000;
  static const channels = 1;
  static const bitsPerSample = 16;

  static Future<String> convertRawFile(String path) async {
    if (path.endsWith('.wav')) return path;
    if (path.endsWith('.opus.bin')) {
      throw StateError('加密的原始文件无法转换');
    }

    final source = File(path);
    if (!await source.exists()) throw StateError('文件不存在：$path');
    final raw = await source.readAsBytes();
    if (raw.isEmpty) throw StateError('文件为空');
    if (OggOpus.isOgg(raw)) throw StateError('需要原始 Opus 帧');

    final decoder = OpusPcmDecoder(outputSampleRate: sampleRate);
    try {
      final pcm = decoder.decodeRawFileBytes(raw);
      if (pcm == null || pcm.isEmpty) throw StateError('Opus 解码失败');
      final wavPath = path.endsWith('.opus')
          ? '${path.substring(0, path.length - 5)}.wav'
          : '$path.wav';
      await File(wavPath).writeAsBytes(_wrapPcm(pcm), flush: true);
      return wavPath;
    } finally {
      decoder.dispose();
    }
  }

  static Uint8List _wrapPcm(Uint8List pcm) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(44);
    _ascii(header, 0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    _ascii(header, 8, 'WAVE');
    _ascii(header, 12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    _ascii(header, 36, 'data');
    header.setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
  }

  static void _ascii(ByteData data, int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
}
