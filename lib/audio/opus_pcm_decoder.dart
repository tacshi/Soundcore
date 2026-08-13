import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_opus/flutter_opus.dart';

import 'ogg_opus.dart';

/// Decode D3200 fixed 160-B Opus frames → PCM16 LE for low-latency streaming.
///
/// Device stream is bare concatenated frames (see [OggOpus]). Trailing zero
/// padding is stripped before libopus. Output defaults to **16 kHz mono** so
/// chunks can go straight to streaming STT (`sample_rate=16000`).
class OpusPcmDecoder {
  OpusPcmDecoder({this.outputSampleRate = 16000, this.channels = 1});

  /// Decoder / PCM sample rate (8000 / 12000 / 16000 / 24000 / 48000).
  final int outputSampleRate;
  final int channels;

  OpusDecoder? _decoder;
  bool _initFailed = false;
  int _framesOk = 0;
  int _framesFail = 0;

  /// Samples per 20 ms channel at [outputSampleRate].
  int get samplesPerFrame =>
      (outputSampleRate * OggOpus.samplesPerFrame) ~/ OggOpus.sampleRate;

  bool get isReady => _decoder != null && !_decoder!.isDisposed;
  bool get initFailed => _initFailed;
  int get framesDecoded => _framesOk;
  int get framesFailed => _framesFail;

  /// Ensure native decoder exists. Returns false if libopus unavailable.
  bool ensureStarted() {
    if (isReady) return true;
    if (_initFailed) return false;
    try {
      _decoder = OpusDecoder.create(
        sampleRate: outputSampleRate,
        channels: channels,
      );
      if (_decoder == null) {
        _initFailed = true;
        debugPrint('[OpusPcm] create failed (null)');
        return false;
      }
      debugPrint(
        '[OpusPcm] ready rate=$outputSampleRate ch=$channels '
        'frameSamples=$samplesPerFrame opus=${OpusDecoder.getVersion()}',
      );
      return true;
    } catch (e) {
      _initFailed = true;
      debugPrint('[OpusPcm] create error: $e');
      return false;
    }
  }

  /// Decode one 160-B (or shorter) raw frame → PCM16 LE bytes, or null.
  Uint8List? decodeFrame(Uint8List rawFrame) {
    if (!ensureStarted()) return null;
    final packet = trimOpusPacket(rawFrame);
    if (packet.isEmpty) return null;

    try {
      // frameSize = max samples/channel; 20 ms D3200 frames → samplesPerFrame.
      // Allow up to 120 ms in case of multi-frame packets (libopus max).
      final maxSamples = samplesPerFrame * 6;
      final pcm = _decoder!.decode(packet, maxSamples);
      if (pcm == null || pcm.isEmpty) {
        _framesFail++;
        return null;
      }
      _framesOk++;
      return pcm;
    } catch (e) {
      _framesFail++;
      if (_framesFail <= 5 || _framesFail % 50 == 0) {
        debugPrint('[OpusPcm] decode fail #$_framesFail: $e');
      }
      return null;
    }
  }

  /// Decode many raw frames and concatenate PCM.
  Uint8List? decodeFrames(Iterable<Uint8List> frames) {
    final out = BytesBuilder(copy: false);
    for (final f in frames) {
      final pcm = decodeFrame(f);
      if (pcm != null) out.add(pcm);
    }
    if (out.isEmpty) return null;
    return out.toBytes();
  }

  /// Split a raw file of concatenated 160-B frames and decode all.
  Uint8List? decodeRawFileBytes(Uint8List raw) {
    if (raw.isEmpty) return null;
    final frames = <Uint8List>[];
    var o = 0;
    while (o + OggOpus.frameSize <= raw.length) {
      frames.add(Uint8List.sublistView(raw, o, o + OggOpus.frameSize));
      o += OggOpus.frameSize;
    }
    if (o < raw.length) {
      frames.add(Uint8List.sublistView(raw, o));
    }
    return decodeFrames(frames);
  }

  void reset() {
    _decoder?.dispose();
    _decoder = null;
    _initFailed = false;
    _framesOk = 0;
    _framesFail = 0;
  }

  void dispose() {
    _decoder?.dispose();
    _decoder = null;
  }

  /// Strip trailing zero padding used in fixed 160-B transport slices.
  static Uint8List trimOpusPacket(Uint8List f) {
    var n = f.length;
    while (n > 1 && f[n - 1] == 0) {
      n--;
    }
    if (n <= 0) return Uint8List(0);
    return n == f.length ? f : Uint8List.sublistView(f, 0, n);
  }
}
