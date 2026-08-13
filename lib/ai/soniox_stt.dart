import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../audio/ogg_opus.dart';
import 'progress_multipart.dart';
import 'stt_types.dart';

/// Soniox async (file) STT — upload → create job → poll → transcript.
///
/// Docs: `https://api.soniox.com/v1/files` + `/v1/transcriptions`
class SonioxSttService {
  SonioxSttService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Override or set from env `SONIOX_API_KEY`.
  String? apiKeyOverride;

  static const _base = 'https://api.soniox.com/v1';
  static const _model = 'stt-async-v5';

  String? get apiKey {
    final o = apiKeyOverride?.trim();
    if (o != null && o.isNotEmpty) return o;
    final env = Platform.environment['SONIOX_API_KEY']?.trim();
    if (env != null && env.isNotEmpty) return env;
    return null;
  }

  bool get isConfigured => apiKey != null;

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer ${apiKey!}',
  };

  /// Transcribe a local raw Opus / Ogg path.
  Future<SttResult> transcribePath(
    String path, {
    String? language,
    SttFileProgressCallback? onProgress,
  }) async {
    final key = apiKey;
    if (key == null) {
      throw StateError('未配置 SONIOX_API_KEY。请 export SONIOX_API_KEY=… 或在应用内设置。');
    }

    onProgress?.call(const SttFileProgress(SttFileStage.preparing));
    final playable = await OggOpus.ensurePlayable(path);
    final file = File(playable);
    if (!await file.exists() || await file.length() < 64) {
      throw StateError('音频太短或无效，无法转写');
    }

    final bytes = await file.readAsBytes();
    final name = playable.split('/').last;
    final filename = name.endsWith('.ogg') ? name : '$name.ogg';

    String? fileId;
    String? transcriptionId;
    try {
      fileId = await _uploadFile(bytes, filename, onProgress: onProgress);
      onProgress?.call(const SttFileProgress(SttFileStage.queued));
      transcriptionId = await _createTranscription(
        fileId: fileId,
        language: language,
      );
      await _waitCompleted(transcriptionId, onProgress: onProgress);
      onProgress?.call(const SttFileProgress(SttFileStage.fetching));
      final text = normalizeSttText(await _fetchTranscript(transcriptionId));
      return SttResult(text: text, sourcePath: path, language: language);
    } finally {
      // Best-effort cleanup (Soniox quotas file storage).
      if (transcriptionId != null) {
        unawaited(_delete('$_base/transcriptions/$transcriptionId'));
      }
      if (fileId != null) {
        unawaited(_delete('$_base/files/$fileId'));
      }
    }
  }

  Future<String> _uploadFile(
    Uint8List bytes,
    String filename, {
    SttFileProgressCallback? onProgress,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/files'));
    req.headers.addAll(_authHeaders);
    req.files.add(
      multipartFileWithProgress(
        field: 'file',
        bytes: bytes,
        filename: filename,
        onProgress: (sent, total) => onProgress?.call(
          SttFileProgress(
            SttFileStage.uploading,
            uploadedBytes: sent,
            totalBytes: total,
          ),
        ),
      ),
    );
    debugPrint('[Soniox] upload $filename ${bytes.length}B');
    final streamed = await _client
        .send(req)
        .timeout(const Duration(seconds: 120));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw StateError('Soniox upload HTTP ${streamed.statusCode}: $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) throw StateError('Soniox upload missing id: $body');
    return id;
  }

  Future<String> _createTranscription({
    required String fileId,
    String? language,
  }) async {
    final config = <String, dynamic>{
      'model': _model,
      'file_id': fileId,
      'enable_language_identification': true,
      'enable_speaker_diarization': true,
    };
    if (language != null && language.isNotEmpty && language != 'auto') {
      config['language_hints'] = [language];
    }

    debugPrint('[Soniox] create transcription file_id=$fileId');
    final res = await _client
        .post(
          Uri.parse('$_base/transcriptions'),
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode(config),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Soniox create HTTP ${res.statusCode}: ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) throw StateError('Soniox create missing id: ${res.body}');
    return id;
  }

  Future<void> _waitCompleted(
    String transcriptionId, {
    Duration timeout = const Duration(minutes: 3),
    SttFileProgressCallback? onProgress,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final res = await _client
          .get(
            Uri.parse('$_base/transcriptions/$transcriptionId'),
            headers: _authHeaders,
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('Soniox status HTTP ${res.statusCode}: ${res.body}');
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final status = '${json['status'] ?? ''}';
      if (status == 'completed') return;
      if (status == 'error') {
        throw StateError(
          'Soniox transcription error: ${json['error_message'] ?? res.body}',
        );
      }
      onProgress?.call(
        SttFileProgress(
          status == 'queued' ? SttFileStage.queued : SttFileStage.processing,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    throw TimeoutException('Soniox transcription timeout');
  }

  Future<String> _fetchTranscript(String transcriptionId) async {
    final res = await _client
        .get(
          Uri.parse('$_base/transcriptions/$transcriptionId/transcript'),
          headers: _authHeaders,
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Soniox transcript HTTP ${res.statusCode}: ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final tokens = json['tokens'];
    if (tokens is List) {
      final rendered = renderSonioxTokens(tokens);
      if (rendered.isNotEmpty) return rendered;
    }
    return '${json['text'] ?? ''}'.trim();
  }

  Future<void> _delete(String url) async {
    try {
      await _client
          .delete(Uri.parse(url), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[Soniox] cleanup $url: $e');
    }
  }

  void dispose() {
    _client.close();
  }
}
