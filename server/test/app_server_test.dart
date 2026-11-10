import 'dart:convert';
import 'dart:io';

import 'package:gong_server/gong_server.dart';
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
  late FakeMeals meals;
  late List<CasedaConfig> mealsLogins;
  late FakeUntis untis;
  late List<UntisConfig> untisLogins;
  AppServer? server;
  final client = HttpClient();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sph_server_');
    gw = FakeGateway();
    logins = [];
    meals = FakeMeals();
    mealsLogins = [];
    untis = FakeUntis();
    untisLogins = [];
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
        mealsGateway: (c) {
          mealsLogins.add(c);
          return meals;
        },
        untisGateway: (c) {
          untisLogins.add(c);
          return untis;
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
        'CASEDA_PASSWORD': false,
        'UNTIS_PASSWORD': false,
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

  group('WebUntis (second source)', () {
    test('not set up: off, no sync task', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      final d = await call('GET', '/api/server-settings', cookie: cookie);
      expect(d.body['values']['UNTIS_ENABLED'], isFalse);
      expect(d.body['secrets']['UNTIS_PASSWORD'], isFalse);
      final sync = await call('GET', '/api/sync', cookie: cookie);
      expect((sync.body['tasks'] as Map).keys, isNot(contains('untis')));
    });

    test('set up in the settings: login tested, task added', () async {
      final s = await start();
      final cookie = await completeSetup(s);

      untis.error = const UntisException('bad', isAuth: true);
      var r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {
            'UNTIS_SERVER': 'https://schule.webuntis.com/timetable/x',
            'UNTIS_USERNAME': 'klasse5e',
            'UNTIS_PASSWORD': 'falsch',
          },
        },
      );
      expect(r.status, 400);
      expect(r.body['error']['code'], 'untis_login_failed');
      expect(s.config.untis, isNull);

      untis.error = null;
      r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {
            'UNTIS_SERVER': 'https://schule.webuntis.com/timetable/x',
            'UNTIS_USERNAME': 'klasse5e',
            'UNTIS_PASSWORD': 'richtig',
          },
        },
      );
      expect(r.status, 200, reason: '${r.body}');
      expect(untisLogins.last.server, 'schule.webuntis.com');
      expect(untisLogins.last.school, 'schule', reason: 'from the host name');

      final d = await call('GET', '/api/server-settings', cookie: cookie);
      expect(d.body['values']['UNTIS_ENABLED'], isTrue);
      expect(d.body['values']['UNTIS_SERVER'], 'schule.webuntis.com');
      expect(d.body['values']['UNTIS_USERNAME'], 'klasse5e');
      expect(d.body['secrets']['UNTIS_PASSWORD'], isTrue);
      expect(jsonEncode(d.body), isNot(contains('richtig')));
      final sync = await call('GET', '/api/sync', cookie: cookie);
      expect((sync.body['tasks'] as Map).keys, contains('untis'));
    });

    test('incomplete or invalid settings are refused', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      for (final settings in [
        {'UNTIS_SERVER': 'schule.webuntis.com'},
        {
          'UNTIS_SERVER': 'ohne punkt',
          'UNTIS_USERNAME': 'a',
          'UNTIS_PASSWORD': 'b',
        },
      ]) {
        final r = await call(
          'PUT',
          '/api/server-settings',
          cookie: cookie,
          json: {'settings': settings},
        );
        expect(r.status, 400);
        expect(r.body['error']['code'], 'invalid_settings');
      }
    });

    test('switched off and on again: login is kept', () async {
      final s = await start({
        'UNTIS_SERVER': 'schule.webuntis.com',
        'UNTIS_SCHOOL': 'meine-schule',
        'UNTIS_USERNAME': 'klasse5e',
        'UNTIS_PASSWORD': 'gespeichert',
      });
      final cookie = await completeSetup(s);
      expect(s.config.untis?.school, 'meine-schule');

      var r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'UNTIS_ENABLED': 'false'},
        },
      );
      expect(r.status, 200);
      expect(s.config.untis, isNull);
      final d = await call('GET', '/api/server-settings', cookie: cookie);
      expect(d.body['values']['UNTIS_ENABLED'], isFalse);
      expect(d.body['values']['UNTIS_USERNAME'], 'klasse5e');
      expect(d.body['secrets']['UNTIS_PASSWORD'], isTrue);

      final before = untisLogins.length;
      r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'UNTIS_ENABLED': 'true'},
        },
      );
      expect(r.status, 200);
      expect(untisLogins.length, greaterThan(before), reason: 'login tested');
      expect(s.config.untis?.password, 'gespeichert');
    });

    test(
      'test login answers with the class; stored password is used',
      () async {
        final s = await start({
          'UNTIS_SERVER': 'schule.webuntis.com',
          'UNTIS_USERNAME': 'klasse5e',
          'UNTIS_PASSWORD': 'gespeichert',
        });
        final cookie = await completeSetup(s);
        var r = await call(
          'POST',
          '/api/server-settings/test-untis',
          cookie: cookie,
          json: {'server': 'schule.webuntis.com', 'username': 'klasse5e'},
        );
        expect(r.body, {'ok': true, 'className': '05eG'});
        expect(untisLogins.last.password, 'gespeichert');

        untis.error = const UntisException('down');
        r = await call(
          'POST',
          '/api/server-settings/test-untis',
          cookie: cookie,
          json: {'server': 'schule.webuntis.com', 'username': 'klasse5e'},
        );
        expect(r.status, 503);
        expect(r.body['error']['code'], 'untis_unavailable');

        r = await call(
          'POST',
          '/api/server-settings/test-untis',
          cookie: cookie,
          json: {'server': 'kein host', 'username': 'x'},
        );
        expect(r.status, 400);
      },
    );
  });

  group('school meals (Caseda)', () {
    test('not set up: /api/meals answers meals_disabled', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      final r = await call('GET', '/api/meals', cookie: cookie);
      expect(r.status, 404);
      expect(r.body['error']['code'], 'meals_disabled');
      final d = await call('GET', '/api/server-settings', cookie: cookie);
      expect(d.body['values']['CASEDA_ENABLED'], isFalse);
    });

    test(
      'set up in the settings: login tested, then balance and orders',
      () async {
        final s = await start();
        final cookie = await completeSetup(s);

        meals.error = const CasedaException('wrong', isAuth: true);
        var r = await call(
          'PUT',
          '/api/server-settings',
          cookie: cookie,
          json: {
            'settings': {
              'CASEDA_USERNAME': 'eltern@example.org',
              'CASEDA_PASSWORD': 'falsch',
            },
          },
        );
        expect(r.status, 400);
        expect(r.body['error']['code'], 'meals_login_failed');
        expect(s.config.caseda, isNull);

        meals.error = null;
        r = await call(
          'PUT',
          '/api/server-settings',
          cookie: cookie,
          json: {
            'settings': {
              'CASEDA_USERNAME': 'eltern@example.org',
              'CASEDA_PASSWORD': 'richtig',
              'CASEDA_BALANCE_WARNING': '7,50',
            },
          },
        );
        expect(r.status, 200, reason: '${r.body}');
        expect(mealsLogins.last.username, 'eltern@example.org');

        r = await call('GET', '/api/meals', cookie: cookie);
        expect(r.status, 200);
        expect(r.body['data']['balanceCents'], 1230);
        expect((r.body['data']['orders'] as List).single['name'], 'Nudeln');
        expect(r.body['balanceWarningCents'], 750);
        expect(r.body['key'], 'meals');

        final d = await call('GET', '/api/server-settings', cookie: cookie);
        expect(d.body['values']['CASEDA_ENABLED'], isTrue);
        expect(d.body['values']['CASEDA_USERNAME'], 'eltern@example.org');
        expect(d.body['secrets']['CASEDA_PASSWORD'], isTrue);
        expect(jsonEncode(d.body), isNot(contains('richtig')));

        final sync = await call('GET', '/api/sync', cookie: cookie);
        expect((sync.body['tasks'] as Map).keys, contains('meals'));
      },
    );

    test('switched off and on again: login is kept', () async {
      final s = await start({
        'CASEDA_USERNAME': 'eltern@example.org',
        'CASEDA_PASSWORD': 'gespeichert',
      });
      final cookie = await completeSetup(s);
      expect(s.config.caseda, isNotNull);

      var r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'CASEDA_ENABLED': 'false'},
        },
      );
      expect(r.status, 200);
      expect(s.config.caseda, isNull);
      expect(
        (await call('GET', '/api/meals', cookie: cookie)).body['error']['code'],
        'meals_disabled',
      );
      final d = await call('GET', '/api/server-settings', cookie: cookie);
      expect(d.body['values']['CASEDA_ENABLED'], isFalse);
      expect(d.body['values']['CASEDA_USERNAME'], 'eltern@example.org');
      expect(d.body['secrets']['CASEDA_PASSWORD'], isTrue);

      final before = mealsLogins.length;
      r = await call(
        'PUT',
        '/api/server-settings',
        cookie: cookie,
        json: {
          'settings': {'CASEDA_ENABLED': 'true'},
        },
      );
      expect(r.status, 200);
      expect(mealsLogins.length, greaterThan(before), reason: 'login tested');
      expect(s.config.caseda?.password, 'gespeichert');
      expect((await call('GET', '/api/meals', cookie: cookie)).status, 200);
    });

    test('test login with the stored password', () async {
      final s = await start({
        'CASEDA_USERNAME': 'eltern@example.org',
        'CASEDA_PASSWORD': 'gespeichert',
      });
      final cookie = await completeSetup(s);
      final r = await call(
        'POST',
        '/api/server-settings/test-caseda',
        cookie: cookie,
        json: {'username': 'eltern@example.org'},
      );
      expect(r.body, {'ok': true});
      expect(mealsLogins.last.password, 'gespeichert');
    });
  });
}

/// The token of a server that is no longer in setup mode (any value).
String tokenOf2(AppServer s) => 'beliebig';

/// Fake Caseda: a fixed snapshot, or an error.
class FakeMeals implements MealsGateway {
  Object? error;

  @override
  Uri? get orderUrl => null;

  @override
  Future<MealsSnapshot> load(DateTime today) async {
    if (error != null) throw error!;
    return MealsSnapshot(
      balanceCents: 1230,
      orders: [
        MealOffer(
          date: DateTime(2026, 11, 10),
          line: 'Menü 1',
          name: 'Nudeln',
          allergens: const ['a'],
          priceCents: 390,
          ordered: 1,
          deadlinePassed: true,
        ),
      ],
    );
  }
}

/// Fake WebUntis: a fixed snapshot, or an error.
class FakeUntis implements UntisGateway {
  Object? error;

  @override
  Future<UntisSnapshot> load(DateTime today) async {
    if (error != null) throw error!;
    return UntisSnapshot(className: '05eG', changes: const []);
  }
}
