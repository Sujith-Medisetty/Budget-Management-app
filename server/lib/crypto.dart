import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-GCM authenticated encryption for refresh tokens.
///
/// Output format: base64( nonce(12) || ciphertext || mac(16) ).
/// 256-bit key, 96-bit nonce, 128-bit tag.
///
/// GCM gives both confidentiality (hides the token) and integrity
/// (detects tampering). If anyone modifies the ciphertext or nonce,
/// `open()` throws instead of decrypting garbage.
class TokenCipher {
  TokenCipher(String hexKey)
      : _key = SecretKey(_hexToBytes(hexKey)),
        _algorithm = AesGcm.with256bits();

  final SecretKey _key;
  final AesGcm _algorithm;

  Future<String> seal(String plaintext) async {
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: _key,
      nonce: nonce,
    );
    final out = BytesBuilder()
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return base64Encode(out.toBytes());
  }

  Future<String> open(String sealed) async {
    final all = base64Decode(sealed);
    final nonce = all.sublist(0, 12);
    final macBytes = all.sublist(all.length - 16);
    final cipherText = all.sublist(12, all.length - 16);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
    final clear = await _algorithm.decrypt(box, secretKey: _key);
    return utf8.decode(clear);
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

