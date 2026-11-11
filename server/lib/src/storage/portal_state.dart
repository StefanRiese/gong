import '../api/cache.dart';
import 'app_database.dart';

/// Per-account state in the database: change detection (seen items) and
/// sync / poll status. [AppDatabase] itself is the state of the first
/// account; [ScopedState] keeps the same for every further account apart.
abstract interface class PortalState {
  Set<String> seen(String kind);
  void markSeen(String kind, Iterable<String> fingerprints, DateTime now);
  void pruneSeen(String kind, Set<String> current, DateTime cutoff);
  Map<String, Object?>? getJson(String key);
  void setJson(String key, Map<String, Object?> value);
}

/// Prefix of all database keys of the account [id]. The first account has
/// no prefix (its data predates multiple accounts); `@` cannot start any
/// other key, so the scopes never overlap.
String scopePrefix(String id) => '@$id/';

/// [PortalState] of one further account: every key gets the scope prefix.
class ScopedState implements PortalState {
  final AppDatabase _db;
  final String prefix;

  ScopedState(this._db, this.prefix);

  @override
  Set<String> seen(String kind) => _db.seen('$prefix$kind');

  @override
  void markSeen(String kind, Iterable<String> fingerprints, DateTime now) =>
      _db.markSeen('$prefix$kind', fingerprints, now);

  @override
  void pruneSeen(String kind, Set<String> current, DateTime cutoff) =>
      _db.pruneSeen('$prefix$kind', current, cutoff);

  @override
  Map<String, Object?>? getJson(String key) => _db.getJson('$prefix$key');

  @override
  void setJson(String key, Map<String, Object?> value) =>
      _db.setJson('$prefix$key', value);
}

/// Cache entries of one account in the shared `cache` table; [prefix] ''
/// = the first account (all keys without scope prefix).
class ScopedCacheStore implements CacheStore {
  final AppDatabase _db;
  final String prefix;

  ScopedCacheStore(this._db, [this.prefix = '']);

  bool _mine(String key) =>
      prefix.isEmpty ? !key.startsWith('@') : key.startsWith(prefix);

  @override
  Iterable<({String key, String json, DateTime fetchedAt})> loadAll() => [
    for (final r in _db.loadAll())
      if (_mine(r.key))
        (
          key: r.key.substring(prefix.length),
          json: r.json,
          fetchedAt: r.fetchedAt,
        ),
  ];

  @override
  void save(String key, String json, DateTime fetchedAt) =>
      _db.save('$prefix$key', json, fetchedAt);

  @override
  void delete(String key) => _db.delete('$prefix$key');
}
