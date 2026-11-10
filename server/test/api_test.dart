import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:gong_server/gong_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

final _hash = PasswordHasher.hash('richtig123', iterations: 1000);

void main() {
  late FakeGateway gw;
  late SphService service;
  late Api api;
  late Handler handler;
  late DateTime now;

  Api build({
    String? webDir,
    EmbeddedWeb? embeddedWeb,
    LoginRateLimiter? limiter,
  }) => Api(
    service: service,
    passwordHash: _hash,
    webDir: webDir,
    embeddedWeb: embeddedWeb,
    limiter: limiter,
    now: () => now,
  );

  setUp(() {
    now = DateTime(2026, 11, 9, 12);
    gw = FakeGateway();
    service = SphService(gw, now: () => now);
    api = build();
    handler = api.handler;
  });

  tearDown(() => service.dispose());

  Future<Response> send(
    String method,
    String path, {
    Object? json,
    String? cookie,
    String contentType = 'application/json',
  }) async {
    return await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        body: json == null ? null : jsonEncode(json),
        headers: {
          if (json != null) 'content-type': contentType,
          'cookie': ?cookie,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> body(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, dynamic>;

  Future<String> login() async {
    final r = await send(
      'POST',
      '/api/auth/login',
      json: {'password': 'richtig123'},
    );
    expect(r.statusCode, 200);
    final setCookie = r.headers['set-cookie']!;
    return setCookie.split(';').first;
  }

  group('auth', () {
    test('healthz needs no login', () async {
      final r = await send('GET', '/healthz');
      expect(r.statusCode, 200);
      expect(await body(r), {'status': 'ok', 'app': 'gong'});
    });

    test('data endpoints require login', () async {
      final r = await send('GET', '/api/timetable');
      expect(r.statusCode, 401);
      expect((await body(r))['error']['code'], 'unauthorized');
      expect(gw.loginCalls, 0, reason: 'no portal access without app login');
    });

    test('login sets a strict HttpOnly cookie', () async {
      final r = await send(
        'POST',
        '/api/auth/login',
        json: {'password': 'richtig123'},
      );
      expect(r.statusCode, 200);
      final c = r.headers['set-cookie']!;
      expect(c, startsWith('$sessionCookie='));
      expect(c, contains('HttpOnly'));
      expect(c, contains('SameSite=Strict'));
      expect(c, isNot(contains('Secure')));
    });

    test('wrong password → 401', () async {
      final r = await send('POST', '/api/auth/login', json: {'password': 'x'});
      expect(r.statusCode, 401);
      expect(r.headers['set-cookie'], isNull);
    });

    test('login requires JSON content type (CSRF protection)', () async {
      final r = await send(
        'POST',
        '/api/auth/login',
        json: {'password': 'richtig123'},
        contentType: 'text/plain',
      );
      expect(r.statusCode, 415);
    });

    test('malformed body → 400', () async {
      final r = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/auth/login'),
          body: 'not json',
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(r.statusCode, 400);
    });

    test('too many failed logins → 429 with Retry-After', () async {
      api = build(limiter: LoginRateLimiter(maxFailures: 2, now: () => now));
      handler = api.handler;
      for (var i = 0; i < 2; i++) {
        await send('POST', '/api/auth/login', json: {'password': 'x'});
      }
      final r = await send(
        'POST',
        '/api/auth/login',
        json: {'password': 'richtig123'},
      );
      expect(r.statusCode, 429);
      expect(int.parse(r.headers['retry-after']!), greaterThan(0));
    });

    test('me and logout', () async {
      final cookie = await login();
      var r = await send('GET', '/api/auth/me', cookie: cookie);
      expect(await body(r), {'authenticated': true});

      r = await send('POST', '/api/auth/logout', cookie: cookie);
      expect(r.headers['set-cookie'], contains('Max-Age=0'));

      r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 401);
    });
  });

  group('data', () {
    late String cookie;
    setUp(() async => cookie = await login());

    test('timetable with metadata and caching', () async {
      var r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 200);
      expect(r.headers['cache-control'], 'no-store');
      var b = await body(r);
      expect(b['cached'], isFalse);
      expect(b['stale'], isFalse);
      expect(b['data']['currentWeek'], 'B');
      expect(b['data']['lessons'], isNotEmpty);

      r = await send('GET', '/api/timetable', cookie: cookie);
      b = await body(r);
      expect(b['cached'], isTrue);

      r = await send('GET', '/api/timetable?refresh=1', cookie: cookie);
      b = await body(r);
      expect(b['cached'], isFalse);
    });

    test('all data endpoints answer 200', () async {
      for (final path in [
        '/api/account',
        '/api/substitutions',
        '/api/calendar',
        '/api/courses',
        '/api/courses/100',
        '/api/homework',
        '/api/homework?alle=1',
        '/api/grades',
      ]) {
        final r = await send('GET', path, cookie: cookie);
        expect(r.statusCode, 200, reason: path);
        expect((await body(r)).containsKey('data'), isTrue, reason: path);
      }
    });

    test('calendar passes the date range', () async {
      final r = await send(
        'GET',
        '/api/calendar?from=2026-12-01&to=2026-12-31',
        cookie: cookie,
      );
      expect(r.statusCode, 200);
      expect(gw.lastCalendarFrom, DateTime(2026, 12, 1));
      expect(gw.lastCalendarTo, DateTime(2026, 12, 31));
    });

    test('calendar validates dates', () async {
      for (final q in [
        'from=2026-13-01',
        'from=gestern',
        'from=2026-12-31&to=2026-12-01',
        'from=2026-01-01&to=2027-12-31',
      ]) {
        final r = await send('GET', '/api/calendar?$q', cookie: cookie);
        expect(r.statusCode, 400, reason: q);
      }
    });

    test('unknown course → 404', () async {
      final r = await send('GET', '/api/courses/999', cookie: cookie);
      expect(r.statusCode, 404);
      expect((await body(r))['error']['code'], 'not_found');
    });

    test('disabled feature → 404 feature_disabled', () async {
      gw.applets = {'stundenplan.php'};
      final r = await send('GET', '/api/substitutions', cookie: cookie);
      expect(r.statusCode, 404);
      expect((await body(r))['error']['code'], 'feature_disabled');
    });

    test('portal down without cache → 503', () async {
      gw.loginErrors.add(const SphUnavailableException('down'));
      final r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 503);
      expect((await body(r))['error']['code'], 'sph_unavailable');
    });

    test('portal down with cache → stale data', () async {
      await send('GET', '/api/timetable', cookie: cookie);
      now = now.add(const Duration(days: 1));
      await service.logout();
      gw.loginErrors.add(const SphUnavailableException('down'));
      // Answered from the cache right away, refreshed in the background …
      var r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 200);
      var b = await body(r);
      expect(b['data']['currentWeek'], 'B');
      expect((b['stale'], b['refreshing']), (false, true));
      while (api.cache.isLoading('timetable')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // … which failed: now the data is marked as stale (offline).
      r = await send('GET', '/api/timetable', cookie: cookie);
      b = await body(r);
      expect((b['stale'], b['refreshing']), (true, true));
      expect(b['data']['currentWeek'], 'B');
    });

    test(
      'wrong SPH credentials → 503 sph_auth_failed with retryAfter',
      () async {
        gw.loginErrors.add(
          const SphAuthException('Wrong username or password'),
        );
        final r = await send('GET', '/api/timetable', cookie: cookie);
        expect(r.statusCode, 503);
        final e = (await body(r))['error'];
        expect(e['code'], 'sph_auth_failed');
        expect(e['retryAfter'], isNotNull);
      },
    );

    Future<Response> setDone(String path, Object body, {String? type}) =>
        Future.value(
          handler(
            Request(
              'PUT',
              Uri.parse('http://localhost$path'),
              body: body is String ? body : jsonEncode(body),
              headers: {
                'content-type': type ?? 'application/json',
                'cookie': cookie,
              },
            ),
          ),
        );

    test('mark homework as done updates portal and cache', () async {
      var b = await body(await send('GET', '/api/homework', cookie: cookie));
      expect(b['data'][0]['done'], isFalse);
      await send('GET', '/api/courses/100', cookie: cookie); // fill cache
      await send('GET', '/api/homework?alle=1', cookie: cookie);
      final detailCalls = gw.lessonDetailCalls;

      final r = await setDone('/api/courses/100/entries/e1/homework', {
        'done': true,
      });
      expect(r.statusCode, 200);
      expect(await body(r), {'done': true});
      expect(gw.homeworkCalls.single, ('100', 'e1', true));

      // Cached data is patched, not reloaded from the portal.
      b = await body(await send('GET', '/api/homework', cookie: cookie));
      expect((b['cached'], b['data'][0]['done']), (true, true));
      b = await body(await send('GET', '/api/homework?alle=1', cookie: cookie));
      expect((b['cached'], b['data'][0]['done']), (true, true));
      b = await body(await send('GET', '/api/courses/100', cookie: cookie));
      final entry = (b['data']['history'] as List).firstWhere(
        (e) => e['id'] == 'e1',
      );
      expect((b['cached'], entry['homeworkDone']), (true, true));
      expect(gw.lessonDetailCalls, detailCalls, reason: 'no reload');
    });

    test('mark homework: validation and errors', () async {
      const path = '/api/courses/100/entries/e1/homework';
      expect((await setDone(path, {'done': 'yes'})).statusCode, 400);
      expect((await setDone(path, 'nope')).statusCode, 400);
      expect(
        (await setDone(path, {'done': true}, type: 'text/plain')).statusCode,
        415,
      );
      expect(
        (await setDone('/api/courses/1%26x/entries/e1/homework', {
          'done': true,
        })).statusCode,
        400,
      );
      gw.homeworkAnswer = '0';
      final r = await setDone(path, {'done': true});
      expect(r.statusCode, 502);
      expect(gw.homeworkCalls, hasLength(2));
    });

    test('mark homework requires login', () async {
      final r = await handler(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/courses/100/entries/e1/homework'),
          body: '{"done":true}',
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(r.statusCode, 401);
      expect(gw.homeworkCalls, isEmpty);
    });

    test('refresh without sync clears the cache', () async {
      await send('GET', '/api/homework', cookie: cookie);
      final r = await send('POST', '/api/refresh', cookie: cookie);
      expect(r.statusCode, 204);
      final b = await body(await send('GET', '/api/homework', cookie: cookie));
      expect(b['cached'], isFalse);
      expect(b['key'], 'homework');
    });

    test('unknown API path → JSON 404', () async {
      final r = await send('GET', '/api/nope', cookie: cookie);
      expect(r.statusCode, 404);
      expect((await body(r))['error']['code'], 'not_found');
    });
  });

  group('settings', () {
    late String cookie;
    setUp(() async => cookie = await login());

    Future<Response> put(Object body, {String type = 'application/json'}) =>
        Future.value(
          handler(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/settings'),
              body: body is String ? body : jsonEncode(body),
              headers: {'content-type': type, 'cookie': cookie},
            ),
          ),
        );

    test(
      'defaults to no colors; saves and returns normalized colors',
      () async {
        var r = await send('GET', '/api/settings', cookie: cookie);
        expect(await body(r), {
          'subjectColors': <String, Object?>{},
          'courseSubjects': <String, Object?>{},
          'substitutionFilter': {
            'classes': <Object?>[],
            'showUnassigned': false,
            'hiddenTypes': <Object?>[],
            'hiddenNotices': <Object?>[],
          },
        });

        r = await put({
          'subjectColors': {' Mathematik ': '#1D5BB8', 'Sport': '#00aa00'},
          'courseSubjects': {'3481': ' M ', '3739': ''},
        });
        expect(r.statusCode, 200);
        r = await send('GET', '/api/settings', cookie: cookie);
        final b = await body(r);
        expect(b['subjectColors'], {
          'Mathematik': '#1d5bb8',
          'Sport': '#00aa00',
        });
        expect(b['courseSubjects'], {'3481': 'M', '3739': ''});
      },
    );

    test('fields not sent keep their value', () async {
      await put({
        'subjectColors': {'M': '#112233'},
      });
      await put({
        'substitutionFilter': {
          'classes': [' 05eG ', '05eG'],
          'hiddenTypes': ['Pausenaufsicht'],
        },
      });
      var b = await body(await send('GET', '/api/settings', cookie: cookie));
      expect(b['subjectColors'], {'M': '#112233'});
      expect(b['substitutionFilter'], {
        'classes': ['05eG'],
        'showUnassigned': false,
        'hiddenTypes': ['Pausenaufsicht'],
        'hiddenNotices': <Object?>[],
      });
      await put({
        'subjectColors': {'M': '#445566'},
      });
      b = await body(await send('GET', '/api/settings', cookie: cookie));
      expect((b['substitutionFilter'] as Map)['classes'], ['05eG']);
    });

    test('rejects invalid input', () async {
      for (final bad in [
        {
          'subjectColors': {'M': 'red'},
        },
        {
          'subjectColors': {'M': '#12345'},
        },
        {
          'subjectColors': {'': '#123456'},
        },
        {'subjectColors': []},
        {
          'courseSubjects': {'a&b': 'M'},
        },
        {
          'courseSubjects': {'1': 5},
        },
        {'courseSubjects': []},
        {'substitutionFilter': []},
        {
          'substitutionFilter': {
            'classes': [''],
          },
        },
        {
          'substitutionFilter': {'showUnassigned': 'ja'},
        },
        'not json',
      ]) {
        final r = await put(bad);
        expect(r.statusCode, 400, reason: '$bad');
      }
      expect((await put({}, type: 'text/plain')).statusCode, 415);
    });

    test('requires login', () async {
      final r = await send('GET', '/api/settings');
      expect(r.statusCode, 401);
    });

    test('substitutions are filtered by the permanent filter', () async {
      Future<Map<String, dynamic>> subs([String q = '']) async =>
          body(await send('GET', '/api/substitutions$q', cookie: cookie));
      List<String?> periods(Map<String, dynamic> b) => [
        for (final d in b['data'] as List)
          for (final e in (d as Map)['entries'] as List) (e as Map)['period'],
      ];

      var b = await subs();
      expect(periods(b), ['3', '5', '2']);
      expect(b['filter'], {'active': false, 'hidden': 0});

      await put({
        'substitutionFilter': {
          'classes': ['07bG'],
        },
      });
      b = await subs();
      expect(periods(b), ['5'], reason: '"07aG, 07bG" contains 07bG');
      expect(b['filter'], {
        'active': true,
        'hidden': 2,
        'classes': ['07bG'],
      });
      expect(
        (b['data'] as List).any(
          (d) => ((d as Map)['notices'] as List).isNotEmpty,
        ),
        isTrue,
        reason: 'notices are kept',
      );

      await put({
        'substitutionFilter': {
          'classes': ['05EG'],
          'showUnassigned': true,
          'hiddenTypes': ['pausenaufsicht'],
        },
      });
      expect(periods(await subs()), ['3']);
      expect(periods(await subs('?alle=1')), ['3', '5', '2']);
    });

    test('URL filters like on the web UI pages', () async {
      Future<Map<String, dynamic>> get(String path) async =>
          body(await send('GET', path, cookie: cookie));
      List<String?> periods(Map<String, dynamic> b) => [
        for (final d in b['data'] as List)
          for (final e in (d as Map)['entries'] as List) (e as Map)['period'],
      ];

      expect(periods(await get('/api/substitutions?suche=buch')), ['3']);
      expect(periods(await get('/api/substitutions?klasse=07bg')), ['5']);
      expect(periods(await get('/api/substitutions?art=F%C3%A4llt%20aus')), [
        '5',
      ]);
      expect(periods(await get('/api/substitutions?ohne_art=pausenaufsicht')), [
        '3',
        '5',
      ]);
      final day = await get('/api/substitutions?von=2026-11-11&bis=2026-11-11');
      expect((day['data'] as List).map((d) => (d as Map)['date']), [
        '2026-11-11',
      ]);
      final bad = await send(
        'GET',
        '/api/substitutions?von=11.11.2026',
        cookie: cookie,
      );
      expect(bad.statusCode, 400);

      // On top of the permanent filter.
      await put({
        'substitutionFilter': {
          'classes': ['05eG'],
        },
      });
      expect(
        periods(await get('/api/substitutions?suche=f%C3%A4llt')),
        isEmpty,
      );
      expect(periods(await get('/api/substitutions?alle=1&suche=f%C3%A4llt')), [
        '5',
      ]);
      expect(periods(await get('/api/substitutions?suche=buch')), ['3']);

      var cal = await get('/api/calendar?suche=ELTERN');
      expect((cal['data'] as List).single['title'], 'Elternabend');
      cal = await get('/api/calendar?suche=gibtsnicht');
      expect(cal['data'], isEmpty);
      cal = await get('/api/calendar?kategorie=termin');
      expect((cal['data'] as List).single['category'], 'Termine');
      cal = await get('/api/calendar?kategorie=Klausuren,Arbeiten');
      expect(cal['data'], isEmpty);
      cal = await get('/api/calendar?kategorie=Termine&suche=gibtsnicht');
      expect(cal['data'], isEmpty);

      final all = (await get('/api/homework?alle=1'))['data'] as List;
      expect(all, isNotEmpty);
      final course = (all.first as Map)['courseName'] as String;
      final found =
          (await get(
                '/api/homework?alle=1&suche=${Uri.encodeQueryComponent(course)}',
              ))['data']
              as List;
      expect(found, isNotEmpty);
      expect(found.every((h) => (h as Map)['courseName'] == course), isTrue);
      expect((await get('/api/homework?suche=gibtsnicht'))['data'], isEmpty);
    });

    test('notices can be hidden by their heading', () async {
      List<Object?> notices(Map<String, dynamic> b) => [
        for (final d in b['data'] as List)
          for (final n in (d as Map)['notices'] as List) (n as Map)['title'],
      ];
      Future<Map<String, dynamic>> subs([String q = '']) async =>
          body(await send('GET', '/api/substitutions$q', cookie: cookie));

      expect(notices(await subs()), ['Allgemein']);
      await put({
        'substitutionFilter': {
          'hiddenNotices': ['allgemein'],
        },
      });
      final b = await subs();
      expect(notices(b), isEmpty);
      expect(b['filter']['active'], isTrue);
      expect(b['filter']['hidden'], 0, reason: 'counts entries only');
      expect(notices(await subs('?alle=1')), ['Allgemein']);
    });

    test('persists in the database', () {
      final db = AppDatabase.inMemory();
      SettingsStore(
        db,
      ).save(const AppSettings(subjectColors: {'Kunst': '#ff8800'}));
      expect(SettingsStore(db).load().subjectColors, {'Kunst': '#ff8800'});
      db.close();
    });
  });

  group('static web UI', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sph_web_');
      File('${dir.path}/index.html').writeAsStringSync('<h1>App</h1>');
      File('${dir.path}/app.js').writeAsStringSync('console.log(1)');
      File('${dir.path}/manifest.webmanifest').writeAsStringSync('{}');
      api = build(webDir: dir.path);
      handler = api.handler;
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('serves files and index.html for unknown paths', () async {
      var r = await send('GET', '/');
      expect(await r.readAsString(), '<h1>App</h1>');
      expect(r.headers['x-frame-options'], 'DENY');

      expect(
        r.headers['content-security-policy'],
        allOf(
          contains("script-src 'self'"),
          contains("frame-ancestors 'none'"),
        ),
      );
      expect(r.headers['cache-control'], 'no-cache');

      r = await send('GET', '/app.js');
      expect(await r.readAsString(), 'console.log(1)');
      expect(r.headers['content-type'], startsWith('text/javascript'));

      r = await send('GET', '/manifest.webmanifest');
      expect(r.headers['content-type'], 'application/manifest+json');

      r = await send('GET', '/noten');
      expect(r.statusCode, 200);
      expect(await r.readAsString(), '<h1>App</h1>');
    });

    test('API 404s are not replaced by index.html', () async {
      final r = await send('GET', '/api/unknown');
      expect(r.statusCode, 404);
      expect((await body(r))['error']['code'], 'not_found');
    });

    test('no web dir → 404 for non-API paths', () async {
      handler = build().handler;
      final r = await send('GET', '/');
      expect(r.statusCode, 404);
    });
  });

  group('embedded web UI', () {
    String b64(String s) => base64.encode(utf8.encode(s));

    setUp(() {
      handler = build(
        embeddedWeb: EmbeddedWeb.fromBase64({
          'index.html': b64('<h1>App</h1>'),
          'js/app.js': b64('console.log(1)'),
          'manifest.webmanifest': b64('{}'),
        }),
      ).handler;
    });

    test('serves files with content type and ETag', () async {
      var r = await send('GET', '/js/app.js');
      expect(r.statusCode, 200);
      expect(await r.readAsString(), 'console.log(1)');
      expect(r.headers['content-type'], startsWith('text/javascript'));
      expect(
        r.headers['content-security-policy'],
        contains("script-src 'self'"),
      );
      final etag = r.headers['etag']!;

      r = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/js/app.js'),
          headers: {'if-none-match': etag},
        ),
      );
      expect(r.statusCode, 304);

      r = await send('GET', '/manifest.webmanifest');
      expect(r.headers['content-type'], 'application/manifest+json');
    });

    test('index.html for / and unknown paths, not for the API', () async {
      expect(await (await send('GET', '/')).readAsString(), '<h1>App</h1>');
      expect(
        await (await send('GET', '/noten')).readAsString(),
        '<h1>App</h1>',
      );
      expect((await send('GET', '/api/unknown')).statusCode, 404);
    });

    test('empty embedded web → 404 for non-API paths', () async {
      handler = build(embeddedWeb: EmbeddedWeb.fromBase64({})).handler;
      expect((await send('GET', '/')).statusCode, 404);
    });
  });

  group('sync and live updates', () {
    late AppDatabase db;
    late SyncService sync;
    late String cookie;

    setUp(() async {
      db = AppDatabase.inMemory();
      final cache = Api.createCache(now: () => now);
      sync = SyncService(
        service: service,
        cache: cache,
        db: db,
        config: const SyncConfig(pause: Duration.zero),
        now: () => now,
      );
      api = Api(
        service: service,
        passwordHash: _hash,
        cache: cache,
        sync: sync,
        now: () => now,
      );
      handler = api.handler;
      cookie = await login();
    });

    tearDown(() async {
      await api.close();
      await sync.stop();
      db.close();
    });

    test('refresh starts a sync in the background (202)', () async {
      final r = await send('POST', '/api/refresh', cookie: cookie);
      expect(r.statusCode, 202);
      expect(await body(r), {'refreshing': true});
      expect(sync.running, isTrue);
      await sync.refreshNow(const []); // waits for the running sync
      final b = await body(await send('GET', '/api/grades', cookie: cookie));
      expect(b['cached'], isTrue, reason: 'filled by the sync');
    });

    test('sync status lists all tasks', () async {
      await sync.refreshNow([SyncTask.homework]);
      final b = await body(await send('GET', '/api/sync', cookie: cookie));
      expect(b['enabled'], isTrue);
      expect(b['running'], isFalse);
      expect((b['tasks'] as Map).keys, [
        for (final t in SyncTask.values)
          if (t != SyncTask.meals) t.name,
      ]);
      expect(b['tasks']['homework']['lastSuccess'], isNotNull);
      expect(b['tasks']['homework']['intervalMinutes'], 15);
      expect(b['tasks']['grades'], isNull);
      expect(b['tasks']['lessons']['lastRun'], isNull);
      expect((await send('GET', '/api/sync', cookie: 'x=y')).statusCode, 401);
    });

    test('events stream pushes sync state and cache updates', () async {
      final r = await send('GET', '/api/events', cookie: cookie);
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], startsWith('text/event-stream'));
      expect(r.headers['content-encoding'], 'identity');
      final lines = StreamQueue(
        r.read().transform(utf8.decoder).transform(const LineSplitter()),
      );
      Future<String> next() async {
        while (true) {
          final l = await lines.next;
          if (l.isNotEmpty) return l;
        }
      }

      expect(await next(), 'retry: 5000');
      expect(await next(), 'event: sync');
      expect(await next(), 'data: {"running":false}');

      final done = sync.refreshNow([SyncTask.timetable]);
      expect(await next(), 'event: sync');
      expect(await next(), 'data: {"running":true}');
      expect(await next(), 'event: update');
      expect(await next(), startsWith('data: {"key":"timetable"'));
      expect(await next(), 'event: sync');
      expect(await next(), 'data: {"running":false}');
      await done;
      await api.close();
      // Stream ends on shutdown (only blank separator lines remain).
      expect((await lines.rest.toList()).where((l) => l.isNotEmpty), isEmpty);
    });

    test('events need a login', () async {
      final r = await send('GET', '/api/events');
      expect(r.statusCode, 401);
    });
  });
}
