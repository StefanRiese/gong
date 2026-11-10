import 'dart:async';
import 'dart:convert';

/// Result of a cached lookup.
class CacheResult<T> {
  final T value;
  final DateTime fetchedAt;

  /// Served from cache without waiting for Schulportal.
  final bool cached;

  /// Served from an expired entry whose last refresh failed (portal down).
  final bool stale;

  /// A refresh of this entry is running in the background.
  final bool refreshing;

  const CacheResult(
    this.value,
    this.fetchedAt, {
    required this.cached,
    required this.stale,
    this.refreshing = false,
  });
}

/// A changed cache entry, e.g. for pushing updates to the web UI.
class CacheUpdate {
  final String key;
  final DateTime fetchedAt;

  const CacheUpdate(this.key, this.fetchedAt);
}

/// Converts cached values to JSON-compatible data and back (persistence).
class CacheCodec {
  final Object? Function(Object? json) decode;

  const CacheCodec(this.decode);
}

/// Persistent storage of cache entries (JSON text).
abstract interface class CacheStore {
  Iterable<({String key, String json, DateTime fetchedAt})> loadAll();
  void save(String key, String json, DateTime fetchedAt);
  void delete(String key);
}

class _Entry {
  final Object? value;
  final DateTime fetchedAt;

  _Entry(this.value, this.fetchedAt);
}

/// TTL cache in front of [SphService].
///
/// - concurrent requests for the same key share one load
/// - [read] answers from the cache right away and refreshes expired entries
///   in the background (stale-while-revalidate); only a missing entry waits
/// - [get] waits for a load when the entry is expired or `refresh` is set;
///   on failure an expired entry is served as stale if [serveStaleOn]
///   accepts the error (e.g. portal down)
/// - with a [store], entries survive restarts (keys with a codec only)
/// - [updates] reports every new or changed entry
class ResponseCache {
  final DateTime Function() _now;
  final bool Function(Object error) serveStaleOn;
  final int maxEntries;
  final CacheStore? _store;
  final CacheCodec? Function(String key) _codecFor;
  final _entries = <String, _Entry>{};
  final _pending = <String, Future<_Entry>>{};

  /// Keys whose last load failed after their entry was stored.
  final _failed = <String, DateTime>{};
  final _updates = StreamController<CacheUpdate>.broadcast(sync: true);

  ResponseCache({
    required this.serveStaleOn,
    this.maxEntries = 300,
    CacheStore? store,
    CacheCodec? Function(String key)? codecFor,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _store = store,
       _codecFor = codecFor ?? ((_) => null) {
    _restore();
  }

  Stream<CacheUpdate> get updates => _updates.stream;

  /// Cached value right away; an entry older than [ttl] is refreshed in the
  /// background. Without an entry, waits for [load].
  Future<CacheResult<T>> read<T>(
    String key,
    Duration ttl,
    Future<T> Function() load,
  ) async {
    final existing = _entries[key];
    if (existing == null) return get(key, ttl, load);
    final expired = _now().difference(existing.fetchedAt) >= ttl;
    if (expired && !_pending.containsKey(key)) {
      _load(key, load).then<void>((_) {}, onError: (Object _) {}).ignore();
    }
    return CacheResult(
      existing.value as T,
      existing.fetchedAt,
      cached: true,
      stale: expired && _failedSince(key, existing),
      refreshing: _pending.containsKey(key),
    );
  }

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

  /// Stores [value] as freshly loaded (e.g. results of a sync run).
  /// Cached value without loading anything; null if there is none (or another type).
  T? peek<T>(String key) {
    final v = _entries[key]?.value;
    return v is T ? v : null;
  }

  void put<T>(String key, T value) => _set(key, _Entry(value, _now()));

  /// Removes all entries.
  void clear() {
    for (final key in _entries.keys.toList()) {
      remove(key);
    }
  }

  /// Removes one entry (e.g. after data was changed).
  void remove(String key) {
    _entries.remove(key);
    _failed.remove(key);
    _store?.delete(key);
  }

  /// When [key] was last loaded, or null if not cached.
  DateTime? fetchedAt(String key) => _entries[key]?.fetchedAt;

  /// Whether a load of [key] is running.
  bool isLoading(String key) => _pending.containsKey(key);

  /// Replaces the cached value of [key] (keeping its age), e.g. to apply a
  /// change the user just made without reloading from Schulportal.
  void update<T>(String key, T Function(T value) change) {
    final e = _entries[key];
    if (e == null || e.value is! T) return;
    _set(key, _Entry(change(e.value as T), e.fetchedAt), keepFailure: true);
  }

  bool _failedSince(String key, _Entry entry) {
    final failed = _failed[key];
    return failed != null && !failed.isBefore(entry.fetchedAt);
  }

  void _set(String key, _Entry entry, {bool keepFailure = false}) {
    _entries.remove(key);
    _entries[key] = entry;
    if (!keepFailure) _failed.remove(key);
    while (_entries.length > maxEntries) {
      remove(_entries.keys.first);
    }
    _persist(key, entry);
    _updates.add(CacheUpdate(key, entry.fetchedAt));
  }

  void _persist(String key, _Entry entry) {
    final store = _store;
    if (store == null || _codecFor(key) == null) return;
    try {
      store.save(key, jsonEncode(entry.value), entry.fetchedAt);
    } on Object {
      // Persistence is best effort; the in-memory entry is still valid.
    }
  }

  void _restore() {
    final store = _store;
    if (store == null) return;
    for (final row in store.loadAll()) {
      final codec = _codecFor(row.key);
      if (codec == null) continue;
      try {
        _entries[row.key] = _Entry(
          codec.decode(jsonDecode(row.json)),
          row.fetchedAt,
        );
      } on Object {
        // Format changed or damaged: drop it, it is loaded again on demand.
        store.delete(row.key);
      }
    }
  }

  Future<_Entry> _load<T>(String key, Future<T> Function() load) {
    final running = _pending[key];
    if (running != null) return running;
    final attempt = Future(() async {
      try {
        final entry = _Entry(await load(), _now());
        _set(key, entry);
        return entry;
      } catch (_) {
        _failed[key] = _now();
        rethrow;
      }
    });
    _pending[key] = attempt;
    attempt.whenComplete(() {
      if (identical(_pending[key], attempt)) _pending.remove(key);
    }).ignore();
    return attempt;
  }

  Future<void> close() => _updates.close();
}
