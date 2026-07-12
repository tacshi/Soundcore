import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../crypto/device_crypto.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';

/// Live status of Feishu-style realtime BLE transfer (`1A07` realtimeFlag=1).
class RealtimeStreamState {
  const RealtimeStreamState({
    this.active = false,
    this.fileId,
    this.path,
    this.bytesReceived = 0,
    this.message = '',
  });

  final bool active;
  final int? fileId;
  final String? path;
  final int bytesReceived;
  final String message;

  RealtimeStreamState copyWith({
    bool? active,
    int? fileId,
    String? path,
    int? bytesReceived,
    String? message,
    bool clearFile = false,
  }) {
    return RealtimeStreamState(
      active: active ?? this.active,
      fileId: clearFile ? null : (fileId ?? this.fileId),
      path: clearFile ? null : (path ?? this.path),
      bytesReceived: bytesReceived ?? this.bytesReceived,
      message: message ?? this.message,
    );
  }
}

/// Automatic realtime audio pull over BLE (Feishu `acquireRealtimeAudioData`).
///
/// Does **not** use SoftAP. Feishu sends `startTransportAudioFile` with
/// `realtimeFlag=1` and `preferSpp=false` → BLE notify slices while recording.
class RealtimeBleStream {
  RealtimeBleStream({
    required this.packets,
    required this.write,
    required this.crypto,
    this.onDecryptedFrame,
  });

  final Stream<DecodedPacket> packets;
  final Future<void> Function(List<int> frame) write;
  final DeviceCrypto crypto;

  /// Invoked for each decrypted 160-B Opus frame (realtime ASR hook).
  final void Function(Uint8List frame)? onDecryptedFrame;

  final _stateController = StreamController<RealtimeStreamState>.broadcast();
  Stream<RealtimeStreamState> get stateStream => _stateController.stream;

  RealtimeStreamState _state = const RealtimeStreamState();
  RealtimeStreamState get state => _state;

  StreamSubscription<DecodedPacket>? _sub;
  IOSink? _sink;
  String? _path;
  int? _fileId;
  int _received = 0;
  bool _decryptOn = false;
  bool _starting = false;
  Timer? _idleFinalizeTimer;

  void _log(String m) => debugPrint('[Realtime] $m');

  void _emit(RealtimeStreamState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// Start (or switch to) streaming [fileId] over BLE with realtimeFlag=1.
  Future<void> startForFile(int fileId) async {
    if (_starting) return;
    if (_fileId == fileId && _state.active && _sink != null) {
      _log('already streaming file $fileId');
      return;
    }
    _starting = true;
    try {
      await _openSession(fileId);
      await write(
        DeviceCommands.startTransportAudioFile(
          fileId: fileId,
          alreadyTransferred: _received,
          realtimeFlag: 1,
        ),
      );
      _log('requested realtime file=$fileId offset=$_received');
      _emit(
        _state.copyWith(
          active: true,
          fileId: fileId,
          path: _path,
          bytesReceived: _received,
          message: '实时传输中…',
        ),
      );
    } finally {
      _starting = false;
    }
  }

  Future<void> _openSession(int fileId) async {
    // Switch file: finalize previous sink first.
    if (_fileId != null && _fileId != fileId) {
      await _finalize(keepActive: false, reason: 'switch');
    }

    _ensurePacketListener();

    if (_fileId == fileId && _sink != null && _path != null) {
      return;
    }

    final dir = await _exportDir();
    final path = p.join(dir.path, '$fileId.opus');
    final file = File(path);
    final exists = await file.exists();
    final offset = exists ? await file.length() : 0;

    _sink = file.openWrite(mode: FileMode.append);
    _path = path;
    _fileId = fileId;
    _received = offset;
    _decryptOn = false;
    _log('open $path (append offset=$offset)');
  }

  void _ensurePacketListener() {
    if (_sub != null) return;
    _sub = packets.listen(_onPacket);
  }

  void _onPacket(DecodedPacket pkt) {
    if (pkt.cmdType != RxCmd.transportType &&
        pkt.cmdType != RxCmd.transportTypeAlt) {
      return;
    }

    // 1A06 — new file / transport status while recording
    if (pkt.cmdId == RxCmd.recordStatusId && pkt.payload.length >= 4) {
      final newId = readU32Le(pkt.payload, 0);
      if (newId > 0 && newId != _fileId) {
        _log('1A06 new file id=$newId');
        unawaited(startForFile(newId));
      }
      return;
    }

    if (_fileId == null || _sink == null) return;

    if (pkt.cmdId == RxCmd.fileHeadId) {
      final secret = AudioFileSecretKey.parseFrame(pkt.raw);
      if (secret != null) {
        _decryptOn = crypto.initFileDecrypt(
          fileId: '$_fileId',
          encryptedFileKey: secret.encryptedFileKey,
          sessionNonce: secret.sessionNonce,
          nonce: secret.nonce,
        );
        _log('head id=${secret.fileId} decrypt=$_decryptOn');
      }
      return;
    }

    if (pkt.cmdId == RxCmd.fileSliceId || pkt.cmdId == RxCmd.fileSliceMarkId) {
      final n = _writeSlices(pkt.raw);
      if (n > 0) {
        _received += n;
        _idleFinalizeTimer?.cancel();
        _emit(
          _state.copyWith(
            active: true,
            fileId: _fileId,
            path: _path,
            bytesReceived: _received,
            message: '实时接收 ${(_received / 1024).toStringAsFixed(1)} KB',
          ),
        );
      }
      return;
    }

    if (pkt.cmdId == RxCmd.fileDoneId) {
      _log('file done for $_fileId');
      unawaited(_finalize(keepActive: false, reason: 'done'));
    }
  }

  int _writeSlices(Uint8List frame) {
    final sink = _sink;
    final fileId = _fileId;
    if (sink == null || fileId == null) return 0;
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

      if (_decryptOn) {
        final plain = crypto.decryptChunk(
          fileId: '$fileId',
          sequence: seq,
          data: chunk,
        );
        if (plain != null) chunk = plain;
      }
      sink.add(chunk);
      written += chunk.length;
      onDecryptedFrame?.call(Uint8List.fromList(chunk));
    }
    return written;
  }

  /// Call when recording pauses/stops — finalize after a short idle settle.
  void onRecordingStopped() {
    if (!_state.active && _sink == null) return;
    _idleFinalizeTimer?.cancel();
    _idleFinalizeTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_finalize(keepActive: false, reason: 'recording_stopped'));
    });
  }

  Future<String?> _finalize({
    required bool keepActive,
    required String reason,
  }) async {
    _idleFinalizeTimer?.cancel();
    final path = _path;
    final id = _fileId;
    final bytes = _received;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    if (id != null) crypto.clearFile('$id');

    _log('finalize reason=$reason path=$path bytes=$bytes');
    if (path != null && bytes > 0) {
      _emit(
        RealtimeStreamState(
          active: keepActive,
          fileId: id,
          path: path,
          bytesReceived: bytes,
          message: keepActive ? '已暂停接收' : '实时文件已保存',
        ),
      );
      return path;
    }
    _emit(const RealtimeStreamState(active: false, message: ''));
    _fileId = null;
    _path = null;
    _received = 0;
    return null;
  }

  Future<String?> stop() => _finalize(keepActive: false, reason: 'stop');

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

  Future<void> dispose() async {
    _idleFinalizeTimer?.cancel();
    await stop();
    await _sub?.cancel();
    _sub = null;
    await _stateController.close();
  }
}
