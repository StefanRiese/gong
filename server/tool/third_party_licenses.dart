// Writes the licenses of the packages the server is built from into one text
// file, so release builds can ship the copyright and license notices that
// MIT, BSD and Apache-2.0 require.
//
//   dart run tool/third_party_licenses.dart [OUTPUT]
//
// Needs `dart pub get` first. OUTPUT defaults to THIRD-PARTY-LICENSES.txt.
// Packages come from `dart pub deps --no-dev`, i.e. everything the runtime
// dependency graph pulls in (a superset of what ends up in the binary).

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final out = args.isNotEmpty ? args.first : 'THIRD-PARTY-LICENSES.txt';

  final deps = Process.runSync(Platform.resolvedExecutable, [
    'pub',
    'deps',
    '--no-dev',
    '-s',
    'list',
  ]);
  if (deps.exitCode != 0) {
    stderr.writeln('dart pub deps failed:\n${deps.stderr}');
    exit(1);
  }
  final names = <String>{};
  for (final line in LineSplitter.split(deps.stdout as String)) {
    final m = RegExp(r'^- ([a-z0-9_]+) ').firstMatch(line);
    if (m != null) names.add(m.group(1)!);
  }
  names.remove('lumo_server');

  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    stderr.writeln('.dart_tool/package_config.json missing: run dart pub get');
    exit(1);
  }
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final roots = <String, Uri>{
    for (final p in config['packages'] as List)
      (p as Map)['name'] as String: configFile.uri.resolve('${p['rootUri']}/'),
  };

  final b = StringBuffer()
    ..writeln('Lumo is licensed under the GPL-3.0 (see LICENSE).')
    ..writeln('It is built with the following packages; their license')
    ..writeln('notices follow.')
    ..writeln();
  final missing = <String>[];
  for (final name in (names.toList()..sort())) {
    final root = roots[name];
    File? file;
    if (root != null) {
      for (final n in ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING']) {
        final f = File.fromUri(root.resolve(n));
        if (f.existsSync()) {
          file = f;
          break;
        }
      }
    }
    if (file == null) {
      missing.add(name);
      continue;
    }
    b
      ..writeln('=' * 72)
      ..writeln('$name (https://pub.dev/packages/$name)')
      ..writeln('=' * 72)
      ..writeln(file.readAsStringSync().trim())
      ..writeln();
  }
  if (missing.isNotEmpty) {
    stderr.writeln('No license file found for: ${missing.join(', ')}');
    exit(1);
  }
  File(out).writeAsStringSync(b.toString());
  stdout.writeln('Wrote $out (${names.length} packages)');
}
