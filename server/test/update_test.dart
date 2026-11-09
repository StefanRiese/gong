import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:schulportal_server/schulportal_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

const _base =
    'https://github.com/StefanRiese/schulportal-client/releases/download/v0.7.0';

/// Fake GitHub: release JSON and assets.
class FakeGitHub {
  final Map<Uri, List<int>> files = {};
  final requested = <Uri>[];
  String tag = 'v0.7.0';

  FakeGitHub() {
    final exe = utf8.encode('new exe');
    files[Uri.parse('$_base/schulportal-client-windows-x64.exe')] = exe;
    files[Uri.parse('$_base/schulportal-client-windows-x64.exe.sha256')] = utf8
        .encode('${sha256.convert(exe)}  schulportal-client-windows-x64.exe\n');
  }

  Future<List<int>> get(Uri url) async {
    requested.add(url);
    if (url == UpdateService.latestUrl) {
      return utf8.encode(
        jsonEncode({
          'tag_name': tag,
          'body': '### Added\n- Neu',
          'html_url':
              'https://github.com/StefanRiese/schulportal-client/releases/tag/$tag',
          'published_at': '2026-11-10T08:00:00Z',
          'assets': [
            for (final u in files.keys)
              {'name': u.pathSegments.last, 'browser_download_url': '$u'},
          ],
        }),
      );
    }
    final body = files[url];
    if (body == null) throw HttpException('404', uri: url);
    return body;
  }
}

Future<void> settle(UpdateService u) async {
  for (var i = 0; i < 100; i++) {
    final phase = u.status()['phase'];
    if (phase != 'downloading' && phase != 'installing') return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory dir;
  late FakeGitHub gh;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sph_update_');
    gh = FakeGitHub();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  UpdateService service(
    UpdateMode mode, {
    String? version = 'v0.6.0',
    Future<void> Function()? onReady,
  }) => UpdateService(
    currentVersion: version,
    mode: mode,
    dataDir: dir.path,
    executable: '${dir.path}/schulportal-client.exe',
    onReadyToRestart: onReady,
    get: gh.get,
  );

  test('versions compare by number; git describe counts as newer', () {
    final v = Version.tryParse;
    expect(v('v0.10.0')! > v('v0.9.9')!, isTrue);
    expect(v('v0.6.0-3-gabc123')! > v('v0.6.0')!, isTrue);
    expect(v('v0.7.0')! > v('v0.6.0-3-gabc123')!, isTrue);
    expect(v('0.6.0')!.compareTo(v('v0.6.0')!), 0);
    expect(v('dev'), isNull);
    expect(v(null), isNull);
  });

  test('check finds a newer release', () async {
    final u = service(UpdateMode.manual);
    expect(u.status()['available'], isFalse);
    await u.check();
    final s = u.status();
    expect(s['latest'], 'v0.7.0');
    expect(s['available'], isTrue);
    expect(s['notes'], contains('Neu'));
    expect(s['canInstall'], isFalse, reason: 'manual mode: notice only');
    expect(s['checkedAt'], isNotNull);

    gh.tag = 'v0.6.0';
    await u.check();
    expect(u.status()['available'], isFalse);
  });

  test('development builds never offer an install', () async {
    final u = service(UpdateMode.windows, version: null);
    await u.check();
    expect(u.status()['available'], isFalse);
    expect(u.canInstall, isFalse);
  });

  test('check errors are reported', () async {
    final u = UpdateService(
      currentVersion: 'v0.6.0',
      mode: UpdateMode.manual,
      dataDir: dir.path,
      get: (_) async => throw const SocketException('offline'),
    );
    await u.check();
    expect(u.status()['checkError'], 'Update-Server nicht erreichbar');
  });

  test(
    'systemd: writes the update request; install.sh reports failures',
    () async {
      final u = service(UpdateMode.systemd);
      await u.check();
      u.install();
      await settle(u);
      expect(
        File('${dir.path}/update-request').readAsStringSync().trim(),
        'v0.7.0',
      );
      expect(u.status()['phase'], 'restarting');

      File(
        '${dir.path}/update-result',
      ).writeAsStringSync('failed: Installation von v0.7.0 fehlgeschlagen\n');
      final s = u.status();
      expect(s['phase'], 'failed');
      expect(s['error'], 'Installation von v0.7.0 fehlgeschlagen');
      expect(u.canInstall, isTrue, reason: 'can be tried again');
    },
  );

  test('windows: verifies, swaps the exe and restarts', () async {
    File('${dir.path}/schulportal-client.exe').writeAsStringSync('old exe');
    var restarted = false;
    final u = service(
      UpdateMode.windows,
      onReady: () async => restarted = true,
    );
    await u.check();
    u.install();
    await settle(u);
    expect(restarted, isTrue);
    expect(
      File('${dir.path}/schulportal-client.exe').readAsStringSync(),
      'new exe',
    );
    expect(
      File('${dir.path}/schulportal-client.exe.old').readAsStringSync(),
      'old exe',
    );

    service(UpdateMode.windows).cleanUp();
    expect(
      File('${dir.path}/schulportal-client.exe.old').existsSync(),
      isFalse,
    );
  });

  test('windows: a wrong checksum leaves the exe alone', () async {
    File('${dir.path}/schulportal-client.exe').writeAsStringSync('old exe');
    gh.files[Uri.parse('$_base/schulportal-client-windows-x64.exe.sha256')] =
        utf8.encode('${'0' * 64}  x\n');
    var restarted = false;
    final u = service(
      UpdateMode.windows,
      onReady: () async => restarted = true,
    );
    await u.check();
    u.install();
    await settle(u);
    expect(u.status()['phase'], 'failed');
    expect(u.status()['error'], contains('Prüfsumme'));
    expect(restarted, isFalse);
    expect(
      File('${dir.path}/schulportal-client.exe').readAsStringSync(),
      'old exe',
    );
  });

  test('downloads only from github.com over https', () async {
    gh.files[Uri.parse(
      'https://example.org/schulportal-client-windows-x64.exe',
    )] = [
      1,
    ];
    gh.files.remove(Uri.parse('$_base/schulportal-client-windows-x64.exe'));
    final u = service(UpdateMode.windows);
    await u.check();
    u.install();
    await settle(u);
    expect(u.status()['error'], 'Unerwartete Download-Adresse');
  });

  group('API', () {
    late SphService sph;
    late Api api;
    late UpdateService u;
    final hash = PasswordHasher.hash('richtig123', iterations: 10);

    setUp(() {
      sph = SphService(FakeGateway());
      u = service(UpdateMode.systemd);
      api = Api(service: sph, passwordHash: hash)..update = u;
    });

    tearDown(() => sph.dispose());

    Future<Response> call(String method, String path, [String? cookie]) async =>
        await api.handler(
          Request(
            method,
            Uri.parse('http://localhost$path'),
            headers: {'cookie': ?cookie},
            body: method == 'POST' && path.endsWith('login')
                ? '{"password":"richtig123"}'
                : null,
          ).change(
            headers: path.endsWith('login')
                ? {'content-type': 'application/json'}
                : {},
          ),
        );

    test('status, check and install need a login', () async {
      expect((await call('GET', '/api/update')).statusCode, 401);
      expect((await call('POST', '/api/update/install')).statusCode, 401);
      final login = await call('POST', '/api/auth/login');
      final cookie = login.headers['set-cookie']!.split(';').first;

      var r = await call('POST', '/api/update/install', cookie);
      expect(r.statusCode, 409, reason: 'nothing found yet');

      r = await call('POST', '/api/update/check', cookie);
      final s = jsonDecode(await r.readAsString()) as Map;
      expect(
        (s['current'], s['latest'], s['canInstall']),
        ('v0.6.0', 'v0.7.0', true),
      );

      r = await call('POST', '/api/update/install', cookie);
      expect(r.statusCode, 202);
      await settle(u);
      expect(File('${dir.path}/update-request').existsSync(), isTrue);
    });
  });
}
