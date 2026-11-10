import 'dart:async';

import 'package:lumo_server/lumo_server.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late ResponseCache cache;
  const ttl = Duration(minutes: 10);

  setUp(() {
    now = DateTime(2026, 11, 9, 12);
    cache = ResponseCache(
      now: () => now,
      serveStaleOn: (e) => e is SphUnavailableException,
    );
  });

  test('caches within TTL and reloads after', () async {
    var loads = 0;
    Future<int> load() async => ++loads;

    final a = await cache.get('k', ttl, load);
    expect((a.value, a.cached, a.stale), (1, false, false));

    now = now.add(const Duration(minutes: 5));
    final b = await cache.get('k', ttl, load);
    expect((b.value, b.cached), (1, true));
    expect(b.fetchedAt, DateTime(2026, 11, 9, 12));

    now = now.add(const Duration(minutes: 6));
    final c = await cache.get('k', ttl, load);
    expect((c.value, c.cached), (2, false));
  });

  test('refresh bypasses the cache', () async {
    var loads = 0;
    await cache.get('k', ttl, () async => ++loads);
    final r = await cache.get('k', ttl, () async => ++loads, refresh: true);
    expect(r.value, 2);
  });

  test('concurrent requests share one load', () async {
    var loads = 0;
    final gate = Completer<void>();
    Future<int> load() async {
      loads++;
      await gate.future;
      return 42;
    }

    final f1 = cache.get('k', ttl, load);
    final f2 = cache.get('k', ttl, load);
    gate.complete();
    expect((await f1).value, 42);
    expect((await f2).value, 42);
    expect(loads, 1);
  });

  test('serves stale data when the portal is unavailable', () async {
    await cache.get('k', ttl, () async => 'old');
    now = now.add(const Duration(hours: 1));
    final r = await cache.get<String>(
      'k',
      ttl,
      () async => throw const SphUnavailableException('down'),
    );
    expect((r.value, r.cached, r.stale), ('old', true, true));
  });

  test('rethrows errors not accepted for stale serving', () async {
    await cache.get('k', ttl, () async => 'old');
    now = now.add(const Duration(hours: 1));
    expect(
      cache.get<String>(
        'k',
        ttl,
        () async => throw const SphNotFoundException('gone'),
      ),
      throwsA(isA<SphNotFoundException>()),
    );
  });

  test('rethrows when nothing is cached', () {
    expect(
      cache.get<String>(
        'k',
        ttl,
        () async => throw const SphUnavailableException('down'),
      ),
      throwsA(isA<SphUnavailableException>()),
    );
  });

  test('a synchronously throwing loader does not poison the key', () async {
    await expectLater(
      cache.get<int>('k', ttl, () => throw StateError('sync')),
      throwsStateError,
    );
    final r = await cache.get('k', ttl, () async => 7);
    expect(r.value, 7);
  });

  test('update changes the value but keeps its age', () async {
    await cache.get('k', ttl, () async => [1, 2]);
    now = now.add(const Duration(minutes: 3));
    cache.update<List<int>>('k', (v) => [...v, 3]);
    final r = await cache.get<List<int>>('k', ttl, () async => [9]);
    expect(r.value, [1, 2, 3]);
    expect(r.cached, isTrue);
    expect(cache.fetchedAt('k'), DateTime(2026, 11, 9, 12));
    cache.update<String>('k', (v) => 'wrong type ignored');
    cache.update<List<int>>('missing', (v) => v);
    expect(cache.fetchedAt('missing'), isNull);
  });

  test('clear removes entries; maxEntries evicts oldest', () async {
    final small = ResponseCache(maxEntries: 2, serveStaleOn: (_) => false);
    var loads = 0;
    await small.get('a', ttl, () async => ++loads);
    await small.get('b', ttl, () async => ++loads);
    await small.get('c', ttl, () async => ++loads);
    expect((await small.get('a', ttl, () async => ++loads)).cached, isFalse);
    expect((await small.get('c', ttl, () async => ++loads)).cached, isTrue);
    small.clear();
    expect((await small.get('c', ttl, () async => ++loads)).cached, isFalse);
  });

  group('read (stale-while-revalidate)', () {
    test(
      'answers right away and refreshes expired entries in background',
      () async {
        var loads = 0;
        final gate = Completer<void>();
        Future<int> load() async {
          loads++;
          if (loads > 1) await gate.future;
          return loads;
        }

        final first = await cache.read('k', ttl, load);
        expect(
          (first.value, first.cached),
          (1, false),
          reason: 'empty → waits',
        );

        now = now.add(const Duration(minutes: 11));
        final second = await cache.read('k', ttl, load);
        expect((second.value, second.cached, second.stale), (1, true, false));
        expect(second.refreshing, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(loads, 2);

        final third = await cache.read('k', ttl, load);
        expect(third.value, 1);
        expect(loads, 2, reason: 'one background refresh at a time');

        gate.complete();
        while (cache.isLoading('k')) {
          await Future<void>.delayed(Duration.zero);
        }
        final fourth = await cache.read('k', ttl, load);
        expect((fourth.value, fourth.refreshing), (2, false));
      },
    );

    test('failed background refresh marks the entry as stale', () async {
      await cache.read('k', ttl, () async => 1);
      now = now.add(const Duration(minutes: 11));
      await cache.read<int>(
        'k',
        ttl,
        () async => throw const SphUnavailableException('down'),
      );
      while (cache.isLoading('k')) {
        await Future<void>.delayed(Duration.zero);
      }
      final r = await cache.read<int>(
        'k',
        ttl,
        () => Completer<int>().future, // never finishes
      );
      expect((r.value, r.stale), (1, true));
    });
  });

  test('updates report new and changed entries', () async {
    final updates = <String>[];
    cache.updates.listen((u) => updates.add(u.key));
    await cache.get('a', ttl, () async => 1);
    cache.put('b', 2);
    cache.update<int>('b', (v) => v + 1);
    expect(updates, ['a', 'b', 'b']);
  });

  test('entries with a codec survive a restart via the store', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    ResponseCache create() => ResponseCache(
      now: () => now,
      serveStaleOn: (_) => false,
      store: db,
      codecFor: CacheKeys.codecFor,
    );

    final first = create();
    final hw = [
      Homework(
        courseId: 'c1',
        courseName: 'Mathe',
        entryId: 'e1',
        date: DateTime(2026, 11, 9),
        topic: 'Brüche',
        description: 'S. 12',
        done: false,
      ),
    ];
    first.put(CacheKeys.homework, hw);
    first.put('no-codec', 42);
    first.update<List<Homework>>(
      CacheKeys.homework,
      (l) => [for (final h in l) h.withDone(true)],
    );

    now = now.add(const Duration(hours: 1));
    final second = create();
    expect(second.fetchedAt(CacheKeys.homework), DateTime(2026, 11, 9, 12));
    expect(second.fetchedAt('no-codec'), isNull);
    final restored = (await second.read<List<Homework>>(
      CacheKeys.homework,
      const Duration(days: 1),
      () => throw StateError('should not load'),
    )).value;
    expect(restored.single.toJson(), hw.single.withDone(true).toJson());

    second.remove(CacheKeys.homework);
    expect(create().fetchedAt(CacheKeys.homework), isNull);
  });

  test('damaged stored entries are dropped', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    db.save(CacheKeys.timetable, '{"slots": [', now);
    final c = ResponseCache(
      serveStaleOn: (_) => false,
      store: db,
      codecFor: CacheKeys.codecFor,
    );
    expect(c.fetchedAt(CacheKeys.timetable), isNull);
    expect(db.loadAll(), isEmpty);
  });
}
