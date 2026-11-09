import 'dart:convert';
import 'dart:math';

import '../storage/app_database.dart';

/// Login sessions for the web UI (sliding expiry).
///
/// With a [database], sessions survive restarts (tokens are stored hashed);
/// without, they live in memory only.
class SessionStore {
  final Duration ttl;
  final AppDatabase? database;
  final DateTime Function() _now;
  final _sessions = <String, DateTime>{};
  final _persistedExpiry = <String, DateTime>{};
  final _random = Random.secure();

  /// Persisted expiry is only rewritten when it moved by more than this,
  /// to avoid a database write on every request.
  static const _persistThreshold = Duration(days: 1);

  SessionStore({
    this.ttl = const Duration(days: 30),
    this.database,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  int get length => _sessions.length;

  /// Creates a session and returns its token.
  String create() {
    _purgeExpired();
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    final expires = _now().add(ttl);
    _sessions[token] = expires;
    _persist(token, expires);
    return token;
  }

  /// True if [token] is a valid session; extends its lifetime.
  bool validate(String? token) {
    if (token == null || token.isEmpty) return false;
    var expires = _sessions[token];
    if (expires == null && database != null) {
      expires = database!.sessionExpiry(token);
      if (expires != null) _persistedExpiry[token] = expires;
    }
    if (expires == null) return false;
    final now = _now();
    if (!now.isBefore(expires)) {
      revoke(token);
      return false;
    }
    final renewed = now.add(ttl);
    _sessions[token] = renewed;
    final persisted = _persistedExpiry[token];
    if (persisted == null ||
        renewed.difference(persisted) > _persistThreshold) {
      _persist(token, renewed);
    }
    return true;
  }

  /// Ends all sessions except [keep] (e.g. after a password change).
  void revokeAllExcept(String? keep) {
    _sessions.removeWhere((t, _) => t != keep);
    _persistedExpiry.removeWhere((t, _) => t != keep);
    database?.deleteSessionsExcept(keep);
  }

  void revoke(String? token) {
    if (token == null) return;
    _sessions.remove(token);
    _persistedExpiry.remove(token);
    database?.deleteSession(token);
  }

  void _persist(String token, DateTime expires) {
    if (database == null) return;
    database!.saveSession(token, expires);
    _persistedExpiry[token] = expires;
  }

  void _purgeExpired() {
    final now = _now();
    _sessions.removeWhere((_, expires) => !now.isBefore(expires));
    _persistedExpiry.removeWhere((t, _) => !_sessions.containsKey(t));
    database?.purgeSessions(now);
  }
}

/// Limits failed login attempts per client.
class LoginRateLimiter {
  final int maxFailures;
  final Duration window;
  final DateTime Function() _now;
  final _failures = <String, List<DateTime>>{};

  LoginRateLimiter({
    this.maxFailures = 5,
    this.window = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Null if [client] may try to log in, otherwise how long to wait.
  Duration? retryAfter(String client) {
    final recent = _recent(client);
    if (recent.length < maxFailures) return null;
    final wait = recent.first.add(window).difference(_now());
    return wait.isNegative ? null : wait;
  }

  void recordFailure(String client) {
    _recent(client).add(_now());
    if (_failures.length > 10000) {
      _failures.removeWhere((k, _) => _recent(k).isEmpty);
    }
  }

  void reset(String client) => _failures.remove(client);

  List<DateTime> _recent(String client) {
    final cutoff = _now().subtract(window);
    final list = _failures.putIfAbsent(client, () => []);
    list.removeWhere((t) => !t.isAfter(cutoff));
    return list;
  }
}
