import 'dart:typed_data';

import 'package:anker_recorder/audio/opus_pcm_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trimOpusPacket strips trailing zero padding', () {
    final padded = Uint8List(160);
    padded[0] = 0x68; // plausible TOC
    padded[1] = 0x12;
    padded[2] = 0x34;
    for (var i = 3; i < 40; i++) {
      padded[i] = i & 0xFF;
    }
    // rest zeros
    final trimmed = OpusPcmDecoder.trimOpusPacket(padded);
    expect(trimmed.length, 40);
    expect(trimmed[0], 0x68);
    expect(trimmed[39], 39);
  });

  test('trimOpusPacket keeps single non-zero byte', () {
    final f = Uint8List.fromList([0x01, 0, 0, 0]);
    expect(OpusPcmDecoder.trimOpusPacket(f).length, 1);
  });

  test('samplesPerFrame for 16 kHz is 320 (20 ms)', () {
    final d = OpusPcmDecoder(outputSampleRate: 16000);
    expect(d.samplesPerFrame, 320);
  });

  test('samplesPerFrame for 48 kHz is 960 (20 ms)', () {
    final d = OpusPcmDecoder(outputSampleRate: 48000);
    expect(d.samplesPerFrame, 960);
  });
}
