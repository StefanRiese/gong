import 'dart:convert';
import 'dart:io';

import 'package:ranzen_server/ranzen_server.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

/// Minimal portal school list (format of exporteur.php?a=schoollist).
const _schoolList = '''
[{"Name": "Darmstadt", "Schulen": [
  {"Id": "1234", "Name": "Musterschule", "Ort": "Darmstadt"},
  {"Id": "5678", "Name": "Beispiel-Gymnasium", "Ort": "Griesheim"}
]}]''';

void main() {
  late Directory dir;
  late FakeGateway gw;
  late List<SphCredentials> logins;
  AppServer? server;
  final client = HttpClient();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sph_server_');
    gw = FakeGateway();
    logins = [];
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    dir.deleteSync(recursive: true);
  });

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<AppServer> start([Map<String, String> env = const {}]) async =>
      server = await AppServer.start(
        {
          'DATA_DIR': dir.path,
          'PORT': '${await freePort()}',
          'SYNC': 'false',
          ...env,
        },
        log: (_, _) {},
        gateway: (c) {
          logins.add(c);
          return gw;
        },
        schools: SchoolDirectory(fetch: () async => _schoolList),
        passwordIterations: 10,
      );

  Future<({int status, Map<String, dynamic> body, HttpHeaders headers})> call(
    String method,
    String path, {
    Object? json,
    String? token,
    String? cookie,
  }) async {
    final req = await client.openUrl(
      method,
      server!.localUrl.resolve(path.substring(1)),
    );
    if (token != null) req.headers.set('x-setup-token', token);
    if (cookie != null) req.headers.set('cookie', cookie);
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final body = text.isEmpty
        ? <String, dynamic>{}
        : switch (jsonDecode(text)) {
            final Map<String, dynamic> m => m,
            final List<dynamic> l => {'list': l},
            _ => <String, dynamic>{},
          };
    return (status: res.statusCode, body: body, headers: res.headers);
  }

  String tokenOf(AppServer s) => s.setupUrl!.queryParameters['token']!;

  String cookieOf(HttpHeaders h) => h.value('set-cookie')!.split(';').first;

  Future<String> completeSetup(AppServer s) async {
    final r = await call(
      'PUT',
      '/api/server-settings',
      token: tokenOf(s),
      json: {
        'settings': {
          'SPH_SCHOOL_ID': '1234',
          'SPH_USERNAME': 'max.muster',
          'SPH_PASSWORD': 'geheim',
        },
        'appPassword': 'web-passwort',
      },
    );
    expect(r.status, 200, reason: '${r.body}');
    return cookieOf(r.headers);
  }

  group('setup mode', () {
    test('starts without credentials; only the setup page works', () async {
      final s = await start();
      expect(s.setupRequired, isTrue);
      expect(s.setupUrl!.path, '/einrichtung');
      expect(
        File('${dir.path}/setup-token').readAsStringSync().trim(),
        tokenOf(s),
      );

      expect((await call('GET', '/api/setup')).body, {'setupRequired': true});
      expect((await call('GET', '/api/timetable')).status, 503);
      final login = await call(
        'POST',
        '/api/auth/login',
        json: {'password': 'x'},
      );
      expect(login.body['error']['code'], 'setup_required');

      expect((await call('GET', '/api/server-settings')).status, 403);
      expect(
        (await call('GET', '/api/server-settings', token: 'falsch')).status,
        403,
      );
      final settings = await call(
        'GET',
        '/api/server-settings',
        token: tokenOf(s),
      );
      expect(settings.status, 200);
      expect(settings.body['setupRequired'], isTrue);
      expect(settings.body['secrets'], {
        'SPH_PASSWORD': false,
        'NTFY_TOKEN': false,
        'APP_PASSWORD': false,
      });
      expect(settings.body['values']['PORT'], s.port);
    });

    test('school search by name, town or number', () async {
      final s = await start();
      var r = await call('GET', '/api/schools?q=gries', token: tokenOf(s));
      expect(r.body['list'], [
        {'id': 5678, 'name': 'Beispiel-Gymnasium', 'city': 'Griesheim'},
      ]);
      r = await call('GET', '/api/schools?q=1234', token: tokenOf(s));
      expect((r.body['list'] as List).single['name'], 'Musterschule');
      expect((await call('GET', '/api/schools?q=x')).status, 403);
    });

    test('wrong Schulportal credentials are rejected', () async {
      final s = await start();
      gw.loginErrors.add(const SphAuthException('Wrong username or password'));
      final r = await call(
        'PUT',
        '/api/server-settings',
        token: tokenOf(s),
        json: {
          'settings': {'SPH_USERNAME': 'max.muster', 'SPH_PASSWORD': 'falsch'},
          'appPassword': 'web-passwort',
        },
      );
      expect(r.status, 400);
      expect(r.body['error']['code'], 'sph_login_failed');
      expect(s.setupRequired, isTrue);
    });

    test('completing the setup logs in and starts normal operation', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      expect(s.setupRequired, isFalse);
      expect(s.setupUrl, isNull);
      expect(File('${dir.path}/setup-token').existsSync(), isFalse);
      expect(logins.last.schoolId, 1234);
      expect(logins.last.username, 'max.muster');

      final tt = await call('GET', '/api/timetable', cookie: cookie);
      expect(tt.status, 200);
      expect(tt.body['data']['currentWeek'], 'B');

      // Token no longer accepted, login required instead.
      expect(
        (await call('GET', '/api/server-settings', token: tokenOf2(s))).status,
        401,
      );
      final settings = await call(
        'GET',
        '/api/server-settings',
        cookie: cookie,
      );
      expect(settings.body['values']['SPH_USERNAME'], 'max.muster');
      expect(settings.body['secrets']['SPH_PASSWORD'], isTrue);
      expect(settings.body['sources']['SPH_USERNAME'], 'web');
      expect(jsonEncode(settings.body), isNot(contains('geheim')));
    });

    test('install.sh --configure marker gives config.env precedence', () async {
      var s = await start();
      await completeSetup(s);
      await s.stop();
      File(
        '${dir.path}/reset-web-settings',
      ).writeAsStringSync('SPH_USERNAME\nSPH_PASSWORD\n');
      s = await start({'SPH_USERNAME': 'aus.datei', 'SPH_PASSWORD': 'pw'});
      expect(s.config.sph.username, 'aus.datei');
      expect(s.config.sph.schoolId, 1234, reason: 'not listed: web value');
      expect(File('${dir.path}/reset-web-settings').existsSync(), isFalse);
    });

    test('settings survive a restart', () async {
      var s = await start();
      final cookie = await completeSetup(s);
      await call('GET', '/api/timetable', cookie: cookie);
      await s.stop();

      s = await start();
      expect(s.setupRequired, isFalse);
      expect(s.config.sph.username, 'max.muster');
      final tt = await call('GET', '/api/timetable', cookie: cookie);
      expect(tt.body['cached'], isTrue, reason: 'cache restored from the DB');
    });
  });

  group('server settings', () {
    late AppServer s;
    late String cookie;

    setUp(() async {
      s = await start();
      cookie = await completeSetup(s);
    });

    test('notifications can be switched on without restart', () async {
      var n = await call('GET', '/api/notifications', cookie: cookie);
      expect(n.body['enabled'], isFalse);
      final r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'NTFY_TOPIC': 'sph-test-123', 'NOTIFY': 'homework'},
        },
      );
      expect(r.status, 200);
      expect(r.body['restartRequired'], isEmpty);
      n = await call('GET', '/api/notifications', cookie: cookie);
      expect(n.body['enabled'], isTrue);
      expect(n.body['kinds'], ['homework']);
    });

    test('invalid values are reported, nothing is stored', () async {
      final r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'POLL_INTERVAL_MINUTES': '1', 'ACTIVE_HOURS': 'nachts'},
        },
      );
      expect(r.status, 400);
      expect(r.body['error']['code'], 'invalid_settings');
      expect(r.body['error']['problems'], hasLength(2));
      expect(s.config.sync.interval, const Duration(minutes: 15));

      final unknown = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'APP_PASSWORD_HASH': 'x'},
        },
      );
      expect(unknown.status, 400);
    });

    test('network settings need a restart', () async {
      final r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'PORT': '8123'},
        },
      );
      expect(r.body['restartRequired'], ['PORT']);
      final d = await call('GET', '/api/server-settings', cookie: cookie);
      expect(d.body['values']['PORT'], 8123);
      expect(d.body['restartRequired'], ['PORT']);
    });

    test(
      'password change needs the current password, logs out others',
      () async {
        final other = cookieOf(
          (await call(
            'POST',
            '/api/auth/login',
            json: {'password': 'web-passwort'},
          )).headers,
        );
        var r = await call(
          'PUT',
          '/api/server-settings',
          cookie: cookie,
          json: {'appPassword': 'neues-passwort', 'currentPassword': 'falsch'},
        );
        expect(r.status, 403);

        r = await call(
          'PUT',
          '/api/server-settings',
          cookie: cookie,
          json: {
            'appPassword': 'neues-passwort',
            'currentPassword': 'web-passwort',
          },
        );
        expect(r.status, 200);
        expect((await call('GET', '/api/auth/me', cookie: cookie)).body, {
          'authenticated': true,
        });
        expect((await call('GET', '/api/auth/me', cookie: other)).body, {
          'authenticated': false,
        });
        final login = await call(
          'POST',
          '/api/auth/login',
          json: {'password': 'neues-passwort'},
        );
        expect(login.status, 200);
      },
    );

    test('another account clears the cached data', () async {
      await call('GET', '/api/timetable', cookie: cookie);
      expect(
        (await call('GET', '/api/timetable', cookie: cookie)).body['cached'],
        isTrue,
      );
      final r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'SPH_USERNAME': 'erika.muster', 'SPH_PASSWORD': 'pw2'},
        },
      );
      expect(r.body['accountChanged'], isTrue);
      expect(
        (await call('GET', '/api/timetable', cookie: cookie)).body['cached'],
        isFalse,
      );
    });

    test('test login uses the stored password if none is given', () async {
      var r = await call(
        'POST',
        '/api/server-settings/test-login',
        cookie: cookie,
        json: {'schoolId': 1234, 'username': 'max.muster'},
      );
      expect(r.body, {'ok': true});
      expect(logins.last.password, 'geheim');

      gw.loginErrors.add(const SphAuthException('Wrong username or password'));
      r = await call(
        'POST',
        '/api/server-settings/test-login',
        cookie: cookie,
        json: {'schoolId': 1234, 'username': 'max.muster', 'password': 'x'},
      );
      expect(r.body['error']['code'], 'sph_login_failed');
    });
  });
}

/// The token of a server that is no longer in setup mode (any value).
String tokenOf2(AppServer s) => 'beliebig';
