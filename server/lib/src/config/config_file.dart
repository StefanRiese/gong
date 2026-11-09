import 'dart:io';

import '../auth/password.dart';
import 'env.dart';

/// Replaces a plain-text `APP_PASSWORD=…` in the config file at [path] with
/// `APP_PASSWORD_HASH=…`, so the password is not stored in clear text.
///
/// Returns true if the file was changed. Throws [FileSystemException] if the
/// file cannot be written (the server then hashes the password in memory).
bool hashPlainPasswordInFile(String path, {int? iterations}) {
  final file = File(path);
  if (!file.existsSync()) return false;
  final lines = file.readAsLinesSync();

  int? plainLine, hashLine;
  String? plain;
  for (var i = 0; i < lines.length; i++) {
    final entry = parseEnvLine(lines[i]);
    if (entry == null) continue;
    if (entry.key == 'APP_PASSWORD' && entry.value.isNotEmpty) {
      plainLine = i;
      plain = entry.value;
    } else if (entry.key == 'APP_PASSWORD_HASH') {
      hashLine = i;
    }
  }
  // Too short: leave it, AppConfig reports the problem.
  if (plain == null || plain.length < 8) return false;

  final hash = iterations == null
      ? PasswordHasher.hash(plain)
      : PasswordHasher.hash(plain, iterations: iterations);
  lines[plainLine!] = 'APP_PASSWORD=';
  if (hashLine != null) {
    lines[hashLine] = 'APP_PASSWORD_HASH=$hash';
  } else {
    lines.insert(plainLine + 1, 'APP_PASSWORD_HASH=$hash');
  }

  final tmp = File('$path.tmp');
  tmp.writeAsStringSync('${lines.join(_eol(file))}${_eol(file)}', flush: true);
  tmp.renameSync(path);
  return true;
}

/// Keeps Windows line endings in files edited with Notepad.
String _eol(File file) =>
    file.readAsStringSync().contains('\r\n') ? '\r\n' : '\n';
