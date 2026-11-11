import 'package:lumo_server/lumo_server.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

class _Meals implements MealsGateway {
  @override
  Uri? get orderUrl => null;

  @override
  Future<MealsSnapshot> load(DateTime today) async =>
      MealsSnapshot(balanceCents: 0, orders: const []);
}

void main() {
  late AppDatabase db;
  late SyncService sync;
  final now = DateTime(2026, 11, 11, 12);

  SyncService build({bool enabled = true, bool withMeals = false}) {
    return SyncService(
      service: SphService(FakeGateway()),
      cache: ResponseCache(serveStaleOn: (_) => false),
      db: db,
      meals: withMeals ? _Meals() : null,
      config: SyncConfig(enabled: enabled),
    );
  }

  void status(
    SyncTask task, {
    DateTime? lastRun,
    DateTime? lastSuccess,
    String? error,
    int failures = 0,
  }) => db.setJson(
    'sync:${task.name}',
    SyncStatus(
      lastRun: lastRun,
      lastSuccess: lastSuccess,
      lastError: error,
      failures: failures,
    ).toJson(),
  );

  const portalTasks = [
    SyncTask.account,
    SyncTask.timetable,
    SyncTask.substitutions,
    SyncTask.homework,
    SyncTask.calendar,
    SyncTask.lessons,
  ];

  ServiceHealth? portal([SyncService? s]) => healthOfTasks(
    key: 'schulportal',
    name: 'Schulportal',
    sync: s ?? sync,
    tasks: portalTasks,
    now: now,
  );

  setUp(() {
    db = AppDatabase.inMemory();
    sync = build();
  });
  tearDown(() => db.close());

  group('Schulportal / sync tasks', () {
    test('never asked yet: gray', () {
      final h = portal()!;
      expect(h.state, HealthState.unknown);
      expect(h.detail, 'Noch nicht abgefragt');
    });

    test('background sync off: gray', () {
      expect(portal(build(enabled: false))!.state, HealthState.unknown);
    });

    test('last runs succeeded: green with the latest success', () {
      final recent = now.subtract(const Duration(minutes: 3));
      status(SyncTask.homework, lastRun: recent, lastSuccess: recent);
      status(
        SyncTask.timetable,
        lastRun: now.subtract(const Duration(hours: 2)),
        lastSuccess: now.subtract(const Duration(hours: 2)),
      );
      final h = portal()!;
      expect(h.state, HealthState.ok);
      expect(h.lastSuccess, recent);
    });

    test('one failed attempt: yellow, will be retried', () {
      status(
        SyncTask.homework,
        lastRun: now,
        lastSuccess: now.subtract(const Duration(hours: 1)),
        error: 'Schulportal nicht erreichbar',
        failures: 1,
      );
      final h = portal()!;
      expect(h.state, HealthState.warn);
      expect(h.detail, contains('Schulportal nicht erreichbar'));
      expect(h.detail, contains('erneut versucht'));
    });

    test('three failed attempts in a row: red', () {
      status(
        SyncTask.homework,
        lastRun: now,
        error: 'Schulportal nicht erreichbar',
        failures: failuresUntilError,
      );
      final h = portal()!;
      expect(h.state, HealthState.error);
      expect(h.detail, contains('3. Versuch in Folge'));
    });

    test('a rejected login is red at once', () {
      status(
        SyncTask.account,
        lastRun: now,
        error: 'Anmeldung beim Schulportal fehlgeschlagen',
        failures: 1,
      );
      final h = portal()!;
      expect(h.state, HealthState.error);
      expect(h.detail, contains('Zugangsdaten'));
    });

    test('nothing failed but the data is old: yellow', () {
      final old = now.subtract(const Duration(days: 2));
      status(SyncTask.homework, lastRun: old, lastSuccess: old);
      final h = portal()!;
      expect(h.state, HealthState.warn);
      expect(h.detail, 'Die Daten sind veraltet');
    });

    test('the worst task decides', () {
      status(SyncTask.homework, lastRun: now, lastSuccess: now);
      status(
        SyncTask.lessons,
        lastRun: now,
        error: 'Unerwartete Daten vom Schulportal',
        failures: 4,
      );
      expect(portal()!.state, HealthState.error);
    });

    test('Caseda only exists when it is set up', () {
      expect(
        healthOfTasks(
          key: 'caseda',
          name: 'Caseda',
          sync: sync,
          tasks: const [SyncTask.meals],
          now: now,
        ),
        isNull,
      );
      final withMeals = build(withMeals: true);
      status(SyncTask.meals, lastRun: now, lastSuccess: now);
      final h = healthOfTasks(
        key: 'caseda',
        name: 'Caseda',
        sync: withMeals,
        tasks: const [SyncTask.meals],
        now: now,
      )!;
      expect(h.state, HealthState.ok);
    });

    test('stale limit: three intervals, at least 12 hours', () {
      expect(
        staleAfter(const Duration(minutes: 15)),
        const Duration(hours: 12),
      );
      expect(staleAfter(const Duration(hours: 6)), const Duration(hours: 18));
    });
  });

  group('ntfy', () {
    const ok = PollStatus(lastRun: null);

    test('off: not shown', () {
      expect(
        healthOfNtfy(configured: false, reachable: null, statuses: []),
        isNull,
      );
    });

    test('reachable: green; not reachable: red; not asked yet: gray', () {
      expect(
        healthOfNtfy(configured: true, reachable: true, statuses: [ok])!.state,
        HealthState.ok,
      );
      expect(
        healthOfNtfy(configured: true, reachable: false, statuses: [ok])!.state,
        HealthState.error,
      );
      expect(
        healthOfNtfy(configured: true, reachable: null, statuses: [ok])!.state,
        HealthState.unknown,
      );
    });

    test('a failed delivery is red although the server answers', () {
      final h = healthOfNtfy(
        configured: true,
        reachable: true,
        statuses: const [
          PollStatus(lastError: 'Senden fehlgeschlagen: ntfy answered 403'),
        ],
      )!;
      expect(h.state, HealthState.error);
      expect(h.detail, contains('403'));
    });
  });

  group('update check', () {
    test('off: not shown', () {
      expect(healthOfUpdates({'checkEnabled': false}), isNull);
    });

    test('error: yellow; never checked: gray; fine: green', () {
      expect(
        healthOfUpdates({
          'checkEnabled': true,
          'checkError': 'Update-Server nicht erreichbar',
        })!.state,
        HealthState.warn,
      );
      expect(
        healthOfUpdates({'checkEnabled': true})!.state,
        HealthState.unknown,
      );
      final h = healthOfUpdates({
        'checkEnabled': true,
        'checkedAt': '2026-11-11T10:00:00Z',
        'available': true,
        'latest': 'v0.20.0',
      })!;
      expect(h.state, HealthState.ok);
      expect(h.detail, 'Update v0.20.0 verfügbar');
    });
  });
}
