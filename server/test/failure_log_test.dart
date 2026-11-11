import 'dart:convert';

import 'package:dio/dio.dart'
    show DioException, DioExceptionType, RequestOptions;
import 'package:dio/dio.dart' as dio show Response;
import 'package:lumo_server/lumo_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

final _hash = PasswordHasher.hash('richtig123', iterations: 1000);

void main() {
  group('describeFailure', () {
    test('names the exception, its cause and the code that threw', () {
      final trace = StackTrace.fromString(
        '#0 a (package:liblanis/src/applets/lessons/student_parser.dart:38:21)\n'
        '#1 b (package:dio/src/x.dart:9:1)\n'
        '#2 c (package:lumo_server/src/sph/mappers.dart:5:1)',
      );
      final e = SphDataException(
        'Unexpected response from Schulportal',
        TypeError(),
      );
      final text = describeFailure(e, stack: trace);
      expect(text, contains('SphDataException: Unexpected response'));
      expect(text, contains('caused by TypeError'));
      expect(
        text,
        contains(
          'at liblanis/src/applets/lessons/student_parser.dart:38 <- '
          'lumo_server/src/sph/mappers.dart:5',
        ),
      );
      expect(text, isNot(contains('dio/src')));
    });

    test('HTTP errors: method, address without query, status', () {
      final options = RequestOptions(
        path:
            'https://start.schulportal.hessen.de/meinunterricht.php?id=7&x=geheim',
        method: 'POST',
      );
      final e = DioException(
        requestOptions: options,
        response: dio.Response(requestOptions: options, statusCode: 500),
        type: DioExceptionType.badResponse,
      );
      final text = describeFailure(SphUnavailableException('down', e));
      expect(
        text,
        contains(
          'DioException(badResponse) POST '
          'start.schulportal.hessen.de/meinunterricht.php status 500',
        ),
      );
      expect(text, isNot(contains('geheim')));
    });

    test('long texts are cut, line breaks removed', () {
      final text = describeFailure(StateError('a\n' * 400));
      expect(text.length, lessThan(420));
      expect(text, isNot(contains('\n')));
    });
  });

  group('API', () {
    late FakeGateway gw;
    late SphService service;
    late Handler handler;
    late List<String> log;

    setUp(() {
      gw = FakeGateway();
      service = SphService(gw);
      log = [];
      handler = Api(
        log: log.add,
        accountId: 'abc123',
        service: service,
        passwordHash: _hash,
      ).handler;
    });
    tearDown(() => service.dispose());

    Future<Response> send(
      String method,
      String path, {
      Object? json,
      String? cookie,
    }) => Future.value(
      handler(
        Request(
          method,
          Uri.parse('http://localhost$path'),
          body: json == null ? null : jsonEncode(json),
          headers: {
            if (json != null) 'content-type': 'application/json',
            'cookie': ?cookie,
          },
        ),
      ),
    );

    Future<String> login() async {
      final r = await send(
        'POST',
        '/api/auth/login',
        json: {'password': 'richtig123'},
      );
      return r.headers['set-cookie']!.split(';').first;
    }

    test('a wrong web password is logged with the client', () async {
      await send('POST', '/api/auth/login', json: {'password': 'falsch'});
      expect(log.single, startsWith('login failed: wrong password from '));
    });

    test('a failed request says what, for which account and why', () async {
      final cookie = await login();
      gw.dataErrors.addAll([StateError('kaputt'), StateError('kaputt')]);
      final r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 502);
      final lines = log.where((l) => l.startsWith('api ')).toList();
      expect(lines, isNotEmpty);
      expect(lines.last, contains('api GET /api/timetable [abc123]'));
      expect(lines.last, contains('SphDataException'));
      expect(lines.last, contains('kaputt'));
    });

    test('expected answers are not logged', () async {
      final cookie = await login();
      gw.applets = {};
      final r = await send('GET', '/api/timetable', cookie: cookie);
      expect(r.statusCode, 404);
      expect(log.where((l) => l.startsWith('api ')), isEmpty);
    });

    test(
      'the first failure and the retry of the portal service are logged',
      () async {
        final lines = <String>[];
        final svc = SphService(gw, log: lines.add);
        gw.dataErrors.addAll([StateError('eins'), StateError('zwei')]);
        await expectLater(svc.timetable(), throwsA(isA<SphDataException>()));
        expect(lines[0], startsWith('request failed, logging in again: '));
        expect(lines[0], contains('eins'));
        expect(lines[1], startsWith('request failed again: '));
        expect(lines[1], contains('zwei'));
        await svc.dispose();
      },
    );

    test('a failed login is logged', () async {
      final lines = <String>[];
      final svc = SphService(gw, log: lines.add);
      gw.loginErrors.add(const SphAuthException('Wrong username or password'));
      await expectLater(svc.timetable(), throwsA(isA<SphAuthException>()));
      expect(lines.single, startsWith('login failed: SphAuthException'));
      await svc.dispose();
    });
  });

  test('sync: a failed task is logged with its failure count', () async {
    final gw = FakeGateway();
    final svc = SphService(gw);
    final log = <String>[];
    final db = AppDatabase.inMemory();
    final sync = SyncService(
      service: svc,
      cache: ResponseCache(serveStaleOn: (_) => false),
      db: db,
      config: const SyncConfig(pause: Duration.zero),
      log: log.add,
    );
    gw.dataErrors.addAll([StateError('a'), StateError('b')]);
    await sync.refreshNow([SyncTask.timetable]);
    expect(
      log.single,
      startsWith('sync timetable failed (1. time in a row): '),
    );
    expect(log.single, contains('SphDataException'));
    await sync.stop();
    await svc.dispose();
    db.close();
  });

  test('cache: a failed refresh in the background is reported', () async {
    var now = DateTime(2026, 11, 9, 12);
    final reported = <String>[];
    final cache = ResponseCache(
      now: () => now,
      serveStaleOn: (_) => true,
      onBackgroundError: (key, error, stack) => reported.add('$key: $error'),
    );
    await cache.get('k', const Duration(minutes: 10), () async => 1);
    now = now.add(const Duration(hours: 1));
    final r = await cache.read<int>(
      'k',
      const Duration(minutes: 10),
      () async => throw StateError('portal weg'),
    );
    expect(r.value, 1, reason: 'the old entry is served');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reported.single, contains('k: Bad state: portal weg'));
  });
}
