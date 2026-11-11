import 'dart:convert';
import 'dart:io';

import 'package:lumo_server/lumo_server.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

/// The settings of the one account as versions before 0.19 kept them.
const _legacySettings = {
  'ACCOUNT_NAME': 'Max',
  'SPH_SCHOOL_ID': '1234',
  'SPH_USERNAME': 'max.muster',
  'SPH_PASSWORD': 'geheim',
  'CASEDA_USERNAME': 'eltern@example.org',
  'CASEDA_PASSWORD': 'caseda-pw',
  'UNTIS_SERVER': 'schule.webuntis.com',
  'UNTIS_USERNAME': 'klasse5e',
  'UNTIS_PASSWORD': 'untis-pw',
  'NTFY_TOPIC': 'lumo-topic-1',
};

void main() {
  late AppDatabase db;
  late WebSettingsStore web;
  late AccountStore store;
  late List<String> log;
  final now = DateTime(2026, 11, 11);

  setUp(() {
    db = AppDatabase.inMemory();
    web = WebSettingsStore(db);
    store = AccountStore(db);
    log = [];
  });
  tearDown(() => db.close());

  String? migrate([Map<String, String> env = const {}]) => migrateLegacyAccount(
    db: db,
    env: env,
    web: web,
    store: store,
    log: log.add,
  );

  /// What 0.18 had in the database for the one account.
  void writeLegacyData() {
    db.setJson('server-config', {..._legacySettings, 'APP_URL': 'http://x/'});
    db.save('timetable', '{}', now);
    db.markSeen('homework', ['fp1'], now);
    db.setJson('sync:homework', {'failures': 0});
    db.setJson('poll:homework', {'sent': 2});
    db.setJson('settings', {
      'subjectColors': {'Kunst': '#ff8800'},
    });
  }

  test('the old account becomes the first one, with its logins', () {
    writeLegacyData();
    expect(migrate(), 'Max');
    final a = store.load().single;
    expect(a.id, 'main');
    expect(a.name, 'Max');
    expect(a.sph.schoolId, 1234);
    expect(a.sph.username, 'max.muster');
    expect(a.sph.password, 'geheim');
    expect(a.caseda?.username, 'eltern@example.org');
    expect(a.caseda?.url.host, 'www.caseda-schulmenue.de');
    expect(a.untis?.server, 'schule.webuntis.com');
    expect(a.untis?.school, 'schule');
    expect(log.single, contains('taken over'));
  });

  test('its data moves to the account scope, nothing is left behind', () {
    writeLegacyData();
    migrate();
    final keys = [for (final r in db.loadAll()) r.key];
    expect(keys, ['@main/timetable']);
    expect(db.seen('homework'), isEmpty);
    expect(db.seen('@main/homework'), {'fp1'});
    expect(db.getJson('sync:homework'), isNull);
    expect(db.getJson('@main/sync:homework'), {'failures': 0});
    expect(db.getJson('@main/poll:homework'), {'sent': 2});
    expect(db.getJson('settings'), isNull);
    expect(SettingsStore(db, scopePrefix('main')).load().subjectColors, {
      'Kunst': '#ff8800',
    });
  });

  test('the old keys disappear from the web settings, the others stay', () {
    writeLegacyData();
    migrate();
    expect(web.loadRaw(), {
      'NTFY_TOPIC': 'lumo-topic-1',
      'APP_URL': 'http://x/',
    });
  });

  test('it runs once only', () {
    writeLegacyData();
    migrate();
    store.save([]); // would be filled again by a second run
    expect(migrate({'SPH_USERNAME': 'u', 'SPH_PASSWORD': 'p'}), isNull);
    expect(store.load(), isEmpty);
  });

  test('accounts added with 0.18 stay, the old account comes first', () {
    writeLegacyData();
    final anna = AccountConfig.parse({
      'name': 'Anna',
      'username': 'anna.muster',
      'password': 'pw',
    }, id: 'abc123');
    store.save([anna]);
    db.save('@abc123/timetable', '{}', now);
    migrate();
    expect([for (final a in store.load()) a.id], ['main', 'abc123']);
    expect([
      for (final r in db.loadAll()) r.key,
    ], containsAll(['@main/timetable', '@abc123/timetable']));
  });

  test('without old settings nothing is added and loose data is dropped', () {
    db.save('timetable', '{}', now);
    db.markSeen('homework', ['fp1'], now);
    expect(migrate(), isNull);
    expect(store.load(), isEmpty);
    expect(db.loadAll(), isEmpty);
    expect(db.seen('homework'), isEmpty);
  });

  test('a new installation can bring the account in config.env', () {
    expect(
      migrate({
        'SPH_SCHOOL_ID': '5151',
        'SPH_USERNAME': 'erika.muster',
        'SPH_PASSWORD': 'pw',
      }),
      'erika.muster',
    );
    expect(store.load().single.sph.schoolId, 5151);
  });

  test('web settings win over config.env', () {
    db.setJson('server-config', {'SPH_USERNAME': 'aus.web'});
    migrate({'SPH_USERNAME': 'aus.datei', 'SPH_PASSWORD': 'pw'});
    expect(store.load().single.sph.username, 'aus.web');
  });

  test('switched-off Caseda / WebUntis are not taken over', () {
    db.setJson('server-config', {
      ..._legacySettings,
      'CASEDA_ENABLED': 'false',
      'UNTIS_ENABLED': 'false',
    });
    migrate();
    final a = store.load().single;
    expect(a.caseda, isNull);
    expect(a.untis, isNull);
    expect(a.sph.username, 'max.muster');
  });

  test('an invalid extra login does not stop the account', () {
    db.setJson('server-config', {
      ..._legacySettings,
      'UNTIS_SERVER': 'kein host',
    });
    migrate();
    final a = store.load().single;
    expect(a.sph.username, 'max.muster');
    expect(a.untis, isNull);
    expect(log.first, contains('not taken over'));
  });

  test('the same login as a further account is not added twice', () {
    db.setJson('server-config', _legacySettings);
    store.save([
      AccountConfig.parse({
        'name': 'Kopie',
        'schoolId': 1234,
        'username': 'MAX.muster',
        'password': 'pw',
      }, id: 'abc123'),
    ]);
    expect(migrate(), isNull);
    expect(store.load().single.id, 'abc123');
  });

  group('on start', () {
    late Directory dir;
    AppServer? server;
    final client = HttpClient();

    setUp(() => dir = Directory.systemTemp.createTempSync('lumo_migrate_'));
    tearDown(() async {
      await server?.stop();
      server = null;
      dir.deleteSync(recursive: true);
    });

    test('an installation of 0.18 keeps account, data and settings', () async {
      // Prepare the database like 0.18 left it.
      final file = AppDatabase.open('${dir.path}/lumo.db');
      final timetable = await SphService(FakeGateway()).timetable();
      file.setJson('server-config', {
        ..._legacySettings,
        'APP_PASSWORD_HASH': PasswordHasher.hash(
          'web-passwort',
          iterations: 10,
        ),
      });
      file.save('timetable', jsonEncode(timetable), now);
      file.close();

      final portal = FakeGateway();
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      server = await AppServer.start(
        {'DATA_DIR': dir.path, 'PORT': '$port', 'SYNC': 'false'},
        log: (_, _) {},
        gateway: (c) => portal,
        passwordIterations: 10,
      );
      expect(server!.setupRequired, isFalse);
      expect(server!.accountCount, 1);

      Future<(int, Map<String, dynamic>)> get(
        String path, [
        String? cookie,
      ]) async {
        final req = await client.getUrl(server!.localUrl.resolve(path));
        if (cookie != null) req.headers.set('cookie', cookie);
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
      }

      final loginReq = await client.postUrl(
        server!.localUrl.resolve('api/auth/login'),
      );
      loginReq.headers.contentType = ContentType.json;
      loginReq.write(jsonEncode({'password': 'web-passwort'}));
      final loginRes = await loginReq.close();
      await loginRes.drain<void>();
      expect(loginRes.statusCode, 200);
      final cookie = loginRes.headers.value('set-cookie')!.split(';').first;

      final (_, accounts) = await get('api/accounts', cookie);
      final first = (accounts['accounts'] as List).single as Map;
      expect(first['id'], 'main');
      expect(first['name'], 'Max');
      expect(first['caseda']['username'], 'eltern@example.org');
      expect(server!.config.ntfy?.topic, 'lumo-topic-1');

      // The cached data of the old installation is served right away.
      final (status, tt) = await get('api/timetable', cookie);
      expect(status, 200);
      expect(tt['cached'], isTrue);
    });
  });
}
