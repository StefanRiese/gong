import 'dart:convert';
import 'dart:io';

import 'package:lumo_server/lumo_server.dart';
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

  /// Sets up the server like the setup page: first account, then the web
  /// password. [account] adds fields to the account (e.g. a Caseda login).
  Future<String> completeSetup(
    AppServer s, {
    Map<String, Object?> account = const {},
  }) async {
    var r = await call(
      'POST',
      '/api/accounts',
      token: tokenOf(s),
      json: {
        'name': 'Max',
        'schoolId': 1234,
        'username': 'max.muster',
        'password': 'geheim',
        ...account,
      },
    );
    expect(r.status, 201, reason: '${r.body}');
    expect(s.setupRequired, isTrue, reason: 'the web password is missing');
    r = await call(
      'PUT',
      '/api/server-settings',
      token: tokenOf(s),
      json: {'appPassword': 'web-passwort'},
    );
    expect(r.status, 200, reason: '${r.body}');
    return cookieOf(r.headers);
  }

  /// Id of the first account.
  Future<String> firstId(String cookie) async =>
      ((await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
                  as List)
              .first['id']
          as String;

  test(
    'HOST 0.0.0.0 also listens on IPv6 (mDNS names resolve to IPv6)',
    () async {
      final s = await start({'HOST': '0.0.0.0'});
      final port = s.localUrl.port;
      for (final host in ['127.0.0.1', '[::1]']) {
        final req = await client.getUrl(
          Uri.parse('http://$host:$port/healthz'),
        );
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 200, reason: host);
      }
    },
    skip: _noIpv6() ? 'no IPv6 loopback here' : false,
  );

  group('setup mode', () {
    test('starts without account; only the setup page works', () async {
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
      expect((await call('POST', '/api/accounts', json: {})).status, 403);
      final settings = await call(
        'GET',
        '/api/server-settings',
        token: tokenOf(s),
      );
      expect(settings.status, 200);
      expect(settings.body['setupRequired'], isTrue);
      expect(settings.body['secrets'], {
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
        'POST',
        '/api/accounts',
        token: tokenOf(s),
        json: {'username': 'max.muster', 'password': 'falsch'},
      );
      expect(r.status, 400);
      expect(r.body['error']['code'], 'sph_login_failed');
      expect(s.setupRequired, isTrue);
      expect(s.accountCount, 0);
    });

    test('account and web password together end the setup', () async {
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
      final accounts = await call('GET', '/api/accounts', cookie: cookie);
      final account = (accounts.body['accounts'] as List).single as Map;
      expect(account['name'], 'Max');
      expect(account['schoolId'], 1234);
      expect(account['username'], 'max.muster');
      expect(account['caseda'], isNull);
      expect(account['untis'], isNull);
      expect(jsonEncode(accounts.body), isNot(contains('geheim')));
    });

    test('the web password first, then the account, also ends it', () async {
      final s = await start();
      var r = await call(
        'PUT',
        '/api/server-settings',
        token: tokenOf(s),
        json: {'appPassword': 'web-passwort'},
      );
      expect(r.status, 200, reason: '${r.body}');
      expect(s.setupRequired, isTrue, reason: 'no account yet');
      r = await call(
        'POST',
        '/api/accounts',
        token: tokenOf(s),
        json: {'username': 'max.muster', 'password': 'geheim'},
      );
      expect(r.status, 201, reason: '${r.body}');
      expect(r.body['name'], 'max.muster', reason: 'default: the user name');
      expect(s.setupRequired, isFalse);
      expect(
        r.headers.value('set-cookie'),
        startsWith('sph_session='),
        reason: 'logged in right away',
      );
    });

    test('install.sh --configure marker gives config.env precedence', () async {
      var s = await start();
      await completeSetup(s);
      expect(
        (await call(
          'PUT',
          '/api/server-settings',
          cookie: cookieOf(
            (await call(
              'POST',
              '/api/auth/login',
              json: {'password': 'web-passwort'},
            )).headers,
          ),
          json: {
            'settings': {'NTFY_TOPIC': 'aus-dem-web', 'APP_URL': 'http://web/'},
          },
        )).status,
        200,
      );
      await s.stop();
      File('${dir.path}/reset-web-settings').writeAsStringSync('NTFY_TOPIC\n');
      s = await start({'NTFY_TOPIC': 'aus-der-datei'});
      expect(s.config.ntfy?.topic, 'aus-der-datei');
      expect(s.config.appUrl.toString(), 'http://web/', reason: 'not listed');
      expect(File('${dir.path}/reset-web-settings').existsSync(), isFalse);
    });

    test('settings and accounts survive a restart', () async {
      var s = await start();
      final cookie = await completeSetup(s);
      await call('GET', '/api/timetable', cookie: cookie);
      await s.stop();

      s = await start();
      expect(s.setupRequired, isFalse);
      expect(s.accountCount, 1);
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
  });

  group('WebUntis (second source)', () {
    const untisLogin = {
      'server': 'https://schule.webuntis.com/timetable/x',
      'username': 'klasse5e',
      'password': 'richtig',
    };

    test('not set up: off, no sync task', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      final accounts = await call('GET', '/api/accounts', cookie: cookie);
      expect((accounts.body['accounts'] as List).single['untis'], isNull);
      final sync = await call('GET', '/api/sync', cookie: cookie);
      expect((sync.body['tasks'] as Map).keys, isNot(contains('untis')));
    });

    test('set up on the account: login tested, task added', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      final id = await firstId(cookie);

      untis.error = const UntisException('bad', isAuth: true);
      var r = await call(
        'PUT',
        '/api/accounts/$id',
        cookie: cookie,
        json: {
          'untis': {...untisLogin, 'password': 'falsch'},
        },
      );
      expect(r.status, 400);
      expect(r.body['error']['code'], 'untis_login_failed');
      expect(
        ((await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
                as List)
            .single['untis'],
        isNull,
      );

      untis.error = null;
      r = await call(
        'PUT',
        '/api/accounts/$id',
        cookie: cookie,
        json: {'untis': untisLogin},
      );
      expect(r.status, 200, reason: '${r.body}');
      expect(untisLogins.last.server, 'schule.webuntis.com');
      expect(untisLogins.last.school, 'schule', reason: 'from the host name');
      expect(r.body['untis'], {
        'server': 'schule.webuntis.com',
        'school': 'schule',
        'username': 'klasse5e',
      });
      expect(jsonEncode(r.body), isNot(contains('richtig')));
      final sync = await call('GET', '/api/sync', cookie: cookie);
      expect((sync.body['tasks'] as Map).keys, contains('untis'));
    });

    test('incomplete or invalid logins are refused', () async {
      final s = await start();
      final cookie = await completeSetup(s);
      final id = await firstId(cookie);
      for (final untisJson in [
        {'server': 'schule.webuntis.com'},
        {'server': 'ohne punkt', 'username': 'a', 'password': 'b'},
      ]) {
        final r = await call(
          'PUT',
          '/api/accounts/$id',
          cookie: cookie,
          json: {'untis': untisJson},
        );
        expect(r.status, 400);
        expect(r.body['error']['code'], 'invalid_settings');
      }
    });

    test(
      'a changed login keeps the stored password; null removes it',
      () async {
        final s = await start();
        final cookie = await completeSetup(
          s,
          account: {
            'untis': {
              'server': 'schule.webuntis.com',
              'school': 'meine-schule',
              'username': 'klasse5e',
              'password': 'gespeichert',
            },
          },
        );
        final id = await firstId(cookie);
        expect(untisLogins.last.school, 'meine-schule');

        var r = await call(
          'PUT',
          '/api/accounts/$id',
          cookie: cookie,
          json: {
            'untis': {'username': 'klasse6e'},
          },
        );
        expect(r.status, 200, reason: '${r.body}');
        expect(untisLogins.last.username, 'klasse6e');
        expect(untisLogins.last.password, 'gespeichert');
        expect(untisLogins.last.school, 'meine-schule');

        r = await call(
          'PUT',
          '/api/accounts/$id',
          cookie: cookie,
          json: {'untis': null},
        );
        expect(r.status, 200);
        expect(r.body['untis'], isNull);
        final sync = await call('GET', '/api/sync', cookie: cookie);
        expect((sync.body['tasks'] as Map).keys, isNot(contains('untis')));
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
    });

    test(
      'set up on the account: login tested, then balance and orders',
      () async {
        final s = await start();
        final cookie = await completeSetup(s);
        final id = await firstId(cookie);

        meals.error = const CasedaException('wrong', isAuth: true);
        var r = await call(
          'PUT',
          '/api/accounts/$id',
          cookie: cookie,
          json: {
            'caseda': {'username': 'eltern@example.org', 'password': 'falsch'},
          },
        );
        expect(r.status, 400);
        expect(r.body['error']['code'], 'meals_login_failed');
        expect((await call('GET', '/api/meals', cookie: cookie)).status, 404);

        meals.error = null;
        r = await call(
          'PUT',
          '/api/accounts/$id',
          cookie: cookie,
          json: {
            'caseda': {'username': 'eltern@example.org', 'password': 'richtig'},
          },
        );
        expect(r.status, 200, reason: '${r.body}');
        expect(mealsLogins.last.username, 'eltern@example.org');
        expect(jsonEncode(r.body), isNot(contains('richtig')));
        expect(r.body['caseda'], {
          'url': 'https://www.caseda-schulmenue.de',
          'username': 'eltern@example.org',
        });

        // The warning amount is a server setting for all accounts.
        expect(
          (await call(
            'PUT',
            '/api/server-settings',
            cookie: cookie,
            json: {
              'settings': {'CASEDA_BALANCE_WARNING': '7,50'},
            },
          )).status,
          200,
        );
        r = await call('GET', '/api/meals', cookie: cookie);
        expect(r.status, 200);
        expect(r.body['data']['balanceCents'], 1230);
        expect((r.body['data']['orders'] as List).single['name'], 'Nudeln');
        expect(r.body['balanceWarningCents'], 750);
        expect(r.body['key'], 'meals');

        final sync = await call('GET', '/api/sync', cookie: cookie);
        expect((sync.body['tasks'] as Map).keys, contains('meals'));
      },
    );

    test('removing the login switches the meals off', () async {
      final s = await start();
      final cookie = await completeSetup(
        s,
        account: {
          'caseda': {'username': 'eltern@example.org', 'password': 'pw'},
        },
      );
      final id = await firstId(cookie);
      expect((await call('GET', '/api/meals', cookie: cookie)).status, 200);

      final r = await call(
        'PUT',
        '/api/accounts/$id',
        cookie: cookie,
        json: {'caseda': null},
      );
      expect(r.status, 200);
      expect(
        (await call('GET', '/api/meals', cookie: cookie)).body['error']['code'],
        'meals_disabled',
      );
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

bool _noIpv6() {
  try {
    return !File('/proc/net/if_inet6').readAsStringSync().contains(' lo');
  } on Object {
    return false;
  }
}
