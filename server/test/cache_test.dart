import 'dart:async';

import 'package:schulportal_server/schulportal_server.dart';
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
}
