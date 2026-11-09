import 'dart:convert';
import 'dart:io';

import 'package:ranzen_server/ranzen_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

class RecordingNotifier implements Notifier {
  final sent = <AppNotification>[];
  int failNext = 0;

  @override
  String get description => 'test';

  @override
  Future<void> send(AppNotification n) async {
    if (failNext > 0) {
      failNext--;
      throw const NotifyException('down');
    }
    sent.add(n);
  }
}

Substitution sub(String period, {String? type = 'Vertretung', String? room}) =>
    Substitution(period: period, type: type, subject: 'Mathe', room: room);

void main() {
  final now = DateTime(2026, 11, 9, 10);

  group('AppDatabase', () {
    test('seen, prune, meta and sessions', () {
      final db = AppDatabase.inMemory();
      db.markSeen('k', {'a', 'b'}, DateTime(2026, 1, 1));
      db.markSeen('k', {'b', 'c'}, now);
      expect(db.seen('k'), {'a', 'b', 'c'});
      expect(db.seen('other'), isEmpty);

      db.pruneSeen('k', {'b'}, DateTime(2026, 6, 1));
      expect(db.seen('k'), {'b', 'c'}, reason: 'a is old and gone');

      db.setJson('x', {'n': 1});
      expect(db.getJson('x'), {'n': 1});
      expect(db.getMeta('missing'), isNull);

      db.saveSession('tok', DateTime(2026, 12, 1));
      expect(db.sessionExpiry('tok'), DateTime(2026, 12, 1));
      db.purgeSessions(DateTime(2027, 1, 1));
      expect(db.sessionExpiry('tok'), isNull);
      db.close();
    });

    test('survives reopening a file', () {
      final dir = Directory.systemTemp.createTempSync('sph_db_');
      try {
        var db = AppDatabase.open('${dir.path}/t.db');
        db.markSeen('k', {'x'}, now);
        db.close();
        db = AppDatabase.open('${dir.path}/t.db');
        expect(db.seen('k'), {'x'});
        db.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  test('SessionStore with database survives restart, stores hashed token', () {
    final db = AppDatabase.inMemory();
    var t = now;
    final first = SessionStore(database: db, now: () => t);
    final token = first.create();
    expect(db.sessionExpiry(token), isNotNull);

    final second = SessionStore(database: db, now: () => t); // "restart"
    expect(second.validate(token), isTrue);
    second.revoke(token);
    expect(SessionStore(database: db, now: () => t).validate(token), isFalse);

    final expiring = SessionStore(
      database: db,
      ttl: const Duration(days: 1),
      now: () => t,
    );
    final tok2 = expiring.create();
    t = t.add(const Duration(days: 2));
    expect(SessionStore(database: db, now: () => t).validate(tok2), isFalse);
  });

  group('change detection', () {
    final days = [
      SubstitutionDay(
        date: DateTime(2026, 11, 8),
        entries: [sub('1')],
        notices: const [],
      ),
      SubstitutionDay(
        date: DateTime(2026, 11, 10),
        entries: [
          sub('3 - 4', room: 'A1'),
          sub('6', type: 'Entfall'),
        ],
        notices: const [],
      ),
    ];

    test('substitutions: one notification per day, past days ignored', () {
      final d = detectSubstitutions(days, {}, now);
      expect(d.current, hasLength(2));
      final n = d.pending.single.notification;
      expect(n.title, '2 Vertretungen morgen (Di, 10.11.)');
      expect(
        n.message,
        '3–4. Std. Mathe: Vertretung · Raum A1\n6. Std. Mathe: Entfall',
      );
      expect(n.tags, ['x']);
      expect(n.priority, 4);
      expect(n.clickPath, '/vertretungen');
    });

    test('substitutions: seen entries are not reported, changes are', () {
      final first = detectSubstitutions(days, {}, now);
      expect(detectSubstitutions(days, first.current, now).pending, isEmpty);

      final changed = [
        SubstitutionDay(
          date: DateTime(2026, 11, 10),
          entries: [
            sub('3 - 4', room: 'B2'),
            sub('6', type: 'Entfall'),
          ],
          notices: const [],
        ),
      ];
      final d = detectSubstitutions(changed, first.current, now);
      expect(d.pending.single.notification.message, contains('Raum B2'));
      expect(d.pending.single.fingerprints, hasLength(1));
    });

    test('substitutions: only included entries are notified', () {
      final day = SubstitutionDay(
        date: DateTime(2026, 11, 10),
        entries: [
          const Substitution(period: '1', subject: 'M', className: '05eG'),
          const Substitution(period: '2', subject: 'D', className: '07aG'),
        ],
        notices: const [],
      );
      const filter = SubstitutionFilter(classes: ['05eG']);
      final d = detectSubstitutions([day], {}, now, include: filter.matches);
      expect(d.current, hasLength(2), reason: 'both are recorded as seen');
      expect(d.pending.single.notification.title, contains('Vertretung'));
      expect(d.pending.single.fingerprints, hasLength(1));
    });

    test('SubstitutionFilter matching', () {
      Substitution s(String? klasse, [String? type]) =>
          Substitution(period: '1', className: klasse, type: type);
      const f = SubstitutionFilter(classes: ['05eG']);
      expect(SubstitutionFilter.classesOf('05kF?05aG, 05eG'), [
        '05kF',
        '05aG',
        '05eG',
      ]);
      expect(f.matches(s('05aG, 05eG')), isTrue);
      expect(f.matches(s('05kF?05eg')), isTrue);
      expect(f.matches(s('05e')), isFalse);
      expect(f.matches(s(null, 'Pausenaufsicht')), isFalse);
      expect(
        const SubstitutionFilter(
          classes: ['05eG'],
          showUnassigned: true,
        ).matches(s(null)),
        isTrue,
      );
      const types = SubstitutionFilter(hiddenTypes: ['Betreuung']);
      expect(types.matches(s('07aG', 'betreuung')), isFalse);
      expect(types.matches(s('07aG', 'Vertretung')), isTrue);
      expect(const SubstitutionFilter().isActive, isFalse);
    });

    test('plainText strips markup and decodes entities', () {
      expect(
        plainText('Aufgabe&nbsp;1 &amp; 2<br>S. 12<br/><b>bis Freitag</b>'),
        'Aufgabe 1 & 2\nS. 12\nbis Freitag',
      );
      final d = detectHomework([
        const Homework(
          courseId: 'c',
          courseName: 'Deutsch',
          entryId: 'x',
          date: null,
          topic: null,
          description: 'Lesen &amp; zusammenfassen<br>S. 3',
          done: false,
        ),
      ], {});
      expect(
        d.pending.single.notification.message,
        'Lesen & zusammenfassen\nS. 3',
      );
    });

    test('homework: new open items only, done flag ignored', () {
      Homework hw(String id, {bool done = false}) => Homework(
        courseId: 'c1',
        courseName: 'Mathe',
        entryId: id,
        date: null,
        topic: 'Brüche',
        description: 'S. 12',
        done: done,
      );
      final d = detectHomework([hw('1'), hw('2', done: true)], {});
      expect(d.pending.single.notification.title, 'Hausaufgabe Mathe');
      expect(d.pending.single.notification.message, 'Brüche:\nS. 12');
      expect(d.pending.single.notification.clickPath, '/kurse/c1');

      final again = detectHomework([hw('1', done: true)], d.current);
      expect(again.pending, isEmpty, reason: 'marking as done is no news');
    });

    CourseGrades course(String id, List<Grade> grades) => CourseGrades(
      course: Course(id: id, name: 'Kurs $id', teachers: const []),
      grades: grades,
      exams: const [],
    );

    test('grades: mark hidden by default, shown when enabled', () {
      final c = [
        course('1', [
          const Grade(name: 'Test', date: '01.10.2026', mark: '2+'),
        ]),
      ];
      final hidden = detectGrades(c, {}).pending.single.notification;
      expect(hidden.title, 'Neue Note: Kurs 1');
      expect(hidden.message, 'Test (01.10.2026)');
      expect(hidden.message, isNot(contains('2+')));

      final shown = detectGrades(
        c,
        {},
        includeValues: true,
      ).pending.single.notification;
      expect(shown.message, 'Test (01.10.2026) → 2+');
    });

    test('too many new items → one summary', () {
      final many = [
        course('1', [
          for (var i = 0; i < 10; i++) Grade(name: 'T$i', date: '', mark: '1'),
        ]),
      ];
      final d = detectGrades(many, {});
      expect(d.pending.single.notification.title, '10 neue Noten');
      expect(d.pending.single.fingerprints, hasLength(10));
    });
  });

  group('Poller', () {
    late FakeGateway gw;
    late SphService service;
    late AppDatabase db;
    late RecordingNotifier notifier;
    late SyncService sync;
    late Poller poller;
    late DateTime clock;

    setUp(() {
      clock = now;
      gw = FakeGateway();
      service = SphService(gw, now: () => clock);
      db = AppDatabase.inMemory();
      notifier = RecordingNotifier();
      sync = SyncService(
        service: service,
        cache: Api.createCache(now: () => clock),
        db: db,
        config: const SyncConfig(pause: Duration.zero),
        now: () => clock,
      );
      poller = Poller(sync: sync, db: db, notifier: notifier, now: () => clock);
    });

    tearDown(() async {
      await sync.stop();
      await service.dispose();
      db.close();
    });

    test('first run records baseline without notifications', () async {
      expect(await poller.runNow(), 0);
      expect(notifier.sent, isEmpty);
      for (final k in WatchKind.values) {
        expect(poller.status(k).baseline, isTrue);
        expect(poller.status(k).lastError, isNull);
      }
    });

    test('new homework and grades are notified once', () async {
      await poller.runNow();
      gw.lessonsData.first.currentEntry!.homework =
          sampleLessons().first.currentEntry!.homework!
            ..description = 'Neu: S. 99';
      expect(await poller.runNow([WatchKind.homework]), 1);
      expect(notifier.sent.single.message, contains('S. 99'));

      expect(await poller.runNow([WatchKind.homework]), 0, reason: 'seen');
    });

    test('also notifies for data synced in the background', () async {
      await poller.runNow();
      gw.lessonsData.first.currentEntry!.homework!.description = 'Neu';
      await sync.refreshNow([SyncTask.homework]);
      expect(notifier.sent, hasLength(1));
    });

    test('failed delivery is retried on the next run', () async {
      await poller.runNow();
      gw.lessonsData.first.currentEntry!.homework!.description = 'Neu';
      notifier.failNext = 1;
      expect(await poller.runNow([WatchKind.homework]), 0);
      expect(
        poller.status(WatchKind.homework).lastError,
        'Senden fehlgeschlagen: down',
      );
      expect(await poller.runNow([WatchKind.homework]), 1);
      expect(poller.status(WatchKind.homework).lastError, isNull);
    });

    test('portal errors are recorded, no notifications', () async {
      await poller.runNow();
      await service.logout();
      gw.loginErrors.add(const SphUnavailableException('down'));
      expect(await poller.runNow([WatchKind.substitutions]), 0);
      expect(
        poller.status(WatchKind.substitutions).lastError,
        'Schulportal nicht erreichbar',
      );
    });

    test('next check follows the sync schedule', () async {
      await poller.runNow();
      expect(
        poller.nextRun(WatchKind.homework),
        now.add(const Duration(minutes: 15)),
      );
      expect(
        poller.nextRun(WatchKind.grades),
        now.add(const Duration(hours: 2)),
      );
    });
  });

  group('SyncService', () {
    late FakeGateway gw;
    late SphService service;
    late AppDatabase db;
    late ResponseCache cache;
    late SyncService sync;
    late DateTime clock;

    SyncService create({SyncConfig config = const SyncConfig()}) => SyncService(
      service: service,
      cache: cache,
      db: db,
      config: SyncConfig(
        enabled: config.enabled,
        activeFromHour: config.activeFromHour,
        activeToHour: config.activeToHour,
        pause: Duration.zero,
      ),
      now: () => clock,
    );

    setUp(() {
      clock = now;
      gw = FakeGateway();
      service = SphService(gw, now: () => clock);
      db = AppDatabase.inMemory();
      cache = Api.createCache(now: () => clock);
      sync = create();
    });

    tearDown(() async {
      await sync.stop();
      await service.dispose();
      db.close();
    });

    test('fills all cache entries; course pages loaded once each', () async {
      await sync.refreshNow();
      for (final key in [
        CacheKeys.account,
        CacheKeys.timetable,
        CacheKeys.substitutions,
        CacheKeys.homework,
        CacheKeys.allHomework,
        CacheKeys.courses,
        CacheKeys.grades,
        CacheKeys.calendar(DateTime(2026, 11, 9), DateTime(2027, 1, 8)),
      ]) {
        expect(cache.fetchedAt(key), clock, reason: key);
      }
      final courses = (await cache.read<List<Course>>(
        CacheKeys.courses,
        const Duration(hours: 1),
        () => throw StateError('not loaded'),
      )).value;
      expect(courses, isNotEmpty);
      for (final c in courses) {
        expect(cache.fetchedAt(CacheKeys.course(c.id)), clock);
      }
      expect(gw.lessonDetailCalls, courses.length);
      for (final t in SyncTask.values) {
        expect(sync.status(t).lastSuccess, clock, reason: t.name);
      }
    });

    test(
      'new homework from the overview is merged into the full list',
      () async {
        await sync.refreshNow();
        final before = gw.lessonDetailCalls;
        gw.lessonsData.first.currentEntry!.homework!.description = 'Brandneu';
        await sync.refreshNow([SyncTask.homework]);
        final all = (await cache.read<List<Homework>>(
          CacheKeys.allHomework,
          const Duration(hours: 1),
          () => throw StateError('not loaded'),
        )).value;
        expect(
          all.where((h) => h.description.contains('Brandneu')),
          hasLength(1),
        );
        expect(gw.lessonDetailCalls, before, reason: 'no course page requests');
      },
    );

    test('reports running state and notifies listeners', () async {
      final states = <bool>[];
      sync.runningChanges.listen(states.add);
      final tasks = <SyncTask>[];
      sync.addListener((t, _) async => tasks.add(t));
      await sync.refreshNow([SyncTask.timetable, SyncTask.substitutions]);
      expect(states, [true, false]);
      expect(tasks, [SyncTask.timetable, SyncTask.substitutions]);
      expect(sync.running, isFalse);
    });

    test('schedule: intervals, active hours, never-run tasks', () async {
      expect(sync.dueTasks(now), SyncTask.values);
      expect(sync.dueTasks(DateTime(2026, 11, 9, 23)), isEmpty);
      await sync.refreshNow();
      expect(sync.dueTasks(now.add(const Duration(minutes: 14))), isEmpty);
      expect(sync.dueTasks(now.add(const Duration(minutes: 15))), [
        SyncTask.substitutions,
        SyncTask.homework,
      ]);
      expect(
        sync.nextRun(SyncTask.calendar),
        now.add(const Duration(hours: 1)),
      );
      expect(sync.nextRun(SyncTask.lessons), now.add(const Duration(hours: 2)));
      expect(
        sync.nextRun(SyncTask.timetable),
        now.add(const Duration(hours: 6)),
      );

      const c = SyncConfig(activeFromHour: 6, activeToHour: 22);
      expect(c.isActive(DateTime(2026, 1, 1, 5, 59)), isFalse);
      expect(c.isActive(DateTime(2026, 1, 1, 6)), isTrue);
      expect(c.isActive(DateTime(2026, 1, 1, 21, 59)), isTrue);
      expect(c.isActive(DateTime(2026, 1, 1, 22)), isFalse);
      const night = SyncConfig(activeFromHour: 20, activeToHour: 2);
      expect(night.isActive(DateTime(2026, 1, 1, 23)), isTrue);
      expect(night.isActive(DateTime(2026, 1, 1, 12)), isFalse);
    });

    test('never-run tasks are due even with a ticking clock', () {
      final ticking = SyncService(
        service: service,
        cache: cache,
        db: db,
        // Every call returns a later time, like the real clock.
        now: () => clock = clock.add(const Duration(microseconds: 1)),
      );
      expect(ticking.dueTasks(clock), SyncTask.values);
    });

    test('failures are retried with backoff, capped at the interval', () async {
      await service.logout();
      gw.loginErrors.addAll(
        List.filled(3, const SphUnavailableException('down')),
      );
      await sync.refreshNow([SyncTask.homework]);
      var s = sync.status(SyncTask.homework);
      expect(s.lastError, 'Schulportal nicht erreichbar');
      expect(s.failures, 1);
      expect(
        sync.nextRun(SyncTask.homework),
        now.add(const Duration(minutes: 5)),
      );

      await sync.refreshNow([SyncTask.homework]);
      expect(
        sync.nextRun(SyncTask.homework),
        now.add(const Duration(minutes: 10)),
      );
      await sync.refreshNow([SyncTask.homework]);
      expect(
        sync.nextRun(SyncTask.homework),
        now.add(const Duration(minutes: 15)),
        reason: 'capped at the interval',
      );

      await sync.refreshNow([SyncTask.homework]);
      s = sync.status(SyncTask.homework);
      expect((s.failures, s.lastError), (0, null));
    });

    test('freshFor: covered keys only while the sync is active', () {
      expect(
        sync.freshFor(CacheKeys.substitutions),
        const Duration(minutes: 20),
      );
      expect(
        sync.freshFor(CacheKeys.course('x')),
        const Duration(hours: 2, minutes: 5),
      );
      expect(sync.freshFor('calendar:2020-01-01:2020-02-01'), isNotNull);
      expect(sync.freshFor('unknown'), isNull);
      clock = DateTime(2026, 11, 9, 23);
      expect(sync.freshFor(CacheKeys.substitutions), isNull);
      expect(
        create(
          config: const SyncConfig(enabled: false),
        ).freshFor(CacheKeys.homework),
        isNull,
      );
    });
  });

  group('NtfyNotifier', () {
    late HttpServer server;
    late List<(Map<String, Object?>, String?)> received;
    var status = 200;

    setUp(() async {
      received = [];
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = jsonDecode(await utf8.decodeStream(req));
        expect(req.headers.contentLength, greaterThan(0));
        received.add((
          body as Map<String, Object?>,
          req.headers.value('authorization'),
        ));
        req.response.statusCode = status;
        req.response.write('{"id":"x"}');
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    NtfyNotifier notifier({String? token, Uri? appUrl}) => NtfyNotifier(
      server: Uri.parse('http://127.0.0.1:${server.port}'),
      topic: 'sph-test',
      token: token,
      appUrl: appUrl,
    );

    test('publishes JSON with UTF-8, click link and token', () async {
      await notifier(
        token: 'tk_secret',
        appUrl: Uri.parse('https://schule.example/app/'),
      ).send(
        const AppNotification(
          title: 'Hausaufgabe Französisch',
          message: 'Übung – S. 12',
          tags: ['books'],
          priority: 4,
          clickPath: '/kurse/7',
        ),
      );
      final (body, auth) = received.single;
      expect(body, {
        'topic': 'sph-test',
        'title': 'Hausaufgabe Französisch',
        'message': 'Übung – S. 12',
        'tags': ['books'],
        'priority': 4,
        'click': 'https://schule.example/app/kurse/7',
      });
      expect(auth, 'Bearer tk_secret');
    });

    test('HTTP errors and unreachable server → NotifyException', () async {
      status = 403;
      await expectLater(
        notifier().send(const AppNotification(title: 't', message: 'm')),
        throwsA(
          isA<NotifyException>().having((e) => e.message, 'm', contains('403')),
        ),
      );
      final dead = NtfyNotifier(
        server: Uri.parse('http://127.0.0.1:1'),
        topic: 'x',
      );
      await expectLater(
        dead.send(const AppNotification(title: 't', message: 'm')),
        throwsA(isA<NotifyException>()),
      );
    });

    test('description hides most of the topic', () {
      expect(
        notifier(token: 't').description,
        '127.0.0.1, Thema sph-te… (mit Token)',
      );
    });
  });

  group('AppConfig notifications', () {
    final base = {
      'SPH_USERNAME': 'u',
      'SPH_PASSWORD': 'p',
      'APP_PASSWORD_HASH': PasswordHasher.hash('geheim123', iterations: 10),
    };

    test('disabled without topic; defaults', () {
      final c = AppConfig.fromEnv(base);
      expect(c.ntfy, isNull);
      expect(c.dataDir, '.');
      expect(c.poller.kinds, WatchKind.values.toSet());
      expect(c.sync.enabled, isTrue);
      expect(c.sync.interval, const Duration(minutes: 15));
      expect(c.sync.detailsInterval, const Duration(hours: 2));
      expect(c.poller.includeGradeValues, isFalse);
    });

    test('parses ntfy and polling settings', () {
      final c = AppConfig.fromEnv({
        ...base,
        'NTFY_TOPIC': 'sph-abc_123',
        'NTFY_URL': 'https://ntfy.example.org',
        'NTFY_TOKEN': 'tk',
        'APP_URL': 'https://schule.example/app',
        'NOTIFY': 'homework, grades',
        'POLL_INTERVAL_MINUTES': '15',
        'GRADES_INTERVAL_MINUTES': '60',
        'ACTIVE_HOURS': '7-21',
        'NOTIFY_GRADE_VALUES': 'true',
        'DATA_DIR': '/var/lib/x',
        'SYNC': 'false',
      });
      expect(c.ntfy!.server.host, 'ntfy.example.org');
      expect(c.ntfy!.topic, 'sph-abc_123');
      expect(c.appUrl.toString(), 'https://schule.example/app/');
      expect(c.poller.kinds, {WatchKind.homework, WatchKind.grades});
      expect(c.sync.enabled, isFalse);
      expect(c.sync.interval, const Duration(minutes: 15));
      expect(c.sync.detailsInterval, const Duration(minutes: 60));
      expect((c.sync.activeFromHour, c.sync.activeToHour), (7, 21));
      expect(c.poller.includeGradeValues, isTrue);
      expect(c.databasePath, '/var/lib/x/ranzen.db');
    });

    test('rejects invalid values', () {
      expect(
        () => AppConfig.fromEnv({
          ...base,
          'NTFY_TOPIC': 'has space',
          'POLL_INTERVAL_MINUTES': '1',
          'ACTIVE_HOURS': '22',
          'NOTIFY': 'grades,news',
        }),
        throwsA(
          isA<ConfigException>().having((e) => e.problems, 'problems', [
            contains('NTFY_TOPIC'),
            contains('POLL_INTERVAL_MINUTES'),
            contains('ACTIVE_HOURS'),
            contains('news'),
          ]),
        ),
      );
    });
  });

  group('notification API', () {
    late FakeGateway gw;
    late SphService service;
    late AppDatabase db;
    late RecordingNotifier notifier;
    late SyncService sync;
    late Poller poller;
    final hash = PasswordHasher.hash('richtig123', iterations: 100);

    setUp(() {
      gw = FakeGateway();
      service = SphService(gw, now: () => now);
      db = AppDatabase.inMemory();
      notifier = RecordingNotifier();
      sync = SyncService(
        service: service,
        cache: Api.createCache(now: () => now),
        db: db,
        config: const SyncConfig(pause: Duration.zero),
        now: () => now,
      );
      poller = Poller(sync: sync, db: db, notifier: notifier, now: () => now);
    });

    tearDown(() async {
      await sync.stop();
      await service.dispose();
      db.close();
    });

    Future<(Handler, String)> loggedIn(Poller? p) async {
      final handler = Api(
        service: service,
        passwordHash: hash,
        poller: p,
        now: () => now,
      ).handler;
      final r = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/auth/login'),
          body: '{"password":"richtig123"}',
          headers: {'content-type': 'application/json'},
        ),
      );
      return (handler, r.headers['set-cookie']!.split(';').first);
    }

    Future<Response> call(
      Handler h,
      String method,
      String path,
      String c,
    ) async => await h(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {'cookie': c},
      ),
    );

    test('disabled without poller', () async {
      final (h, c) = await loggedIn(null);
      final r = await call(h, 'GET', '/api/notifications', c);
      expect(jsonDecode(await r.readAsString()), {'enabled': false});
      expect(
        (await call(h, 'POST', '/api/notifications/test', c)).statusCode,
        409,
      );
    });

    test('status, test message and manual check', () async {
      final (h, c) = await loggedIn(poller);
      var r = await call(h, 'POST', '/api/notifications/test', c);
      expect(r.statusCode, 204);
      expect(notifier.sent.single.title, 'Schulportal: Test');

      r = await call(h, 'POST', '/api/notifications/check', c);
      expect(jsonDecode(await r.readAsString()), {'sent': 0});

      r = await call(h, 'GET', '/api/notifications', c);
      final b = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      expect(b['enabled'], isTrue);
      expect(b['target'], 'test');
      expect(b['status']['homework']['baseline'], isTrue);

      notifier.failNext = 1;
      r = await call(h, 'POST', '/api/notifications/test', c);
      expect(r.statusCode, 502);
    });

    test('requires login', () async {
      final (h, _) = await loggedIn(poller);
      final r = await call(h, 'GET', '/api/notifications', 'x=y');
      expect(r.statusCode, 401);
    });
  });
}
