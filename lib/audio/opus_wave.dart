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
    if (await source.length() == 0) throw StateError('文件为空');

    final input = await source.open();
    final prefix = await input.read(12);
    await input.setPosition(0);
    if (OggOpus.isOgg(prefix)) {
      await input.close();
      throw StateError('需要原始 Opus 帧');
    }

    final decoder = OpusPcmDecoder(outputSampleRate: sampleRate);
    final wavPath = path.endsWith('.opus')
        ? '${path.substring(0, path.length - 5)}.wav'
        : '$path.wav';
    final partial = File('$wavPath.part');
    final output = await partial.open(mode: FileMode.write);
    var completed = false;
    try {
      await output.writeFrom(_wavHeader(0));
      final pcmBatch = BytesBuilder(copy: false);
      var pcmLength = 0;
      var carry = Uint8List(0);
      while (true) {
        final chunk = await input.read(OggOpus.frameSize * 100);
        if (chunk.isEmpty) {
          if (carry.isNotEmpty) {
            final pcm = decoder.decodeFrame(carry);
            if (pcm != null && pcm.isNotEmpty) {
              pcmBatch.add(pcm);
              pcmLength += pcm.length;
            }
          }
          break;
        }

        final data = carry.isEmpty
            ? chunk
            : (Uint8List(carry.length + chunk.length)
                ..setRange(0, carry.length, carry)
                ..setRange(carry.length, carry.length + chunk.length, chunk));
        final completeLength =
            (data.length ~/ OggOpus.frameSize) * OggOpus.frameSize;
        for (
          var offset = 0;
          offset < completeLength;
          offset += OggOpus.frameSize
        ) {
          final pcm = decoder.decodeFrame(
            Uint8List.sublistView(data, offset, offset + OggOpus.frameSize),
          );
          if (pcm != null && pcm.isNotEmpty) {
            pcmBatch.add(pcm);
            pcmLength += pcm.length;
          }
        }
        carry = completeLength == data.length
            ? Uint8List(0)
            : Uint8List.fromList(data.sublist(completeLength));
        if (pcmBatch.isNotEmpty) {
          await output.writeFrom(pcmBatch.takeBytes());
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (pcmBatch.isNotEmpty) {
        await output.writeFrom(pcmBatch.takeBytes());
      }
      if (pcmLength == 0) throw StateError('Opus 解码失败');
      await output.setPosition(0);
      await output.writeFrom(_wavHeader(pcmLength));
      await output.flush();
      completed = true;
    } finally {
      await input.close();
      await output.close();
      decoder.dispose();
      if (!completed && await partial.exists()) {
        await partial.delete();
      }
    }

    final wav = File(wavPath);
    if (await wav.exists()) await wav.delete();
    await partial.rename(wavPath);
    return wavPath;
  }

  static Uint8List _wavHeader(int pcmLength) {
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(44);
    _ascii(header, 0, 'RIFF');
    header.setUint32(4, 36 + pcmLength, Endian.little);
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
    header.setUint32(40, pcmLength, Endian.little);
    return header.buffer.asUint8List();
  }

  static void _ascii(ByteData data, int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
}
