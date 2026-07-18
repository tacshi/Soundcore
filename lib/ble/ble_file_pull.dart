import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../crypto/device_crypto.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';

class BleFilePullCancelled implements Exception {
  const BleFilePullCancelled();
}

/// Pull one offline recording over BLE (0x1A/0x07 head → 0x08 slices → 0x0A done).
///
/// Prefer this for playback of small/medium files; use Wi‑Fi SoftAP for batch.
class BleFilePull {
  BleFilePull({
    required this.packets,
    required this.write,
    required this.crypto,
  });

  final Stream<DecodedPacket> packets;
  final Future<void> Function(List<int> frame) write;
  final DeviceCrypto crypto;
  bool _cancelled = false;
  Completer<void>? _cancelCompleter;

  void cancel() {
    _cancelled = true;
    final completer = _cancelCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _log(String m) => debugPrint('[BlePull] $m');

  Future<String> pullFile(
    OfflineFileEntry file, {
    // Maximum time without a file packet, not a cap on total transfer time.
    Duration timeout = const Duration(seconds: 90),
    void Function(int received, int expected)? onProgress,
  }) async {
    _cancelled = false;
    _cancelCompleter = Completer<void>();
    final dir = await _exportDir();
    final path = p.join(dir.path, '${file.fileId}.opus');
    final sink = File(path).openWrite();

    var received = 0;
    var expected = file.sizeBytes;
    var decryptOn = false;
    final fileIdStr = '${file.fileId}';
    final head = Completer<void>();
    final done = Completer<void>();
    final inactivity = Stopwatch()..start();
    final sub = packets.listen((pkt) {
      if (pkt.cmdType != RxCmd.transportType &&
          pkt.cmdType != RxCmd.transportTypeAlt) {
        return;
      }
      if (pkt.cmdId == RxCmd.fileHeadId) {
        inactivity.reset();
        final secret = AudioFileSecretKey.parseFrame(pkt.raw);
        if (secret != null) {
          if (secret.fileSize > 0) expected = secret.fileSize;
          decryptOn = crypto.initFileDecrypt(
            fileId: fileIdStr,
            encryptedFileKey: secret.encryptedFileKey,
            sessionNonce: secret.sessionNonce,
            nonce: secret.nonce,
          );
          _log('head id=${secret.fileId} size=$expected decrypt=$decryptOn');
        }
        if (!head.isCompleted) head.complete();
        return;
      }
      if (pkt.cmdId == RxCmd.fileSliceId ||
          pkt.cmdId == RxCmd.fileSliceMarkId) {
        inactivity.reset();
        received += _writeSlices(
          pkt.raw,
          sink,
          fileId: fileIdStr,
          decrypt: decryptOn,
        );
        onProgress?.call(received, expected);
        return;
      }
      if (pkt.cmdId == RxCmd.fileDoneId) {
        inactivity.reset();
        if (!done.isCompleted) done.complete();
      }
    });

    try {
      await write(
        DeviceCommands.startTransportAudioFile(
          fileId: file.fileId,
          alreadyTransferred: 0,
          realtimeFlag: 0,
        ),
      );
      _log('requested file ${file.fileId}');

      try {
        await Future.any([
          head.future,
          _cancelCompleter!.future,
        ]).timeout(const Duration(seconds: 15));
      } on TimeoutException {
        _log('no file head yet — waiting for slices');
      }
      if (_cancelled) throw const BleFilePullCancelled();

      while (!_cancelled && inactivity.elapsed < timeout) {
        if (done.isCompleted) break;
        if (expected > 0 && received >= expected) break;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

      if (_cancelled) throw const BleFilePullCancelled();

      if (expected > 0 && received < expected * 0.95) {
        throw StateError('Incomplete BLE export: $received/$expected bytes');
      }

      await sink.flush();
      await sink.close();
      crypto.clearFile(fileIdStr);

      if (received == 0) {
        try {
          await File(path).delete();
        } catch (_) {}
        throw StateError(
          'No audio data received for ${file.fileId}. '
          'Keep BLE connected and try again.',
        );
      }
      _log('saved $path ($received bytes, decrypt=$decryptOn)');
      return path;
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await File(path).delete();
      } catch (_) {}
      crypto.clearFile(fileIdStr);
      rethrow;
    } finally {
      await sub.cancel();
      _cancelCompleter = null;
    }
  }

  int _writeSlices(
    Uint8List frame,
    IOSink sink, {
    required String fileId,
    required bool decrypt,
  }) {
    var written = 0;
    var i = 9;
    while (frame.length - i >= 165) {
      final seq = readU32Le(frame, i);
      i += 4;
      i += 1; // flags
      final dataEnd = i + 160;
      if (dataEnd > frame.length) break;
      var chunk = Uint8List.fromList(frame.sublist(i, dataEnd));
      i = dataEnd;
      if (i < frame.length) i += 1;

      if (decrypt) {
        final plain = crypto.decryptChunk(
          fileId: fileId,
          sequence: seq,
          data: chunk,
        );
        if (plain != null) chunk = plain;
      }
      sink.add(chunk);
      written += chunk.length;
    }
    return written;
  }

  Future<Directory> _exportDir() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder', 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
