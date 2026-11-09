import 'dart:convert';
import 'dart:io';

import 'package:schulportal_server/schulportal_server.dart';
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

  Api build({String? webDir, LoginRateLimiter? limiter}) => Api(
    service: service,
    passwordHash: _hash,
    webDir: webDir,
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
      expect(await body(r), {'status': 'ok'});
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
      final r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 200);
      final b = await body(r);
      expect(b['stale'], isTrue);
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

    test('refresh clears the cache', () async {
      await send('GET', '/api/homework', cookie: cookie);
      final r = await send('POST', '/api/refresh', cookie: cookie);
      expect(r.statusCode, 204);
      final b = await body(await send('GET', '/api/homework', cookie: cookie));
      expect(b['cached'], isFalse);
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
        expect(await body(r), {'subjectColors': <String, Object?>{}});

        r = await put({
          'subjectColors': {' Mathematik ': '#1D5BB8', 'Sport': '#00aa00'},
        });
        expect(r.statusCode, 200);
        r = await send('GET', '/api/settings', cookie: cookie);
        expect(await body(r), {
          'subjectColors': {'Mathematik': '#1d5bb8', 'Sport': '#00aa00'},
        });
      },
    );

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
}
