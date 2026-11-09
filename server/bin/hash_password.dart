// Creates APP_PASSWORD_HASH for the web UI login.
//
// Usage (from server/):
//   dart run bin/hash_password.dart          # prompts for the password
//   echo -n secret | dart run bin/hash_password.dart --stdin

import 'dart:convert';
import 'dart:io';

import 'package:ranzen_server/ranzen_server.dart';

Future<void> main(List<String> args) async {
  final String password;
  if (args.contains('--stdin')) {
    password = (await stdin.transform(utf8.decoder).join()).trimRight();
  } else {
    password = _prompt('Password: ');
    final again = _prompt('Repeat:   ');
    if (password != again) {
      stderr.writeln('Passwords do not match.');
      exit(1);
    }
  }
  if (password.length < 8) {
    stderr.writeln('Use at least 8 characters.');
    exit(1);
  }
  stdout.writeln('APP_PASSWORD_HASH=${PasswordHasher.hash(password)}');
}

String _prompt(String label) {
  stderr.write(label);
  final interactive = stdin.hasTerminal;
  if (interactive) stdin.echoMode = false;
  try {
    return stdin.readLineSync() ?? '';
  } finally {
    if (interactive) {
      stdin.echoMode = true;
      stderr.writeln();
    }
  }
}
