import 'dart:io';

import 'package:schulportal_server/schulportal_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sph_config_');
    file = File('${dir.path}/config.env');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('hashPlainPasswordInFile', () {
    test('replaces APP_PASSWORD with APP_PASSWORD_HASH', () {
      file.writeAsStringSync(
        'SPH_USERNAME=u\nAPP_PASSWORD="geheim 123"\nAPP_PASSWORD_HASH=\nPORT=8080\n',
      );
      expect(hashPlainPasswordInFile(file.path, iterations: 10), isTrue);

      final env = <String, String>{
        for (final l in file.readAsLinesSync())
          if (parseEnvLine(l) case final e?) e.key: e.value,
      };
      expect(env['APP_PASSWORD'], '');
      expect(
        PasswordHasher.verify('geheim 123', env['APP_PASSWORD_HASH']!),
        isTrue,
      );
      expect(env['PORT'], '8080');
      expect(file.existsSync(), isTrue);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('adds the hash line if missing and keeps CRLF line endings', () {
      file.writeAsStringSync('APP_PASSWORD=geheim123\r\nHOST=127.0.0.1\r\n');
      expect(hashPlainPasswordInFile(file.path, iterations: 10), isTrue);
      final text = file.readAsStringSync();
      expect(text, contains('APP_PASSWORD=\r\nAPP_PASSWORD_HASH=pbkdf2'));
      expect(text.replaceAll('\r\n', ''), isNot(contains('\n')));
    });

    test('a new APP_PASSWORD replaces an existing hash', () {
      final old = PasswordHasher.hash('alt-passwort', iterations: 10);
      file.writeAsStringSync(
        'APP_PASSWORD_HASH=$old\nAPP_PASSWORD=neu-passwort\n',
      );
      expect(hashPlainPasswordInFile(file.path, iterations: 10), isTrue);
      final hash = parseEnvLine(file.readAsLinesSync().first)!.value;
      expect(PasswordHasher.verify('neu-passwort', hash), isTrue);
    });

    test('leaves the file alone without (valid) APP_PASSWORD', () {
      for (final content in ['APP_PASSWORD=\n', 'APP_PASSWORD=kurz\n', '']) {
        file.writeAsStringSync(content);
        expect(hashPlainPasswordInFile(file.path), isFalse);
        expect(file.readAsStringSync(), content);
      }
      expect(hashPlainPasswordInFile('${dir.path}/missing.env'), isFalse);
    });
  });

  group('desktopConfigTemplate', () {
    test('is incomplete until filled in, then valid', () {
      file.writeAsStringSync(desktopConfigTemplate(dataDir: dir.path));
      expect(
        () => AppConfig.fromEnv(_fileEnv(file)),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.problems,
            'problems',
            hasLength(2), // SPH credentials, app password
          ),
        ),
      );

      final filled = file
          .readAsStringSync()
          .replaceFirst('SPH_USERNAME=\n', 'SPH_USERNAME=max.muster\n')
          .replaceFirst('SPH_PASSWORD=\n', 'SPH_PASSWORD=x\n')
          .replaceFirst('APP_PASSWORD=\n', 'APP_PASSWORD=geheim123\n');
      file.writeAsStringSync(filled);
      final c = AppConfig.fromEnv(_fileEnv(file));
      expect(c.dataDir, dir.path);
      expect(c.openBrowser, isTrue);
      expect(c.ntfy, isNull);
      expect(PasswordHasher.verify('geheim123', c.appPasswordHash), isTrue);
    });

    test('uses the requested line endings', () {
      final t = desktopConfigTemplate(dataDir: r'C:\x', eol: '\r\n');
      expect(t, contains('DATA_DIR=C:\\x\r\n'));
      expect(t.replaceAll('\r\n', ''), isNot(contains('\n')));
    });
  });
}

/// Only the file's values (not the test process environment).
Map<String, String> _fileEnv(File f) => {
  for (final l in f.readAsLinesSync())
    if (parseEnvLine(l) case final e?) e.key: e.value,
};
