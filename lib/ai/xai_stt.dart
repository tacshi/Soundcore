import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../audio/ogg_opus.dart';
import 'progress_multipart.dart';
import 'stt_types.dart';

export 'stt_types.dart' show SttResult, SttProvider;

/// Speech-to-text via xAI / SpaceXAI (`POST https://api.x.ai/v1/stt`).
///
/// Batch path: mux raw D3200 Opus → Ogg and upload.
/// Live path: [XaiSttStreamSession] streams PCM16 after Opus decode
/// (`wss://api.x.ai/v1/stt`).
class XaiSttService {
  XaiSttService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Override or set from Settings / env `XAI_API_KEY`.
  String? apiKeyOverride;

  static const _endpoint = 'https://api.x.ai/v1/stt';

  String? get apiKey {
    final o = apiKeyOverride?.trim();
    if (o != null && o.isNotEmpty) return o;
    final env = Platform.environment['XAI_API_KEY']?.trim();
    if (env != null && env.isNotEmpty) return env;
    return null;
  }

  String? get _apiKey => apiKey;

  bool get isConfigured => _apiKey != null;

  /// Transcribe a local raw Opus or Ogg path. Returns plain text.
  Future<SttResult> transcribePath(
    String path, {
    String? language,
    bool format = true,
    SttFileProgressCallback? onProgress,
  }) async {
    final key = _apiKey;
    if (key == null) {
      throw StateError('未配置 XAI_API_KEY。请 export XAI_API_KEY=… 或在应用内设置。');
    }

    onProgress?.call(const SttFileProgress(SttFileStage.preparing));
    final playable = await OggOpus.ensurePlayable(path);
    final file = File(playable);
    if (!await file.exists() || await file.length() < 64) {
      throw StateError('音频太短或无效，无法转写');
    }

    final bytes = await file.readAsBytes();
    final name = playable.split('/').last;

    final req = http.MultipartRequest('POST', Uri.parse(_endpoint));
    req.headers['Authorization'] = 'Bearer $key';
    // Docs: file must be last field in multipart form.
    if (format && language != null && language.isNotEmpty) {
      req.fields['format'] = 'true';
      req.fields['language'] = language;
    } else if (language != null && language.isNotEmpty) {
      req.fields['language'] = language;
    }
    // Multipart: repeat keyterm fields (http.MultipartRequest keeps last if map).
    // Bias toward product terms via single combined keyterm.
    req.fields['keyterm'] = 'soundcore Work';
    req.files.add(
      multipartFileWithProgress(
        field: 'file',
        bytes: bytes,
        filename: name.endsWith('.ogg') ? name : '$name.ogg',
        onProgress: (sent, total) {
          onProgress?.call(
            SttFileProgress(
              SttFileStage.uploading,
              uploadedBytes: sent,
              totalBytes: total,
            ),
          );
          if (sent == total) {
            onProgress?.call(const SttFileProgress(SttFileStage.processing));
          }
        },
      ),
    );

    debugPrint(
      '[STT/xAI] POST $_endpoint file=${bytes.length}B lang=$language',
    );
    final streamed = await _client
        .send(req)
        .timeout(const Duration(seconds: 120));
    onProgress?.call(const SttFileProgress(SttFileStage.fetching));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw StateError('STT HTTP ${streamed.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final text = '${json['text'] ?? ''}'.trim();
    final duration = (json['duration'] as num?)?.toDouble();
    final languageName = json['language'] as String?;
    return SttResult(
      text: text,
      durationSec: duration,
      language: languageName,
      sourcePath: path,
      provider: SttProvider.xai,
    );
  }

  void dispose() {
    _client.close();
  }
}
