import 'dart:async';

/// Result of a cached lookup.
class CacheResult<T> {
  final T value;
  final DateTime fetchedAt;

  /// Served from cache without asking Schulportal.
  final bool cached;

  /// Served from an expired cache entry because loading failed.
  final bool stale;

  const CacheResult(
    this.value,
    this.fetchedAt, {
    required this.cached,
    required this.stale,
  });
}

class _Entry {
  final Object? value;
  final DateTime fetchedAt;

  _Entry(this.value, this.fetchedAt);
}

/// In-memory TTL cache in front of [SphService].
///
/// - concurrent requests for the same key share one load
/// - on load failure, an expired entry is served as stale if
///   [serveStaleOn] accepts the error (e.g. portal down)
class ResponseCache {
  final DateTime Function() _now;
  final bool Function(Object error) serveStaleOn;
  final int maxEntries;
  final _entries = <String, _Entry>{};
  final _pending = <String, Future<_Entry>>{};

  ResponseCache({
    required this.serveStaleOn,
    this.maxEntries = 200,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  Future<CacheResult<T>> get<T>(
    String key,
    Duration ttl,
    Future<T> Function() load, {
    bool refresh = false,
  }) async {
    final existing = _entries[key];
    if (!refresh &&
        existing != null &&
        _now().difference(existing.fetchedAt) < ttl) {
      return CacheResult(
        existing.value as T,
        existing.fetchedAt,
        cached: true,
        stale: false,
      );
    }
    try {
      final entry = await _load(key, load);
      return CacheResult(
        entry.value as T,
        entry.fetchedAt,
        cached: false,
        stale: false,
      );
    } catch (e) {
      if (existing != null && serveStaleOn(e)) {
        return CacheResult(
          existing.value as T,
          existing.fetchedAt,
          cached: true,
          stale: true,
        );
      }
      rethrow;
    }
  }

  /// Removes all entries (e.g. after a manual refresh).
  void clear() => _entries.clear();

  Future<_Entry> _load<T>(String key, Future<T> Function() load) {
    final running = _pending[key];
    if (running != null) return running;
    final attempt = Future(() async {
      final value = await load();
      final entry = _Entry(value, _now());
      _entries.remove(key);
      _entries[key] = entry;
      while (_entries.length > maxEntries) {
        _entries.remove(_entries.keys.first);
      }
      return entry;
    });
    _pending[key] = attempt;
    attempt.whenComplete(() {
      if (identical(_pending[key], attempt)) _pending.remove(key);
    }).ignore();
    return attempt;
  }
}
