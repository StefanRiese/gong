import 'dart:io';

import 'package:lumo_server/src/net/ports.dart';
import 'package:test/test.dart';

void main() {
  test('ports from 1024 are not probed', () async {
    expect(await portProblem(1024), isNull);
    expect(await portProblem(8080), isNull);
  });

  test('a port below 1024 is rejected without the right to use it', () async {
    final root =
        !Platform.isWindows &&
        (await Process.run('id', ['-u'])).stdout.toString().trim() == '0';
    if (root || Platform.isMacOS || Platform.isWindows) return; // allowed there
    expect(await portProblem(81), contains('below 1024'));
  });
}
