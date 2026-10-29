import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../audio/audio_duration.dart';
import '../audio/ogg_opus.dart';
import 'stt_types.dart';

class ChinaSttException implements Exception {
  const ChinaSttException(this.provider, this.code, {this.detail});
  final String provider;
  final String code;
  final String? detail;
  String get message => switch (code) {
    'credentials' => '$provider 凭证无效，请在设置中按「AppID:密钥」格式填写',
    'audio' => '无法读取录音，请重新下载',
    'too_large' => '录音过大，$provider 无法处理',
    'network' => '无法连接 $provider，请检查网络后重试',
    'timeout' => '$provider 转写超时，请稍后重试',
    'empty' => '未识别到语音，可重试',
    _ => '$provider 转写失败${detail == null ? '' : '（$detail）'}，请重试',
  };
  @override
  String toString() => 'ChinaSttException($provider, $code, $detail)';
}

/// Credentials are stored as a single "AppID:Secret" string.
({String appId, String secret})? parseAppCredential(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final index = raw.indexOf(':');
  if (index <= 0 || index == raw.length - 1) return null;
  return (
    appId: raw.substring(0, index).trim(),
    secret: raw.substring(index + 1).trim(),
  );
}

Future<String> _prepareOgg(String provider, String path) async {
  final file = File(path);
  if (!await file.exists() || await file.length() < 64) {
    throw ChinaSttException(provider, 'audio');
  }
  if (!path.endsWith('.opus')) return path;
  return OggOpus.ensurePlayable(path);
}

Future<T> _guard<T>(String provider, Future<T> Function() action) async {
  try {
    return await action();
  } on TimeoutException {
    throw ChinaSttException(provider, 'network');
  } on SocketException {
    throw ChinaSttException(provider, 'network');
  } on http.ClientException {
    throw ChinaSttException(provider, 'network');
  }
}

/// iFlytek 录音文件转写 (raasr v2): upload the file, then poll the order.
class XfyunSttService {
  XfyunSttService({http.Client? client}) : _client = client ?? http.Client();
  static const label = '讯飞';
  static const _base = 'https://raasr.xfyun.cn/v2/api';
  final http.Client _client;
  String? credentialOverride;
  String? get credential => credentialOverride;
  bool get isConfigured => parseAppCredential(credential) != null;

  Map<String, String> _auth(String appId, String secret) {
    final ts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final md5Hex = md5.convert(utf8.encode('$appId$ts')).toString();
    final signa = base64.encode(
      Hmac(sha1, utf8.encode(secret)).convert(utf8.encode(md5Hex)).bytes,
    );
    return {'appId': appId, 'ts': ts, 'signa': signa};
  }

  Map<String, dynamic> _content(http.Response response) {
    Map<String, dynamic>? data;
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map<String, dynamic>) data = value;
    } on FormatException {
      /* Fall through. */
    }
    final code = data?['code']?.toString();
    if (data == null || code != '000000') {
      final failure = data?['descInfo']?.toString();
      throw ChinaSttException(
        label,
        code == '26600' || code == '26601' || code == '26602'
            ? 'credentials'
            : 'response',
        detail: failure ?? 'HTTP ${response.statusCode}',
      );
    }
    final content = data['content'];
    return content is Map<String, dynamic> ? content : const {};
  }

  Future<SttResult> transcribePath(
    String path, {
    String? credentialValue,
    SttFileProgressCallback? onProgress,
  }) => _guard(label, () async {
    final cred = parseAppCredential(credentialValue ?? credential);
    if (cred == null) throw const ChinaSttException(label, 'credentials');
    final audioPath = await _prepareOgg(label, path);
    final file = File(audioPath);
    final bytes = await file.readAsBytes();
    if (bytes.length > 500 * 1024 * 1024) {
      throw const ChinaSttException(label, 'too_large');
    }
    final duration = await AudioDuration.read(audioPath);
    onProgress?.call(
      SttFileProgress(
        SttFileStage.uploading,
        uploadedBytes: 0,
        totalBytes: bytes.length,
      ),
    );
    final uploadUri = Uri.parse('$_base/upload').replace(
      queryParameters: {
        ..._auth(cred.appId, cred.secret),
        'fileName': 'recording.ogg',
        'fileSize': '${bytes.length}',
        'duration': '${math.max(1000, duration?.inMilliseconds ?? 60000)}',
        'language': 'cn',
        'roleType': '1',
      },
    );
    final upload = _content(
      await _client
          .post(
            uploadUri,
            headers: {'Content-Type': 'application/octet-stream'},
            body: bytes,
          )
          .timeout(const Duration(minutes: 20)),
    );
    final orderId = upload['orderId']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw const ChinaSttException(label, 'response');
    }
    onProgress?.call(const SttFileProgress(SttFileStage.processing));
    final deadline = DateTime.now().add(const Duration(hours: 2));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final result = _content(
        await _client
            .post(
              Uri.parse('$_base/getResult').replace(
                queryParameters: {
                  ..._auth(cred.appId, cred.secret),
                  'orderId': orderId,
                  'resultType': 'transfer',
                },
              ),
            )
            .timeout(const Duration(seconds: 60)),
      );
      final info = result['orderInfo'];
      final status = info is Map ? info['status'] : null;
      if (status == -1) {
        throw ChinaSttException(
          label,
          'response',
          detail: info is Map ? 'failType ${info['failType']}' : null,
        );
      }
      if (status == 4) {
        onProgress?.call(const SttFileProgress(SttFileStage.fetching));
        return SttResult(
          text: _parseOrderResult(result['orderResult']),
          durationSec: duration == null ? null : duration.inMilliseconds / 1000,
          language: 'zh',
        );
      }
    }
    throw const ChinaSttException(label, 'timeout');
  });

  static String _parseOrderResult(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      throw const ChinaSttException(label, 'empty');
    }
    final lines = <String>[];
    String? currentSpeaker;
    final lattice = (jsonDecode(raw) as Map)['lattice'];
    if (lattice is List) {
      for (final item in lattice.whereType<Map>()) {
        final best = item['json_1best'];
        final st = (best is String ? jsonDecode(best) : best)?['st'];
        if (st is! Map) continue;
        final buffer = StringBuffer();
        for (final rt in (st['rt'] as List? ?? const []).whereType<Map>()) {
          for (final ws in (rt['ws'] as List? ?? const []).whereType<Map>()) {
            final cw = ws['cw'];
            if (cw is List && cw.isNotEmpty && cw.first is Map) {
              buffer.write((cw.first as Map)['w'] ?? '');
            }
          }
        }
        final text = buffer.toString().trim();
        if (text.isEmpty) continue;
        final speaker = st['rl']?.toString();
        if (speaker != null && speaker != '0') {
          if (speaker == currentSpeaker && lines.isNotEmpty) {
            lines[lines.length - 1] += text;
          } else {
            lines.add('说话人 $speaker：$text');
          }
        } else {
          lines.add(text);
        }
        currentSpeaker = speaker;
      }
    }
    final text = lines.join('\n').trim();
    if (text.isEmpty) throw const ChinaSttException(label, 'empty');
    return text;
  }

  void dispose() => _client.close();
}

/// Volcengine 大模型录音文件识别极速版: one request with inline audio.
class VolcSttService {
  VolcSttService({http.Client? client}) : _client = client ?? http.Client();
  static const label = '火山引擎';
  static final _uri = Uri.parse(
    'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
  );
  final http.Client _client;
  String? credentialOverride;
  String? get credential => credentialOverride;
  bool get isConfigured => parseAppCredential(credential) != null;

  static String _requestId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<SttResult> transcribePath(
    String path, {
    String? credentialValue,
    SttFileProgressCallback? onProgress,
  }) => _guard(label, () async {
    final cred = parseAppCredential(credentialValue ?? credential);
    if (cred == null) throw const ChinaSttException(label, 'credentials');
    final audioPath = await _prepareOgg(label, path);
    final bytes = await File(audioPath).readAsBytes();
    if (bytes.length > 100 * 1024 * 1024) {
      throw const ChinaSttException(label, 'too_large');
    }
    onProgress?.call(
      SttFileProgress(
        SttFileStage.uploading,
        uploadedBytes: 0,
        totalBytes: bytes.length,
      ),
    );
    final response = await _client
        .post(
          _uri,
          headers: {
            'Content-Type': 'application/json',
            'X-Api-App-Key': cred.appId,
            'X-Api-Access-Key': cred.secret,
            'X-Api-Resource-Id': 'volc.bigasr.auc_turbo',
            'X-Api-Request-Id': _requestId(),
            'X-Api-Sequence': '-1',
          },
          body: jsonEncode({
            'user': {'uid': cred.appId},
            'audio': {'data': base64.encode(bytes)},
            'request': {
              'model_name': 'bigmodel',
              'enable_itn': true,
              'enable_punc': true,
            },
          }),
        )
        .timeout(const Duration(minutes: 20));
    final status = response.headers['x-api-status-code'];
    if (status == '20000003') throw const ChinaSttException(label, 'empty');
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        status == '45000010') {
      throw const ChinaSttException(label, 'credentials');
    }
    if (status != '20000000') {
      throw ChinaSttException(
        label,
        'response',
        detail:
            response.headers['x-api-message'] ??
            status ??
            'HTTP ${response.statusCode}',
      );
    }
    onProgress?.call(const SttFileProgress(SttFileStage.fetching));
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final result = data is Map ? data['result'] : null;
    final lines = <String>[];
    final utterances = result is Map ? result['utterances'] : null;
    if (utterances is List) {
      for (final u in utterances.whereType<Map>()) {
        final text = (u['text'] ?? '').toString().trim();
        if (text.isNotEmpty) lines.add(text);
      }
    }
    final text = lines.isNotEmpty
        ? lines.join('\n')
        : (result is Map ? (result['text'] ?? '').toString() : '');
    if (text.trim().isEmpty) throw const ChinaSttException(label, 'empty');
    final durationMs = data is Map && data['audio_info'] is Map
        ? (data['audio_info']['duration'] as num?)
        : null;
    return SttResult(
      text: text.trim(),
      durationSec: durationMs == null ? null : durationMs / 1000,
      language: 'zh',
    );
  });

  void dispose() => _client.close();
}
