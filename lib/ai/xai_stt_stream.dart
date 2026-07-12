import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'stt_types.dart';

export 'stt_types.dart' show SttStreamEvent, SttStreamSession;

/// Low-latency streaming STT: binary PCM16 LE over xAI WebSocket.
///
/// Docs: `wss://api.x.ai/v1/stt?sample_rate=16000&encoding=pcm&interim_results=true`
/// Wait for `transcript.created`, then send ~100 ms PCM chunks.
class XaiSttStreamSession implements SttStreamSession {
  XaiSttStreamSession({
    required this.apiKey,
    this.sampleRate = 16000,
    this.language,
    this.interimResults = true,
    this.keyterms = const ['soundcore Work', 'Anker'],
  });

  final String apiKey;
  final int sampleRate;
  final String? language;
  final bool interimResults;
  final List<String> keyterms;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _events = StreamController<SttStreamEvent>.broadcast();
  final _pcmBuf = BytesBuilder(copy: false);
  Completer<void>? _ready;
  Completer<SttStreamEvent>? _doneWait;
  bool _opened = false;
  bool _serverReady = false;
  bool _closing = false;

  /// Target chunk size: 100 ms of mono PCM16.
  int get chunkBytes => sampleRate * 2 ~/ 10;

  @override
  Stream<SttStreamEvent> get events => _events.stream;
  @override
  bool get isOpen => _opened && !_closing;
  @override
  bool get isServerReady => _serverReady;

  Uri get _uri {
    final q = <String, String>{
      'sample_rate': '$sampleRate',
      'encoding': 'pcm',
      'interim_results': interimResults ? 'true' : 'false',
      'endpointing': '300',
    };
    if (language != null && language!.isNotEmpty) {
      q['language'] = language!;
    }
    // First keyterm via map; extras appended below (repeat params).
    if (keyterms.isNotEmpty) {
      q['keyterm'] = keyterms.first;
    }
    var uri = Uri.https('api.x.ai', '/v1/stt', q);
    if (keyterms.length > 1) {
      final extra = keyterms
          .skip(1)
          .map((t) => 'keyterm=${Uri.encodeQueryComponent(t)}')
          .join('&');
      uri = Uri.parse('${uri.toString()}&$extra');
    }
    return uri;
  }

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    if (_opened) return;
    _closing = false;
    _serverReady = false;
    _ready = Completer<void>();
    _doneWait = null;

    final uri = _uri;
    debugPrint('[SttStream/xAI] connect $uri');
    try {
      _channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Authorization': 'Bearer $apiKey'},
      );
      _opened = true;
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (Object e) {
          debugPrint('[SttStream/xAI] error: $e');
          _emit(SttStreamEvent(type: 'error', error: '$e'));
          if (!(_ready?.isCompleted ?? true)) {
            _ready!.completeError(e);
          }
        },
        onDone: () {
          debugPrint('[SttStream/xAI] socket done');
          _opened = false;
          _serverReady = false;
          _emit(const SttStreamEvent(type: 'closed'));
          if (!(_ready?.isCompleted ?? true)) {
            _ready!.completeError(StateError('STT WS closed before ready'));
          }
          final d = _doneWait;
          if (d != null && !d.isCompleted) {
            d.complete(const SttStreamEvent(type: 'closed'));
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      _opened = false;
      rethrow;
    }

    try {
      await _ready!.future.timeout(timeout);
    } on TimeoutException {
      await close();
      throw TimeoutException('STT WS ready timeout');
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = '${json['type'] ?? ''}';
    if (type == 'transcript.created') {
      _serverReady = true;
      if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      _emit(const SttStreamEvent(type: 'created'));
      return;
    }
    if (type == 'error') {
      final msg = '${json['message'] ?? json['error'] ?? data}';
      _emit(SttStreamEvent(type: 'error', error: msg));
      return;
    }
    if (type == 'transcript.partial') {
      final text = '${json['text'] ?? ''}'.trim();
      final isFinal = json['is_final'] == true;
      final speechFinal = json['speech_final'] == true;
      final dur = (json['duration'] as num?)?.toDouble();
      _emit(
        SttStreamEvent(
          type: 'partial',
          text: text,
          isFinal: isFinal,
          speechFinal: speechFinal,
          durationSec: dur,
        ),
      );
      return;
    }
    if (type == 'transcript.done') {
      final text = '${json['text'] ?? ''}'.trim();
      final dur = (json['duration'] as num?)?.toDouble();
      final ev = SttStreamEvent(
        type: 'done',
        text: text,
        isFinal: true,
        speechFinal: true,
        durationSec: dur,
      );
      _emit(ev);
      final d = _doneWait;
      if (d != null && !d.isCompleted) d.complete(ev);
      return;
    }
  }

  void _emit(SttStreamEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  void sendPcm(Uint8List pcm16le) {
    if (!_opened || _closing || !_serverReady || pcm16le.isEmpty) return;
    _pcmBuf.add(pcm16le);
    _flushChunks(force: false);
  }

  void _flushChunks({required bool force}) {
    final ch = _channel;
    if (ch == null) return;
    final target = chunkBytes;
    while (_pcmBuf.length >= target) {
      final all = _pcmBuf.toBytes();
      final chunk = Uint8List.sublistView(all, 0, target);
      final rest = Uint8List.sublistView(all, target);
      _pcmBuf.clear();
      if (rest.isNotEmpty) _pcmBuf.add(rest);
      try {
        ch.sink.add(chunk);
      } catch (e) {
        debugPrint('[SttStream/xAI] send fail: $e');
        return;
      }
    }
    if (force && _pcmBuf.length > 0) {
      final rem = _pcmBuf.toBytes();
      _pcmBuf.clear();
      try {
        ch.sink.add(rem);
      } catch (e) {
        debugPrint('[SttStream/xAI] flush fail: $e');
      }
    }
  }

  @override
  void finalizeUtterance() {
    final ch = _channel;
    if (ch == null || !_opened) return;
    try {
      ch.sink.add(jsonEncode({'type': 'Finalize'}));
    } catch (_) {}
  }

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!_opened) return null;
    _flushChunks(force: true);
    _doneWait = Completer<SttStreamEvent>();
    try {
      _channel?.sink.add(jsonEncode({'type': 'audio.done'}));
    } catch (e) {
      debugPrint('[SttStream/xAI] audio.done fail: $e');
    }
    try {
      return await _doneWait!.future.timeout(timeout);
    } on TimeoutException {
      debugPrint('[SttStream/xAI] done timeout');
      return null;
    } finally {
      await close();
    }
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _serverReady = false;
    _opened = false;
    _pcmBuf.clear();
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  @override
  Future<void> dispose() async {
    await close();
    await _events.close();
  }
}
