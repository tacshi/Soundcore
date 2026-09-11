import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'stt_types.dart';

enum SpeechResourceStatus { unsupported, needsDownload, ready }

class SpeechLanguage {
  const SpeechLanguage({required this.code, required this.name});

  final String code;
  final String name;
}

class AppleSpeechCapabilities {
  const AppleSpeechCapabilities({
    required this.supported,
    required this.speechStatus,
    required this.translationStatus,
    this.speechLanguages = const [],
    this.translationLanguages = const [],
    this.suggestedSourceLanguage,
  });

  const AppleSpeechCapabilities.unsupported()
    : supported = false,
      speechStatus = SpeechResourceStatus.unsupported,
      translationStatus = SpeechResourceStatus.unsupported,
      speechLanguages = const [],
      translationLanguages = const [],
      suggestedSourceLanguage = null;

  final bool supported;
  final SpeechResourceStatus speechStatus;
  final SpeechResourceStatus translationStatus;
  final List<SpeechLanguage> speechLanguages;
  final List<SpeechLanguage> translationLanguages;
  final String? suggestedSourceLanguage;

  factory AppleSpeechCapabilities.fromMap(Map<dynamic, dynamic> map) {
    SpeechResourceStatus status(String key) =>
        SpeechResourceStatus.values
            .where((value) => value.name == map[key])
            .firstOrNull ??
        SpeechResourceStatus.unsupported;
    List<SpeechLanguage> languages(String key) => [
      for (final item in map[key] as List? ?? const [])
        if (item is Map && item['code'] is String)
          SpeechLanguage(
            code: item['code'] as String,
            name: item['name'] as String? ?? item['code'] as String,
          ),
    ];
    return AppleSpeechCapabilities(
      supported: map['supported'] == true,
      speechStatus: status('speechStatus'),
      translationStatus: status('translationStatus'),
      speechLanguages: languages('speechLanguages'),
      translationLanguages: languages('translationLanguages'),
      suggestedSourceLanguage: map['suggestedSourceLanguage'] as String?,
    );
  }
}

/// Apple processing only. An unavailable bridge never selects a cloud provider.
/// Methods remain overridable so controllers can test capability and job state.
class AppleSpeechService {
  AppleSpeechService({MethodChannel? channel, EventChannel? eventChannel})
    : _channel = channel ?? const MethodChannel('soundcore/apple_speech'),
      _eventChannel =
          eventChannel ?? const EventChannel('soundcore/apple_speech/events');

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<dynamic>? _events;
  final Set<_AppleSttStreamSession> _sessions = {};
  String? _fileJob;
  bool _disposed = false;
  static int _sequence = 0;

  static String _identifier() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async {
    if (!_supportedPlatform || _disposed) {
      return const AppleSpeechCapabilities.unsupported();
    }
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'capabilities',
        {'sourceLanguage': sourceLanguage, 'targetLanguage': targetLanguage},
      );
      return map == null
          ? const AppleSpeechCapabilities.unsupported()
          : AppleSpeechCapabilities.fromMap(map);
    } on MissingPluginException {
      return const AppleSpeechCapabilities.unsupported();
    } on PlatformException catch (error) {
      if (error.code == 'unsupported') {
        return const AppleSpeechCapabilities.unsupported();
      }
      rethrow;
    }
  }

  void _checkAvailable() {
    if (_disposed || !_supportedPlatform) {
      throw PlatformException(code: 'unsupported');
    }
  }

  Future<void> prepareLanguages({
    required String sourceLanguage,
    String? targetLanguage,
  }) => _fileOperation<void>('prepareLanguages', {
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
  }, (_) {});

  /// Prepare an existing transcript's language pair without requiring speech
  /// recognition support or downloading a speech model for its source language.
  Future<void> prepareTranslation({
    required String sourceLanguage,
    required String targetLanguage,
  }) => _fileOperation<void>('prepareTranslation', {
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
  }, (_) {});

  SttStreamSession createStreamSession({
    required String sourceLanguage,
    String? targetLanguage,
  }) {
    _checkAvailable();
    final session = _AppleSttStreamSession(
      channel: _channel,
      nativeEvents: _events ??= _eventChannel.receiveBroadcastStream(),
      identifier: _identifier(),
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      beforeStart: cancelFileProcessing,
    );
    _sessions.add(session);
    session.onDisposed = () => _sessions.remove(session);
    return session;
  }

  Future<T> _fileOperation<T>(
    String method,
    Map<String, Object?> args,
    T Function(dynamic value) decode,
  ) async {
    _checkAvailable();
    if (_fileJob != null) throw PlatformException(code: 'busy');
    final job = _identifier();
    _fileJob = job;
    try {
      final value = await _channel.invokeMethod<dynamic>(method, {
        ...args,
        'jobId': job,
      });
      if (_disposed || _fileJob != job) {
        throw PlatformException(code: 'cancelled');
      }
      return decode(value);
    } finally {
      if (_fileJob == job) _fileJob = null;
    }
  }

  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    onProgress?.call(const SttFileProgress(SttFileStage.preparing));
    onProgress?.call(const SttFileProgress(SttFileStage.processing));
    return _fileOperation(
      'transcribeFile',
      {'path': path, 'sourceLanguage': sourceLanguage},
      (value) {
        final map = value as Map;
        onProgress?.call(const SttFileProgress(SttFileStage.fetching));
        return SttResult(
          text: normalizeSttText(map['text'] as String? ?? ''),
          durationSec: (map['durationSec'] as num?)?.toDouble(),
          sourcePath: path,
          language: sourceLanguage,
        );
      },
    );
  }

  Future<String> translate(
    String text, {
    required String sourceLanguage,
    required String targetLanguage,
  }) => _fileOperation('translate', {
    'text': text,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
  }, (value) => value as String);

  Future<void> cancelFileProcessing() async {
    final job = _fileJob;
    _fileJob = null;
    if (job == null) return;
    await _channel.invokeMethod<void>('cancelFile', {'jobId': job});
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancelFileProcessing();
    for (final session in _sessions.toList()) {
      await session.dispose();
    }
  }
}

class _AppleSttStreamSession implements SttStreamSession {
  _AppleSttStreamSession({
    required this.channel,
    required this.nativeEvents,
    required this.identifier,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.beforeStart,
  });

  final Future<void> Function() beforeStart;
  final MethodChannel channel;
  final Stream<dynamic> nativeEvents;
  final String identifier;
  final String sourceLanguage;
  final String? targetLanguage;
  final _events = StreamController<SttStreamEvent>.broadcast();
  final _pendingPcm = Queue<Uint8List>();
  StreamSubscription<dynamic>? _subscription;
  VoidCallback? onDisposed;
  bool _open = false;
  bool _ready = false;
  bool _closed = false;
  bool _started = false;
  bool _finishing = false;
  bool _draining = false;
  int _pendingBytes = 0;
  Completer<void>? _drained;
  SttStreamEvent? _latest;

  @override
  Stream<SttStreamEvent> get events => _events.stream;
  @override
  bool get isOpen => _open && !_closed;
  @override
  bool get isServerReady => _ready && isOpen;

  SttStreamEvent _decode(Map<dynamic, dynamic> map) => SttStreamEvent(
    type: map['type'] as String? ?? 'partial',
    text: normalizeSttText(map['text'] as String? ?? ''),
    isFinal: map['isFinal'] == true,
    speechFinal: map['speechFinal'] == true,
    durationSec: (map['durationSec'] as num?)?.toDouble(),
    error: map['error'] as String?,
    translationTurns: [
      for (final turn in map['translationTurns'] as List? ?? const [])
        if (turn is Map)
          SttTranslationTurn(
            sourceLanguage: turn['sourceLanguage'] as String? ?? sourceLanguage,
            targetLanguage:
                turn['targetLanguage'] as String? ?? targetLanguage ?? '',
            sourceText: turn['sourceText'] as String? ?? '',
            text: turn['text'] as String? ?? '',
            isFinal: turn['isFinal'] == true,
          ),
    ],
    pendingTranslationSource: map['pendingTranslationSource'] is String
        ? SttSourceChunk(
            language: sourceLanguage,
            text: map['pendingTranslationSource'] as String,
          )
        : null,
  );

  void _emit(SttStreamEvent event) {
    if (_closed || _events.isClosed) return;
    _latest = event;
    _events.add(event);
  }

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    if (_started || _closed) throw StateError('Session already started');
    _started = true;
    _subscription = nativeEvents.listen(
      (dynamic value) {
        if (value is! Map || value['sessionId'] != identifier || _closed) {
          return;
        }
        final event = _decode(value);
        if (event.type == 'created') _ready = true;
        if (event.type == 'closed' || event.type == 'error') _ready = false;
        _emit(event);
      },
      onError: (Object error) {
        _emit(SttStreamEvent(type: 'error', error: _errorCode(error)));
      },
    );
    _open = true;
    try {
      await beforeStart().timeout(timeout);
      if (_closed) return;
      await channel
          .invokeMethod<void>('startStream', {
            'sessionId': identifier,
            'sourceLanguage': sourceLanguage,
            'targetLanguage': targetLanguage,
          })
          .timeout(timeout);
      if (_closed) return;
      _ready = true;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  void sendPcm(Uint8List pcm16le) {
    if (!isServerReady || _finishing || pcm16le.isEmpty) return;
    // Five seconds of D3200 PCM. Fail explicitly instead of silently dropping.
    if (_pendingBytes + pcm16le.length > 16000 * 2 * 5) {
      _emit(const SttStreamEvent(type: 'error', error: 'audio_buffer_full'));
      unawaited(close());
      return;
    }
    _pendingPcm.add(Uint8List.fromList(pcm16le));
    _pendingBytes += pcm16le.length;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    _drained = Completer<void>();
    try {
      while (!_closed && _pendingPcm.isNotEmpty) {
        final pcm = _pendingPcm.removeFirst();
        _pendingBytes -= pcm.length;
        await channel.invokeMethod<void>('appendPcm', {
          'sessionId': identifier,
          'pcm': pcm,
        });
      }
    } catch (error) {
      _emit(SttStreamEvent(type: 'error', error: _errorCode(error)));
      unawaited(close());
    } finally {
      _draining = false;
      _drained?.complete();
      _drained = null;
    }
  }

  @override
  void finalizeUtterance() {
    if (!isServerReady || _finishing) return;
    unawaited(_finalizeUtterance());
  }

  Future<void> _finalizeUtterance() async {
    try {
      await _drained?.future;
      if (_closed || _finishing) return;
      await channel.invokeMethod<void>('finalizeUtterance', {
        'sessionId': identifier,
      });
    } catch (error) {
      _emit(SttStreamEvent(type: 'error', error: _errorCode(error)));
    }
  }

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_closed || !_open) return _latest;
    _finishing = true;
    try {
      await _drained?.future.timeout(timeout);
      final map = await channel
          .invokeMapMethod<String, dynamic>('finishStream', {
            'sessionId': identifier,
          })
          .timeout(timeout);
      if (!_closed && map != null) _emit(_decode(map));
      return _latest;
    } finally {
      await close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _open = false;
    _ready = false;
    _pendingPcm.clear();
    _pendingBytes = 0;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await channel.invokeMethod<void>('closeStream', {
        'sessionId': identifier,
      });
    } on MissingPluginException {
      // Unsupported hosts cannot hold a native stream.
    }
  }

  @override
  Future<void> dispose() async {
    await close();
    await _events.close();
    onDisposed?.call();
    onDisposed = null;
  }

  String _errorCode(Object error) =>
      error is PlatformException ? error.code : 'processing_failed';
}
