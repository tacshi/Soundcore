import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// ECDH (secp256r1) + HKDF + AES-CTR decrypt for D3200 offline files.
///
/// Matches Feishu `KeyManager` / `CryptoManager` / `AesCtrStreamDecrypt`:
/// 1. App generates ECDH P-256 keypair
/// 2. BLE `0x2E/0x01` sends app public key (65-byte uncompressed)
/// 3. Device replies with dev public (65B @9) + shared (32B @74)
/// 4. sessionKey = HKDF-SHA256(ECDH_shared, salt={1,2,3}, info={1,2,3}, 32)
/// 5. Per file head: AES-CTR decrypt encryptFileKey with sessionKey + sessionNonce
///    → must start with ASCII `soundcored3200` then 32-byte fileKey
/// 6. Each 160-B slice: AES-CTR(fileKey, IV = nonce[0:12] ‖ BE(seq*10))
class DeviceCrypto {
  DeviceCrypto();

  static const fileKeyMagic = 'soundcored3200'; // 14 bytes UTF-8

  ECPrivateKey? _privateKey;
  ECPublicKey? _publicKey;
  Uint8List? sessionKey; // 32-byte AES-256 key after handshake
  bool get hasSession => sessionKey != null && sessionKey!.length == 32;

  final Map<String, AesCtrStreamDecrypt> _fileDecryptors = {};

  /// Generate (or re-use) app ECDH keypair. Returns uncompressed public key bytes (65).
  Uint8List ensureKeyPair() {
    if (_privateKey != null && _publicKey != null) {
      return _encodePublic(_publicKey!);
    }
    final domain = ECDomainParameters('secp256r1');
    final secureRandom = _secureRandom();
    final keyGen = ECKeyGenerator()
      ..init(
        ParametersWithRandom(ECKeyGeneratorParameters(domain), secureRandom),
      );
    final pair = keyGen.generateKeyPair();
    _privateKey = pair.privateKey;
    _publicKey = pair.publicKey;
    return _encodePublic(_publicKey!);
  }

  /// Hex form of app public key (Feishu sends hex→bytes of this).
  String get publicKeyHex {
    final pub = ensureKeyPair();
    return _toHex(pub);
  }

  String get privateKeyHex {
    ensureKeyPair();
    final d = _privateKey!.d!;
    return _toHex(_bigIntToBytes(d, 32));
  }

  /// Complete handshake after RX 0x2E/0x01: device pubkey + device shared check.
  bool completeHandshake({
    required Uint8List devicePublicKey,
    required Uint8List deviceSharedKey,
  }) {
    try {
      ensureKeyPair();
      if (devicePublicKey.length < 65) {
        debugPrint(
          '[Crypto] device public key too short: ${devicePublicKey.length}',
        );
        return false;
      }
      final shared = computeEcdhShared(devicePublicKey);
      if (shared == null) return false;

      final sharedHex = _toHex(shared).toUpperCase();
      final deviceHex = _toHex(deviceSharedKey).toUpperCase();
      if (sharedHex != deviceHex) {
        debugPrint('[Crypto] ECDH mismatch app=$sharedHex dev=$deviceHex');
        return false;
      }

      // HKDF with salt={1,2,3}, info={1,2,3}, length=32 (KeyManager.deriveHKDFKey)
      sessionKey = hkdfSha256(
        ikm: shared,
        salt: Uint8List.fromList([1, 2, 3]),
        info: Uint8List.fromList([1, 2, 3]),
        length: 32,
      );
      debugPrint('[Crypto] session key established (${sessionKey!.length} B)');
      return true;
    } catch (e, st) {
      debugPrint('[Crypto] handshake failed: $e\n$st');
      return false;
    }
  }

  /// ECDH shared secret = X coordinate of (priv * peerPub), 32 bytes.
  Uint8List? computeEcdhShared(Uint8List peerPublicUncompressed) {
    try {
      final domain = ECDomainParameters('secp256r1');
      final peer = _decodePublic(domain, peerPublicUncompressed);
      if (peer == null || _privateKey == null) return null;
      final agreement = ECDHBasicAgreement()..init(_privateKey!);
      final secret = agreement.calculateAgreement(peer);
      return _bigIntToBytes(secret, 32);
    } catch (e) {
      debugPrint('[Crypto] ECDH compute failed: $e');
      return null;
    }
  }

  /// initDevDecrypt: unwrap per-file key from header material.
  bool initFileDecrypt({
    required String fileId,
    required Uint8List encryptedFileKey,
    required Uint8List sessionNonce,
    required Uint8List nonce,
  }) {
    if (!hasSession) {
      debugPrint('[Crypto] no session key — run ECDH handshake first');
      return false;
    }
    if (_fileDecryptors.containsKey(fileId)) return true;

    if (sessionNonce.length != 16) {
      debugPrint(
        '[Crypto] sessionNonce must be 16 B, got ${sessionNonce.length}',
      );
      return false;
    }
    final plain = aesCtrDecrypt(
      data: encryptedFileKey,
      key: sessionKey!,
      iv: sessionNonce,
    );
    if (plain == null || plain.length < 46) {
      debugPrint('[Crypto] decrypt fileKey failed (len=${plain?.length})');
      return false;
    }
    final magic = utf8.decode(plain.sublist(0, 14), allowMalformed: true);
    if (magic != fileKeyMagic) {
      debugPrint('[Crypto] fileKey magic mismatch: "$magic"');
      return false;
    }
    final fileKey = plain.sublist(14); // remaining (typically 32)
    if (fileKey.length < 16) {
      debugPrint('[Crypto] fileKey too short: ${fileKey.length}');
      return false;
    }
    // Prefer 32-byte AES-256; if longer, take first 32.
    final key = fileKey.length >= 32
        ? Uint8List.fromList(fileKey.sublist(0, 32))
        : Uint8List.fromList(fileKey);
    final n = nonce.length >= 12
        ? Uint8List.fromList(nonce.sublist(0, min(16, nonce.length)))
        : Uint8List.fromList(nonce);
    _fileDecryptors[fileId] = AesCtrStreamDecrypt(fileKey: key, nonce: n);
    debugPrint('[Crypto] file decryptor ready for $fileId');
    return true;
  }

  /// Decrypt one 160-byte slice for [fileId] at packet [sequence].
  /// Returns null if no decryptor / failure (caller may fall back to raw).
  Uint8List? decryptChunk({
    required String fileId,
    required int sequence,
    required Uint8List data,
  }) {
    final d = _fileDecryptors[fileId];
    if (d == null) return null;
    return d.decryptChunk(data, sequence);
  }

  bool hasFileDecryptor(String fileId) => _fileDecryptors.containsKey(fileId);

  void clearFile(String fileId) => _fileDecryptors.remove(fileId);

  void resetSession() {
    sessionKey = null;
    _fileDecryptors.clear();
  }

  // ── AES-CTR (JCE AES/CTR/NoPadding equivalent) ───────────────────────

  static Uint8List? aesCtrDecrypt({
    required Uint8List data,
    required Uint8List key,
    required Uint8List iv,
  }) {
    try {
      if (key.length != 16 && key.length != 24 && key.length != 32) {
        return null;
      }
      final cipher = SICStreamCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), _padIv(iv)));
      final out = Uint8List(data.length);
      cipher.processBytes(data, 0, data.length, out, 0);
      return out;
    } catch (e) {
      debugPrint('[Crypto] aesCtrDecrypt: $e');
      return null;
    }
  }

  static Uint8List _padIv(Uint8List iv) {
    if (iv.length == 16) return iv;
    final out = Uint8List(16);
    out.setRange(0, min(16, iv.length), iv);
    return out;
  }

  // ── HKDF-SHA256 (extract + expand, SpongyCastle-compatible) ───────────

  static Uint8List hkdfSha256({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) {
    // Extract: PRK = HMAC-SHA256(salt, ikm)
    final extract = HMac(SHA256Digest(), 64)..init(KeyParameter(salt));
    final prk = Uint8List(extract.macSize);
    extract
      ..update(ikm, 0, ikm.length)
      ..doFinal(prk, 0);

    // Expand
    final out = Uint8List(length);
    var t = Uint8List(0);
    var offset = 0;
    var counter = 1;
    while (offset < length) {
      final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(prk));
      mac.update(t, 0, t.length);
      mac.update(info, 0, info.length);
      mac.update(Uint8List.fromList([counter]), 0, 1);
      t = Uint8List(mac.macSize);
      mac.doFinal(t, 0);
      final n = min(t.length, length - offset);
      out.setRange(offset, offset + n, t);
      offset += n;
      counter++;
    }
    return out;
  }

  // ── Encoding helpers ─────────────────────────────────────────────────

  static Uint8List _encodePublic(ECPublicKey pub) {
    // Uncompressed SEC1: 0x04 || X || Y (65 bytes)
    return Uint8List.fromList(pub.Q!.getEncoded(false));
  }

  static ECPublicKey? _decodePublic(ECDomainParameters domain, Uint8List raw) {
    if (raw.isEmpty) return null;
    final bytes = raw.length >= 65 ? raw.sublist(0, 65) : raw;
    if (bytes[0] != 0x04 || bytes.length < 65) {
      // Try as raw X||Y (64) without prefix
      if (bytes.length == 64) {
        final withPrefix = Uint8List.fromList([0x04, ...bytes]);
        final p = domain.curve.decodePoint(withPrefix);
        return p == null ? null : ECPublicKey(p, domain);
      }
      return null;
    }
    final p = domain.curve.decodePoint(bytes);
    return p == null ? null : ECPublicKey(p, domain);
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final raw = Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    if (raw.length == length) return raw;
    if (raw.length > length) return raw.sublist(raw.length - length);
    final out = Uint8List(length);
    out.setRange(length - raw.length, length, raw);
    return out;
  }

  static String _toHex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  static SecureRandom _secureRandom() {
    final rng = FortunaRandom();
    final seed = Uint8List(32);
    final r = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = r.nextInt(256);
    }
    rng.seed(KeyParameter(seed));
    return rng;
  }
}

/// Per-file AES-CTR stream (Feishu `AesCtrStreamDecrypt`).
///
/// IV for sequence [index]: nonce[0..12) ‖ BE_uint32(index * 10)
/// (160-byte chunks = 10 AES blocks each).
class AesCtrStreamDecrypt {
  AesCtrStreamDecrypt({required this.fileKey, required this.nonce});

  final Uint8List fileKey;
  final Uint8List nonce;

  Uint8List buildCounter(int blockIndex) {
    final iv = Uint8List(16);
    final n = min(12, nonce.length);
    iv.setRange(0, n, nonce);
    final c = blockIndex * 10;
    iv[12] = (c >> 24) & 0xFF;
    iv[13] = (c >> 16) & 0xFF;
    iv[14] = (c >> 8) & 0xFF;
    iv[15] = c & 0xFF;
    return iv;
  }

  Uint8List? decryptChunk(Uint8List data, int index) {
    return DeviceCrypto.aesCtrDecrypt(
      data: data,
      key: fileKey,
      iv: buildCounter(index),
    );
  }
}

/// Parsed 1A07 file head (≥97 bytes when encrypted).
class AudioFileSecretKey {
  AudioFileSecretKey({
    required this.fileId,
    required this.fileSize,
    required this.nonce,
    required this.encryptedFileKey,
    required this.sessionNonce,
    this.errorCode = 0,
  });

  final int fileId;
  final int fileSize;
  final Uint8List nonce; // 16
  final Uint8List encryptedFileKey; // 46
  final Uint8List sessionNonce; // 16
  final int errorCode;

  /// Full-frame parse (Feishu `analyzeWifiTransferDataHead`).
  static AudioFileSecretKey? parseFrame(Uint8List raw) {
    if (raw.length < 97) return null;
    int u32(int o) =>
        (raw[o] & 0xFF) |
        ((raw[o + 1] & 0xFF) << 8) |
        ((raw[o + 2] & 0xFF) << 16) |
        ((raw[o + 3] & 0xFF) << 24);

    final fileId = u32(9);
    final fileSize = u32(13);
    final nonce = Uint8List.fromList(raw.sublist(17, 33));
    final encryptedFileKey = Uint8List.fromList(raw.sublist(33, 79));
    final sessionNonce = Uint8List.fromList(raw.sublist(79, 95));
    final err = raw.length > 95 ? raw[95] & 0xFF : 0;
    return AudioFileSecretKey(
      fileId: fileId,
      fileSize: fileSize,
      nonce: nonce,
      encryptedFileKey: encryptedFileKey,
      sessionNonce: sessionNonce,
      errorCode: err,
    );
  }
}
