import 'dart:convert';
import 'dart:typed_data';

import 'package:anker_recorder/crypto/device_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HKDF-SHA256 length and determinism', () {
    final ikm = Uint8List.fromList(List.generate(32, (i) => i));
    final salt = Uint8List.fromList([1, 2, 3]);
    final info = Uint8List.fromList([1, 2, 3]);
    final a = DeviceCrypto.hkdfSha256(
      ikm: ikm,
      salt: salt,
      info: info,
      length: 32,
    );
    final b = DeviceCrypto.hkdfSha256(
      ikm: ikm,
      salt: salt,
      info: info,
      length: 32,
    );
    expect(a.length, 32);
    expect(a, b);
  });

  test('AES-CTR roundtrip', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final iv = Uint8List.fromList(List.generate(16, (i) => i));
    final plain = Uint8List.fromList(utf8.encode('hello soundcore work!!'));
    final enc = DeviceCrypto.aesCtrDecrypt(data: plain, key: key, iv: iv);
    // CTR encrypt == decrypt (XOR stream)
    expect(enc, isNotNull);
    final dec = DeviceCrypto.aesCtrDecrypt(data: enc!, key: key, iv: iv);
    expect(dec, plain);
  });

  test('AesCtrStreamDecrypt counter uses index*10', () {
    final nonce = Uint8List.fromList(List.generate(16, (i) => i));
    final key = Uint8List.fromList(List.generate(32, (i) => 0xA0 + (i % 16)));
    final d = AesCtrStreamDecrypt(fileKey: key, nonce: nonce);
    final c0 = d.buildCounter(0);
    final c1 = d.buildCounter(1);
    expect(c0.sublist(0, 12), nonce.sublist(0, 12));
    expect(c0[15], 0);
    expect(c1[15], 10); // 1*10
    expect(c1[14], 0);
  });

  test('ECDH keypair + shared secret agrees both ways', () {
    final a = DeviceCrypto();
    final b = DeviceCrypto();
    final pubA = a.ensureKeyPair();
    final pubB = b.ensureKeyPair();
    expect(pubA.length, 65);
    expect(pubA[0], 0x04);
    final sharedA = a.computeEcdhShared(pubB)!;
    final sharedB = b.computeEcdhShared(pubA)!;
    expect(sharedA, sharedB);
    expect(sharedA.length, 32);

    final ok = a.completeHandshake(
      devicePublicKey: pubB,
      deviceSharedKey: sharedA,
    );
    expect(ok, isTrue);
    expect(a.hasSession, isTrue);
  });

  test('initFileDecrypt requires soundcored3200 magic', () {
    final a = DeviceCrypto();
    final b = DeviceCrypto();
    a.ensureKeyPair();
    final pubB = b.ensureKeyPair();
    final shared = a.computeEcdhShared(pubB)!;
    // Force session via handshake with B's public
    expect(
      a.completeHandshake(devicePublicKey: pubB, deviceSharedKey: shared),
      isTrue,
    );

    final sessionNonce = Uint8List.fromList(List.generate(16, (i) => i + 3));
    final nonce = Uint8List.fromList(List.generate(16, (i) => 20 + i));
    final fileKey = Uint8List.fromList(List.generate(32, (i) => 50 + i));
    final plainKey = Uint8List.fromList([
      ...utf8.encode(DeviceCrypto.fileKeyMagic),
      ...fileKey,
    ]);
    // Encrypt file key material with session AES-CTR
    final encKey = DeviceCrypto.aesCtrDecrypt(
      data: plainKey,
      key: a.sessionKey!,
      iv: sessionNonce,
    )!;

    final ok = a.initFileDecrypt(
      fileId: '12345',
      encryptedFileKey: encKey,
      sessionNonce: sessionNonce,
      nonce: nonce,
    );
    expect(ok, isTrue);

    final chunk = Uint8List.fromList(List.generate(160, (i) => i & 0xFF));
    final cipher = a.decryptChunk(fileId: '12345', sequence: 0, data: chunk);
    // decrypt of random with real key yields non-null stream
    expect(cipher, isNotNull);
    expect(cipher!.length, 160);
    // re-encrypt == original for CTR
    final again = a.decryptChunk(fileId: '12345', sequence: 0, data: cipher);
    expect(again, chunk);
  });
}
