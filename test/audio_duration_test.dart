import 'dart:io';
import 'dart:typed_data';

import 'package:anker_recorder/audio/audio_duration.dart';
import 'package:anker_recorder/audio/ogg_opus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('audio-duration-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('reads duration from generated PCM WAV metadata', () async {
    const byteRate = 48000 * 2;
    const dataLength = byteRate * 2;
    final bytes = Uint8List(44 + dataLength);
    final header = ByteData.sublistView(bytes);
    bytes.setAll(0, 'RIFF'.codeUnits);
    bytes.setAll(8, 'WAVE'.codeUnits);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint32(40, dataLength, Endian.little);
    final file = File('${directory.path}/1.wav');
    await file.writeAsBytes(bytes);

    expect(await AudioDuration.read(file.path), const Duration(seconds: 2));
  });

  test('estimates duration from raw Opus frame count', () async {
    final file = File('${directory.path}/1.opus');
    await file.writeAsBytes(Uint8List(OggOpus.frameSize * 10));

    expect(
      await AudioDuration.read(file.path),
      const Duration(milliseconds: 200),
    );
  });

  test('reads duration from the final Ogg granule', () async {
    final raw = Uint8List(OggOpus.frameSize * 50);
    for (var i = 0; i < raw.length; i += OggOpus.frameSize) {
      raw[i] = 0xbc;
    }
    final file = File('${directory.path}/1.opus');
    await file.writeAsBytes(OggOpus.muxRawFrames(raw));

    expect(await AudioDuration.read(file.path), const Duration(seconds: 1));
  });
}
