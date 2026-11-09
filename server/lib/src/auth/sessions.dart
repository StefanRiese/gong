import 'dart:convert';
import 'dart:math';

/// In-memory login sessions for the web UI (sliding expiry).
///
/// Sessions are lost on restart; users then simply log in again.
class SessionStore {
  final Duration ttl;
  final DateTime Function() _now;
  final _sessions = <String, DateTime>{};
  final _random = Random.secure();

  SessionStore({this.ttl = const Duration(days: 30), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  int get length => _sessions.length;

  /// Creates a session and returns its token.
  String create() {
    _purgeExpired();
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    _sessions[token] = _now().add(ttl);
    return token;
  }

  /// True if [token] is a valid session; extends its lifetime.
  bool validate(String? token) {
    if (token == null || token.isEmpty) return false;
    final expires = _sessions[token];
    if (expires == null) return false;
    final now = _now();
    if (!now.isBefore(expires)) {
      _sessions.remove(token);
      return false;
    }
    _sessions[token] = now.add(ttl);
    return true;
  }

  void revoke(String? token) {
    if (token != null) _sessions.remove(token);
  }

  void _purgeExpired() {
    final now = _now();
    _sessions.removeWhere((_, expires) => !now.isBefore(expires));
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
