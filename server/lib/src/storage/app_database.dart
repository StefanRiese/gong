import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../api/cache.dart';

/// App state in SQLite: seen items for change detection, poll status,
/// web UI sessions, cached portal data.
class AppDatabase implements CacheStore {
  final Database _db;

  AppDatabase._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _migrate();
  }

  /// Opens (and creates) the database file at [path].
  factory AppDatabase.open(String path) => AppDatabase._(sqlite3.open(path));

  /// Version of the loaded SQLite library.
  static String get sqliteVersion => sqlite3.version.libVersion;

  /// In-memory database for tests.
  factory AppDatabase.inMemory() => AppDatabase._(sqlite3.openInMemory());

  static const _schemaVersion = 2;

  void _migrate() {
    final version = _db.userVersion;
    if (version > _schemaVersion) {
      throw StateError(
        'Database schema $version is newer than this program '
        '($_schemaVersion). Please update.',
      );
    }
    if (version < 1) {
      _db.execute('''
        CREATE TABLE seen (
          kind TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          first_seen INTEGER NOT NULL,
          PRIMARY KEY (kind, fingerprint)
        );
        CREATE TABLE meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE sessions (
          token_hash TEXT PRIMARY KEY,
          expires INTEGER NOT NULL
        );
      ''');
      _db.userVersion = 1;
    }
    if (version < 2) {
      _db.execute('''
        CREATE TABLE cache (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          fetched_at INTEGER NOT NULL
        );
      ''');
      _db.userVersion = 2;
    }
  }

  // --- cached portal data (CacheStore) ------------------------------------------

  @override
  Iterable<({String key, String json, DateTime fetchedAt})> loadAll() => [
    for (final row in _db.select(
      'SELECT key, value, fetched_at FROM cache ORDER BY fetched_at',
    ))
      (
        key: row['key'] as String,
        json: row['value'] as String,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          row['fetched_at'] as int,
        ),
      ),
  ];

  @override
  void save(String key, String json, DateTime fetchedAt) => _db.execute(
    'INSERT OR REPLACE INTO cache (key, value, fetched_at) VALUES (?, ?, ?)',
    [key, json, fetchedAt.millisecondsSinceEpoch],
  );

  @override
  void delete(String key) =>
      _db.execute('DELETE FROM cache WHERE key = ?', [key]);

  // --- change detection ------------------------------------------------------

  /// Fingerprints already seen for [kind].
  Set<String> seen(String kind) => {
    for (final row in _db.select(
      'SELECT fingerprint FROM seen WHERE kind = ?',
      [kind],
    ))
      row['fingerprint'] as String,
  };

  void markSeen(String kind, Iterable<String> fingerprints, DateTime now) {
    final stmt = _db.prepare(
      'INSERT OR IGNORE INTO seen (kind, fingerprint, first_seen) VALUES (?, ?, ?)',
    );
    _db.execute('BEGIN');
    try {
      for (final f in fingerprints) {
        stmt.execute([kind, f, now.millisecondsSinceEpoch]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.close();
    }
  }

  /// Removes fingerprints first seen before [cutoff] that are no longer
  /// present (keeps current ones so they are not reported again).
  void pruneSeen(String kind, Set<String> current, DateTime cutoff) {
    final old = _db.select(
      'SELECT fingerprint FROM seen WHERE kind = ? AND first_seen < ?',
      [kind, cutoff.millisecondsSinceEpoch],
    );
    final stmt = _db.prepare(
      'DELETE FROM seen WHERE kind = ? AND fingerprint = ?',
    );
    try {
      for (final row in old) {
        final f = row['fingerprint'] as String;
        if (!current.contains(f)) stmt.execute([kind, f]);
      }
    } finally {
      stmt.close();
    }
  }

  // --- key/value ---------------------------------------------------------------

  String? getMeta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String value) => _db.execute(
    'INSERT INTO meta (key, value) VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  Map<String, Object?>? getJson(String key) {
    final raw = getMeta(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, Object?>;
    } on FormatException {
      return null;
    }
  }

  void setJson(String key, Map<String, Object?> value) =>
      setMeta(key, jsonEncode(value));

  // --- sessions (tokens are stored hashed) -------------------------------------

  static String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  void saveSession(String token, DateTime expires) => _db.execute(
    'INSERT INTO sessions (token_hash, expires) VALUES (?, ?) '
    'ON CONFLICT(token_hash) DO UPDATE SET expires = excluded.expires',
    [hashToken(token), expires.millisecondsSinceEpoch],
  );

  /// Deletes all sessions except [keep] (null = all).
  void deleteSessionsExcept(String? keep) => keep == null
      ? _db.execute('DELETE FROM sessions')
      : _db.execute('DELETE FROM sessions WHERE token_hash != ?', [
          hashToken(keep),
        ]);

  /// Forgets everything derived from the Schulportal account (seen items,
  /// notification and sync status, cached data), e.g. after switching to
  /// another account.
  void resetPortalState() {
    _db.execute('DELETE FROM seen');
    _db.execute(
      "DELETE FROM meta WHERE key LIKE 'poll:%' OR key LIKE 'sync:%'",
    );
    _db.execute('DELETE FROM cache');
  }

  /// Expiry of the session, or null if unknown.
  DateTime? sessionExpiry(String token) {
    final rows = _db.select(
      'SELECT expires FROM sessions WHERE token_hash = ?',
      [hashToken(token)],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['expires'] as int);
  }

  void deleteSession(String token) => _db.execute(
    'DELETE FROM sessions WHERE token_hash = ?',
    [hashToken(token)],
  );

  void purgeSessions(DateTime now) => _db.execute(
    'DELETE FROM sessions WHERE expires <= ?',
    [now.millisecondsSinceEpoch],
  );

  void close() => _db.close();
}
