import 'dart:convert';
import 'dart:io';

import 'package:lumo_server/lumo_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

void main() {
  late Directory dir;
  late Map<String, FakeGateway> gateways; // by username
  late List<SphCredentials> logins;
  AppServer? server;
  final client = HttpClient();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lumo_accounts_');
    gateways = {};
    logins = [];
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    dir.deleteSync(recursive: true);
  });

  /// Gateway of [username]; the first account sees all portal areas, the
  /// others no calendar (to tell the accounts apart).
  FakeGateway gatewayFor(String username) => gateways.putIfAbsent(username, () {
    final g = FakeGateway();
    if (username != 'max.muster') g.applets.remove('kalender.php');
    return g;
  });

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<AppServer> start() async => server = await AppServer.start(
    {
      'DATA_DIR': dir.path,
      'PORT': '${await freePort()}',
      'SYNC': 'false',
      'SPH_SCHOOL_ID': '1234',
      'SPH_USERNAME': 'max.muster',
      'SPH_PASSWORD': 'geheim',
      'APP_PASSWORD': 'web-passwort',
    },
    log: (_, _) {},
    gateway: (c) {
      logins.add(c);
      return gatewayFor(c.username);
    },
    passwordIterations: 10,
  );

  Future<({int status, Map<String, dynamic> body, HttpHeaders headers})> call(
    String method,
    String path, {
    Object? json,
    String? cookie,
  }) async {
    final req = await client.openUrl(
      method,
      server!.localUrl.resolve(path.substring(1)),
    );
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

  Future<String> login() async {
    final r = await call(
      'POST',
      '/api/auth/login',
      json: {'password': 'web-passwort'},
    );
    expect(r.status, 200, reason: '${r.body}');
    return r.headers.value('set-cookie')!.split(';').first;
  }

  Map<String, Object?> anna([Map<String, Object?> more = const {}]) => {
    'name': 'Anna',
    'schoolId': 1234,
    'username': 'anna.muster',
    'password': 'annas-passwort',
    ...more,
  };

  Future<String> addAnna(String cookie, [Map<String, Object?>? data]) async {
    final r = await call(
      'POST',
      '/api/accounts',
      cookie: cookie,
      json: data ?? anna(),
    );
    expect(r.status, 201, reason: '${r.body}');
    return r.body['id'] as String;
  }

  List<String> cacheKeys() {
    final db = sqlite3.open('${dir.path}/lumo.db');
    try {
      return [
        for (final r in db.select('SELECT key FROM cache')) r['key'] as String,
      ];
    } finally {
      db.close();
    }
  }

  test('starts with the one account; the list needs a login', () async {
    await start();
    expect((await call('GET', '/api/accounts')).status, 401);
    final cookie = await login();
    final r = await call('GET', '/api/accounts', cookie: cookie);
    expect(r.status, 200);
    expect(r.body['accounts'], [
      {
        'id': 'main',
        'name': 'max.muster',
        'primary': true,
        'schoolId': 1234,
        'username': 'max.muster',
      },
    ]);
  });

  test('adding an account tries its login and never shows passwords', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);
    expect(id, matches(RegExp(r'^[a-z0-9]{6}$')));
    expect(
      logins.map((c) => c.username),
      contains('anna.muster'),
      reason: 'login tested',
    );

    final list =
        (await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
            as List;
    expect(list.map((a) => a['name']), ['max.muster', 'Anna']);
    expect(list[1]['id'], id);
    expect(list[1]['primary'], isFalse);
    expect(jsonEncode(list), isNot(contains('annas-passwort')));
  });

  test('adding fails for a wrong login, invalid data and duplicates', () async {
    await start();
    final cookie = await login();
    gatewayFor(
      'anna.muster',
    ).loginErrors.add(const SphAuthException('Falsches Passwort'));
    var r = await call('POST', '/api/accounts', cookie: cookie, json: anna());
    expect(r.status, 400);
    expect(r.body['error']['code'], 'sph_login_failed');

    r = await call(
      'POST',
      '/api/accounts',
      cookie: cookie,
      json: anna({'name': '', 'password': ''}),
    );
    expect(r.status, 400);
    expect(r.body['error']['code'], 'invalid_settings');

    // The first account again (same school, user name in other case).
    r = await call(
      'POST',
      '/api/accounts',
      cookie: cookie,
      json: anna({'username': 'MAX.muster'}),
    );
    expect(r.status, 400);
    expect(r.body['error']['problems'], hasLength(1));

    expect(
      ((await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
              as List)
          .length,
      1,
      reason: 'nothing was stored',
    );
  });

  test('data of the accounts is kept apart', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);

    List<dynamic> features(Map<String, dynamic> r) => r['data']['features'];
    final main = await call('GET', '/api/account', cookie: cookie);
    final mainScoped = await call(
      'GET',
      '/api/accounts/main/account',
      cookie: cookie,
    );
    final child = await call(
      'GET',
      '/api/accounts/$id/account',
      cookie: cookie,
    );
    expect(features(main.body), contains('calendar'));
    expect(features(mainScoped.body), contains('calendar'));
    expect(features(child.body), isNot(contains('calendar')));

    // Both timetables are cached, each under its own key.
    await call('GET', '/api/timetable', cookie: cookie);
    await call('GET', '/api/accounts/$id/timetable', cookie: cookie);
    expect(cacheKeys(), containsAll(['timetable', '@$id/timetable']));
  });

  test('user settings are per account', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);
    final put = await call(
      'PUT',
      '/api/accounts/$id/settings',
      cookie: cookie,
      json: {
        'subjectColors': {'Kunst': '#ff8800'},
      },
    );
    expect(put.status, 200, reason: '${put.body}');
    expect(
      (await call(
        'GET',
        '/api/accounts/$id/settings',
        cookie: cookie,
      )).body['subjectColors'],
      {'Kunst': '#ff8800'},
    );
    expect(
      (await call(
        'GET',
        '/api/settings',
        cookie: cookie,
      )).body['subjectColors'],
      isEmpty,
    );
  });

  test('endpoints need a login, an existing account and a data area', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);
    expect((await call('GET', '/api/accounts/$id/timetable')).status, 401);
    var r = await call('GET', '/api/accounts/nope/timetable', cookie: cookie);
    expect(r.status, 404);
    expect(r.body['error']['code'], 'unknown_account');
    r = await call('GET', '/api/accounts/$id/server-settings', cookie: cookie);
    expect(r.status, 404);
    expect(r.body['error']['code'], 'not_found');
  });

  test('accounts and their cache survive a restart', () async {
    await start();
    var cookie = await login();
    final id = await addAnna(cookie);
    await call('GET', '/api/accounts/$id/timetable', cookie: cookie);
    await server!.stop();

    await start();
    cookie = await login();
    final list =
        (await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
            as List;
    expect(list.map((a) => a['id']), ['main', id]);
    final r = await call('GET', '/api/accounts/$id/timetable', cookie: cookie);
    expect(r.status, 200);
    expect(r.body['cached'], isTrue);
  });

  test('changing an account: name keeps data, other user resets it', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);
    await call('GET', '/api/accounts/$id/timetable', cookie: cookie);
    await call(
      'PUT',
      '/api/accounts/$id/settings',
      cookie: cookie,
      json: {
        'subjectColors': {'Kunst': '#ff8800'},
      },
    );
    final loginsBefore = logins.length;

    var r = await call(
      'PUT',
      '/api/accounts/$id',
      cookie: cookie,
      json: {'name': 'Anna M.'},
    );
    expect(r.status, 200, reason: '${r.body}');
    expect(r.body['name'], 'Anna M.');
    expect(logins.length, loginsBefore, reason: 'no new login for a rename');
    expect(cacheKeys(), contains('@$id/timetable'));

    r = await call(
      'PUT',
      '/api/accounts/$id',
      cookie: cookie,
      json: {'username': 'ben.muster', 'password': 'bens-passwort'},
    );
    expect(r.status, 200, reason: '${r.body}');
    expect(logins.last.username, 'ben.muster');
    expect(cacheKeys(), isNot(contains('@$id/timetable')));
    expect(
      (await call(
        'GET',
        '/api/accounts/$id/settings',
        cookie: cookie,
      )).body['subjectColors'],
      isEmpty,
    );

    r = await call('PUT', '/api/accounts/nope', cookie: cookie, json: {});
    expect(r.status, 404);
  });

  test('the first account only takes a name', () async {
    await start();
    final cookie = await login();
    var r = await call(
      'PUT',
      '/api/accounts/main',
      cookie: cookie,
      json: {'name': 'Max'},
    );
    expect(r.status, 200, reason: '${r.body}');
    expect(r.body['name'], 'Max');
    r = await call(
      'PUT',
      '/api/accounts/main',
      cookie: cookie,
      json: {'username': 'x'},
    );
    expect(r.status, 400);
    expect(
      ((await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
          as List)[0]['name'],
      'Max',
    );
  });

  test('removing an account deletes its data; the first stays', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);
    await call('GET', '/api/accounts/$id/timetable', cookie: cookie);
    await call('GET', '/api/timetable', cookie: cookie);

    var r = await call('DELETE', '/api/accounts/main', cookie: cookie);
    expect(r.status, 400);
    r = await call('DELETE', '/api/accounts/nope', cookie: cookie);
    expect(r.status, 404);

    r = await call('DELETE', '/api/accounts/$id', cookie: cookie);
    expect(r.status, 204);
    expect(
      (await call('GET', '/api/accounts/$id/timetable', cookie: cookie)).status,
      404,
    );
    expect(cacheKeys(), ['timetable']);
    expect(gateways['anna.muster']!.disposed, isTrue);
    expect(
      ((await call('GET', '/api/accounts', cookie: cookie)).body['accounts']
              as List)
          .length,
      1,
    );
  });

  test('server settings changes reach the further accounts', () async {
    await start();
    final cookie = await login();
    final id = await addAnna(cookie);
    expect(
      (await call(
        'GET',
        '/api/accounts/$id/notifications',
        cookie: cookie,
      )).body['enabled'],
      isFalse,
    );
    final r = await call(
      'PUT',
      '/api/server-settings',
      cookie: cookie,
      json: {
        'settings': {'NTFY_TOPIC': 'lumo-test-123'},
      },
    );
    expect(r.status, 200, reason: '${r.body}');
    expect(
      (await call(
        'GET',
        '/api/accounts/$id/notifications',
        cookie: cookie,
      )).body['enabled'],
      isTrue,
    );
  });

  test('LabeledNotifier names the child once there are several', () async {
    final sent = <AppNotification>[];
    ({String name, String id})? label;
    final n = LabeledNotifier(_Recording(sent), () => label);
    const note = AppNotification(
      title: 'Neue Hausaufgabe',
      message: 'Mathe',
      clickPath: '/hausaufgaben',
    );
    await n.send(note);
    label = (name: 'Anna', id: 'k3x9ab');
    await n.send(note);
    expect(sent[0].title, 'Neue Hausaufgabe');
    expect(sent[0].clickPath, '/hausaufgaben');
    expect(sent[1].title, 'Anna: Neue Hausaufgabe');
    expect(sent[1].clickPath, '/hausaufgaben?konto=k3x9ab');
  });

  test('state scopes do not overlap', () {
    final db = AppDatabase.inMemory();
    final a = ScopedState(db, scopePrefix('aaa'));
    final b = ScopedState(db, scopePrefix('bbb'));
    final now = DateTime(2026, 1, 1);
    db.markSeen('homework', ['x'], now);
    a.markSeen('homework', ['y'], now);
    a.setJson('sync:homework', {'n': 1});
    expect(db.seen('homework'), {'x'});
    expect(a.seen('homework'), {'y'});
    expect(b.seen('homework'), isEmpty);
    expect(b.getJson('sync:homework'), isNull);

    db.resetPortalState(scopePrefix('aaa'));
    expect(a.seen('homework'), isEmpty);
    expect(db.seen('homework'), {'x'}, reason: 'other scopes untouched');
    db.resetPortalState();
    expect(db.seen('homework'), isEmpty);
    db.close();
  });
}

class _Recording implements Notifier {
  final List<AppNotification> sent;

  _Recording(this.sent);

  @override
  String get description => 'test';

  @override
  Future<void> send(AppNotification notification) async =>
      sent.add(notification);
}
