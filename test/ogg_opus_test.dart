import 'dart:io';
import 'dart:typed_data';

import 'package:anker_recorder/audio/ogg_opus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mux raw 160-byte frames yields OggS', () {
    final frames = 10;
    final raw = Uint8List(frames * OggOpus.frameSize);
    // Non-zero payload so frames are not trimmed to empty.
    for (var i = 0; i < frames; i++) {
      final o = i * OggOpus.frameSize;
      raw[o] = 0xbc;
      for (var j = 1; j < OggOpus.frameSize; j++) {
        raw[o + j] = (j * 17 + i) & 0xFF;
      }
    }
    final ogg = OggOpus.muxRawFrames(raw);
    expect(OggOpus.isOgg(ogg), isTrue);
    expect(ogg.length, greaterThan(200));
  });

  test('ensurePlayable on sample file if present', () async {
    final path =
        '${Platform.environment['HOME']}/Library/Containers/com.anker.ankerRecorder/Data/Documents/AnkerRecorder/exports/1783822462.opus';
    final f = File(path);
    if (!await f.exists()) return;
    final playable = await OggOpus.ensurePlayable(path);
    expect(playable.endsWith('.ogg'), isTrue);
    final bytes = await File(playable).readAsBytes();
    expect(OggOpus.isOgg(bytes), isTrue);
    expect(bytes.length, greaterThan(1000));
  });
}
