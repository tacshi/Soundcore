import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../audio/ogg_opus.dart';
import 'stt_types.dart';

class MossException implements Exception {
  const MossException(this.code, {this.statusCode});
  final String code;
  final int? statusCode;
  bool get retryable =>
      code == 'network' || code == 'rate_limit' || code == 'server';
  String get message => switch (code) {
    'credentials' => 'MOSS API Key 无效，请在设置中更新',
    'model' => '此 API Key 无法使用 MOSS Pro，请更换',
    'balance' => 'MOSS 余额不足，请充值后重试',
    'too_large' => '录音超过 512 MB，请缩短后重试',
    'audio' => '无法读取录音，请重新下载',
    'rate_limit' => 'MOSS 请求过多，稍后重试',
    'network' => '无法连接 MOSS，请检查网络后重试',
    'empty' => '未识别到语音，可重试',
    _ => 'MOSS 转写失败，请重试',
  };
  @override
  String toString() => 'MossException($code, $statusCode)';
}

/// File-based MOSS Pro transcription. Credentials are passed per operation so
/// changing settings cannot change the account of a running job.
class MossSttService {
  MossSttService({http.Client? client, Uri? baseUri})
    : _client = client ?? http.Client(),
      _base = (baseUri ?? Uri.parse('https://api.mosi.cn/v1')).toString();
  static const model = 'moss-transcribe-diarize-pro';
  static const maxUploadBytes = 512 * 1024 * 1024;
  final http.Client _client;
  final String _base;
  String? apiKeyOverride;
  String? get apiKey {
    final key = apiKeyOverride?.trim();
    if (key != null && key.isNotEmpty) return key;
    final env = Platform.environment['MOSS_API_KEY']?.trim();
    return env == null || env.isEmpty ? null : env;
  }

  Uri _uri(String path) => Uri.parse('$_base$path');
  Map<String, String> _headers(String key) => {'Authorization': 'Bearer $key'};

  Future<T> _request<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on TimeoutException {
      throw const MossException('network');
    } on SocketException {
      throw const MossException('network');
    } on http.ClientException {
      throw const MossException('network');
    }
  }

  void _check(int status) {
    if (status >= 200 && status < 300) return;
    throw MossException(switch (status) {
      401 || 403 => 'credentials',
      402 => 'balance',
      413 => 'too_large',
      429 => 'rate_limit',
      >= 500 => 'server',
      _ => 'response',
    }, statusCode: status);
  }

  Map<String, dynamic> _decode(http.Response response) {
    _check(response.statusCode);
    try {
      final value = jsonDecode(response.body);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      /* Do not expose response bodies. */
    }
    throw const MossException('response');
  }

  Future<void> validateKey(String key) => _request(() async {
    final data = _decode(
      await _client
          .get(_uri('/models'), headers: _headers(key))
          .timeout(const Duration(seconds: 20)),
    );
    if (data['data'] is! List ||
        !(data['data'] as List).any(
          (item) => item is Map && item['id'] == model,
        )) {
      throw const MossException('model');
    }
  });

  Future<String> prepareAudio(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() < 64) {
      throw const MossException('audio');
    }
    if (await file.length() > maxUploadBytes) {
      throw const MossException('too_large');
    }
    // WAV and already-containerized exports can be uploaded directly.
    if (!path.endsWith('.opus')) return path;
    final playable = await OggOpus.ensurePlayable(path);
    if (await File(playable).length() > maxUploadBytes) {
      throw const MossException('too_large');
    }
    return playable;
  }

  Future<String> upload(
    String path,
    String key, {
    SttFileProgressCallback? onProgress,
  }) => _request(() async {
    final file = File(path);
    final size = await file.length();
    if (size > maxUploadBytes) throw const MossException('too_large');
    var sent = 0;
    final request = http.MultipartRequest('POST', _uri('/files'))
      ..headers.addAll(_headers(key))
      ..fields['purpose'] = 'audio'
      ..files.add(
        http.MultipartFile(
          'file',
          file.openRead().map((chunk) {
            sent += chunk.length;
            onProgress?.call(
              SttFileProgress(
                SttFileStage.uploading,
                uploadedBytes: sent,
                totalBytes: size,
              ),
            );
            return chunk;
          }),
          size,
          filename: p.basename(path),
        ),
      );
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 30));
    final body = await response.stream.bytesToString().timeout(
      const Duration(seconds: 60),
    );
    final data = _decode(http.Response(body, response.statusCode));
    return _id(data['id']);
  });

  Future<String> submit(String fileId, String key) => _request(() async {
    final data = _decode(
      await _client
          .post(
            _uri('/audio/transcriptions'),
            headers: {..._headers(key), 'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'file_id': fileId,
              'diarize': true,
              'response_format': 'json',
              'async': true,
            }),
          )
          .timeout(const Duration(seconds: 60)),
    );
    return _id(data['task_id'] ?? data['id']);
  });

  String _id(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value;
    throw const MossException('response');
  }

  Future<Map<String, dynamic>> task(String id, String key) => _request(
    () async => _decode(
      await _client
          .get(
            _uri('/audio/tasks/${Uri.encodeComponent(id)}'),
            headers: _headers(key),
          )
          .timeout(const Duration(seconds: 60)),
    ),
  );

  Future<void> deleteFile(String id, String key) => _request(() async {
    final response = await _client
        .delete(
          _uri('/files/${Uri.encodeComponent(id)}'),
          headers: _headers(key),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 404) _check(response.statusCode);
  });

  SttResult parse(Map<String, dynamic> data) {
    final lines = <String>[];
    String? currentSpeaker;
    final segments = data['segments'];
    if (segments is List) {
      for (final segment in segments.whereType<Map>()) {
        final text =
            (segment['text'] is String ? segment['text'] as String : '').trim();
        if (text.isEmpty) continue;
        final speaker = segment['speaker']?.toString().trim();
        if (speaker != null && speaker.isNotEmpty) {
          if (speaker == currentSpeaker && lines.isNotEmpty) {
            lines[lines.length - 1] += ' $text';
          } else {
            lines.add('说话人 $speaker：$text');
          }
        } else {
          lines.add(text);
        }
        currentSpeaker = speaker;
      }
    }
    final text = lines.isNotEmpty
        ? lines.join('\n')
        : (data['text'] is String ? data['text'] as String : '');
    if (text.trim().isEmpty) throw const MossException('empty');
    return SttResult(
      text: text.trim(),
      durationSec: (data['duration'] as num?)?.toDouble(),
      language: data['language'] is String ? data['language'] as String : null,
    );
  }

  void dispose() => _client.close();
}
