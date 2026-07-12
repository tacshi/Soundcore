import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'stt_types.dart';

/// Soniox real-time STT over WebSocket (`wss://stt-rt.soniox.com/transcribe-websocket`).
///
/// 1. Connect
/// 2. Send JSON config (`api_key`, `model`, `pcm_s16le`, …)
/// 3. Stream binary PCM16 LE
/// 4. End with empty frame → `finished: true`
class SonioxSttStreamSession implements SttStreamSession {
  SonioxSttStreamSession({
    required this.apiKey,
    this.sampleRate = 16000,
    this.language,
    this.languageHints = const ['zh', 'en'],
    this.model = 'stt-rt-v5',
    this.terms = const ['soundcore Work', 'Anker', '录音豆', 'D3200'],
  });

  final String apiKey;
  final int sampleRate;
  final String? language;
  final List<String> languageHints;
  final String model;
  final List<String> terms;

  static final _uri = Uri.parse('wss://stt-rt.soniox.com/transcribe-websocket');

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _events = StreamController<SttStreamEvent>.broadcast();
  final _pcmBuf = BytesBuilder(copy: false);
  final _finalTokens = <Map<String, dynamic>>[];
  Completer<void>? _ready;
  Completer<SttStreamEvent>? _doneWait;
  bool _opened = false;
  bool _serverReady = false;
  bool _closing = false;

  int get chunkBytes => sampleRate * 2 ~/ 10; // 100 ms

  @override
  Stream<SttStreamEvent> get events => _events.stream;
  @override
  bool get isOpen => _opened && !_closing;
  @override
  bool get isServerReady => _serverReady;

  Map<String, dynamic> get _config {
    final hints = <String>{
      ...languageHints,
      if (language != null && language!.isNotEmpty) language!,
    }.toList();
    return {
      'api_key': apiKey,
      'model': model,
      'audio_format': 'pcm_s16le',
      'sample_rate': sampleRate,
      'num_channels': 1,
      'language_hints': hints,
      'enable_language_identification': true,
      'enable_endpoint_detection': true,
      'max_endpoint_delay_ms': 1000,
      'context': {
        'terms': terms,
        'general': [
          {'key': 'domain', 'value': 'voice notes / meeting recorder'},
          {'key': 'product', 'value': 'soundcore Work D3200'},
        ],
      },
    };
  }

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    if (_opened) return;
    _closing = false;
    _serverReady = false;
    _finalTokens.clear();
    _ready = Completer<void>();
    _doneWait = null;

    debugPrint('[SonioxStream] connect $_uri');
    try {
      _channel = IOWebSocketChannel.connect(
        _uri,
        headers: {'Authorization': 'Bearer $apiKey'},
      );
      _opened = true;
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (Object e) {
          debugPrint('[SonioxStream] error: $e');
          _emit(SttStreamEvent(type: 'error', error: '$e'));
          if (!(_ready?.isCompleted ?? true)) {
            _ready!.completeError(e);
          }
        },
        onDone: () {
          debugPrint('[SonioxStream] socket done');
          _opened = false;
          _serverReady = false;
          _emit(const SttStreamEvent(type: 'closed'));
          if (!(_ready?.isCompleted ?? true)) {
            _ready!.completeError(StateError('Soniox WS closed before ready'));
          }
          final d = _doneWait;
          if (d != null && !d.isCompleted) {
            d.complete(const SttStreamEvent(type: 'closed'));
          }
        },
        cancelOnError: false,
      );

      // Config is the first text message; then we can stream audio.
      _channel!.sink.add(jsonEncode(_config));
      _serverReady = true;
      if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      _emit(const SttStreamEvent(type: 'created'));
    } catch (e) {
      _opened = false;
      rethrow;
    }

    try {
      await _ready!.future.timeout(timeout);
    } on TimeoutException {
      await close();
      throw TimeoutException('Soniox WS ready timeout');
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

    if (json['error_code'] != null) {
      final msg =
          '${json['error_code']} ${json['error_message'] ?? json['error_type'] ?? ''}';
      _emit(SttStreamEvent(type: 'error', error: msg.trim()));
      if (!(_ready?.isCompleted ?? true)) {
        _ready!.completeError(StateError(msg));
      }
      return;
    }

    final tokens = json['tokens'];
    final nonFinal = <Map<String, dynamic>>[];
    if (tokens is List) {
      for (final t in tokens) {
        if (t is! Map) continue;
        final map = Map<String, dynamic>.from(t);
        final text = '${map['text'] ?? ''}';
        if (text.isEmpty) continue;
        // Skip pure endpoint markers if present as empty-ish control.
        if (map['is_final'] == true) {
          _finalTokens.add(map);
        } else {
          nonFinal.add(map);
        }
      }
    }

    final full = _renderTokens(_finalTokens, nonFinal);
    final finalOnly = _renderTokens(_finalTokens, const []);
    final hasNonFinal = nonFinal.isNotEmpty;
    final finished = json['finished'] == true;
    final audioMs = (json['total_audio_proc_ms'] as num?)?.toDouble();
    final durationSec = audioMs != null ? audioMs / 1000.0 : null;

    if (finished) {
      final ev = SttStreamEvent(
        type: 'done',
        text: finalOnly,
        isFinal: true,
        speechFinal: true,
        durationSec: durationSec,
      );
      _emit(ev);
      final d = _doneWait;
      if (d != null && !d.isCompleted) d.complete(ev);
      return;
    }

    if (full.isNotEmpty || finalOnly.isNotEmpty) {
      _emit(
        SttStreamEvent(
          type: 'partial',
          text: full.isNotEmpty ? full : finalOnly,
          isFinal: !hasNonFinal,
          // Endpoint detection finalizes tokens; treat all-final updates as chunk finals.
          speechFinal: false,
          durationSec: durationSec,
        ),
      );
    }
  }

  static String _renderTokens(
    List<Map<String, dynamic>> finals,
    List<Map<String, dynamic>> nonFinals,
  ) {
    final buf = StringBuffer();
    for (final t in [...finals, ...nonFinals]) {
      // Ignore translation channel if present.
      if (t['translation_status'] == 'translation') continue;
      final piece = '${t['text'] ?? ''}';
      // Soniox endpoint token → newline (normalized further below).
      if (RegExp(r'^<end>$', caseSensitive: false).hasMatch(piece.trim())) {
        buf.write('\n');
      } else {
        buf.write(piece);
      }
    }
    return normalizeSttText(buf.toString());
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
        debugPrint('[SonioxStream] send fail: $e');
        return;
      }
    }
    if (force && _pcmBuf.length > 0) {
      final rem = _pcmBuf.toBytes();
      _pcmBuf.clear();
      try {
        ch.sink.add(rem);
      } catch (e) {
        debugPrint('[SonioxStream] flush fail: $e');
      }
    }
  }

  @override
  void finalizeUtterance() {
    // Soniox endpoint detection handles this; empty finalize not required mid-stream.
  }

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!_opened) return null;
    _flushChunks(force: true);
    _doneWait = Completer<SttStreamEvent>();
    try {
      // Empty frame signals end-of-audio.
      _channel?.sink.add(Uint8List(0));
      // Some servers accept empty text string as well.
      try {
        _channel?.sink.add('');
      } catch (_) {}
    } catch (e) {
      debugPrint('[SonioxStream] end-of-audio fail: $e');
    }
    try {
      return await _doneWait!.future.timeout(timeout);
    } on TimeoutException {
      debugPrint('[SonioxStream] done timeout');
      // Return accumulated finals if any.
      final text = _renderTokens(_finalTokens, const []);
      if (text.isNotEmpty) {
        return SttStreamEvent(
          type: 'done',
          text: text,
          isFinal: true,
          speechFinal: true,
        );
      }
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
