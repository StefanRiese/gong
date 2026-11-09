import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 password hashes in the format
/// `pbkdf2-sha256$<iterations>$<salt base64url>$<hash base64url>`.
class PasswordHasher {
  static const prefix = 'pbkdf2-sha256';
  static const defaultIterations = 200000;
  static const _keyLength = 32;

  /// Creates a new hash with a random salt.
  static String hash(String password, {int iterations = defaultIterations}) {
    final rnd = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
    final dk = _pbkdf2(utf8.encode(password), salt, iterations, _keyLength);
    return [prefix, iterations, _b64(salt), _b64(dk)].join(r'$');
  }

  /// True if [encoded] is a well-formed hash this class can verify.
  static bool isValidFormat(String encoded) => _parse(encoded) != null;

  /// Verifies [password] against [encoded] in constant time.
  static bool verify(String password, String encoded) {
    final parsed = _parse(encoded);
    if (parsed == null) return false;
    final (iterations, salt, expected) = parsed;
    final actual = _pbkdf2(
      utf8.encode(password),
      salt,
      iterations,
      expected.length,
    );
    return constantTimeEquals(actual, expected);
  }

  static (int, Uint8List, Uint8List)? _parse(String encoded) {
    final parts = encoded.trim().split(r'$');
    if (parts.length != 4 || parts[0] != prefix) return null;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations < 1) return null;
    try {
      final salt = base64Url.decode(base64Url.normalize(parts[2]));
      final hash = base64Url.decode(base64Url.normalize(parts[3]));
      if (salt.isEmpty || hash.isEmpty) return null;
      return (iterations, salt, hash);
    } on FormatException {
      return null;
    }
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int length,
  ) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder();
    var block = 1;
    while (out.length < length) {
      final blockBytes = [
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];
      var u = hmac.convert([...salt, ...blockBytes]).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
      block++;
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
