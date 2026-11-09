import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import '../auth/password.dart';
import '../auth/sessions.dart';
import '../notify/notifier.dart';
import '../notify/poller.dart';
import '../sph/errors.dart';
import '../sph/sph_service.dart';
import 'cache.dart';

/// How long each kind of data is cached before Schulportal is asked again.
class CacheTtl {
  static const account = Duration(hours: 1);
  static const timetable = Duration(hours: 6);
  static const substitutions = Duration(minutes: 10);
  static const calendar = Duration(hours: 1);
  static const courses = Duration(hours: 1);
  static const courseDetails = Duration(minutes: 30);
  static const homework = Duration(minutes: 15);
  static const grades = Duration(hours: 1);
}

const sessionCookie = 'sph_session';
const _maxLoginBody = 4096;
const _maxCalendarRange = Duration(days: 400);

/// HTTP API (and optional static web UI) on top of [SphService].
///
/// Endpoints (all JSON):
///   GET  /healthz
///   POST /api/auth/login    {"password": "..."}  → sets session cookie
///   POST /api/auth/logout
///   GET  /api/auth/me
///   GET  /api/account | timetable | substitutions | courses | homework | grades
///   GET  /api/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD
///   GET  /api/courses/{id}
///   POST /api/refresh       clears the cache
///   GET  /api/notifications          notification settings + poll status
///   POST /api/notifications/test     send a test notification
///   POST /api/notifications/check    check for changes now
/// Data endpoints accept `?refresh=1` to bypass the cache and answer with
/// `{"data": …, "fetchedAt": …, "cached": bool, "stale": bool}`.
class Api {
  final SphService service;
  final String passwordHash;
  final SessionStore sessions;
  final LoginRateLimiter limiter;
  final ResponseCache cache;
  final bool cookieSecure;
  final bool trustProxy;
  final String? webDir;

  /// Background polling + notifications; null = disabled.
  final Poller? poller;
  final DateTime Function() _now;

  Api({
    required this.service,
    required this.passwordHash,
    SessionStore? sessions,
    LoginRateLimiter? limiter,
    ResponseCache? cache,
    this.cookieSecure = false,
    this.trustProxy = false,
    this.webDir,
    this.poller,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       sessions = sessions ?? SessionStore(now: now),
       limiter = limiter ?? LoginRateLimiter(now: now),
       cache = cache ?? createCache(now: now);

  /// Cache shared by the API and the background poller.
  static ResponseCache createCache({DateTime Function()? now}) => ResponseCache(
    now: now,
    serveStaleOn: (e) =>
        e is SphUnavailableException ||
        e is SphDataException ||
        e is SphAuthException,
  );

  Handler get handler {
    final router = Router(notFoundHandler: _notFound)
      ..get('/healthz', (Request r) => _json(200, {'status': 'ok'}))
      ..post('/api/auth/login', _login)
      ..post('/api/auth/logout', _logout)
      ..get('/api/auth/me', _me)
      ..get(
        '/api/account',
        _data('account', CacheTtl.account, (_) => service.account()),
      )
      ..get(
        '/api/timetable',
        _data('timetable', CacheTtl.timetable, (_) => service.timetable()),
      )
      ..get(
        '/api/substitutions',
        _data(
          'substitutions',
          CacheTtl.substitutions,
          (_) => service.substitutions(),
        ),
      )
      ..get('/api/calendar', _calendar)
      ..get(
        '/api/courses',
        _data('courses', CacheTtl.courses, (_) => service.courses()),
      )
      ..get('/api/courses/<id>', (Request r, String id) {
        return _data(
          'course:$id',
          CacheTtl.courseDetails,
          (_) => service.courseDetails(id),
        )(r);
      })
      ..get(
        '/api/homework',
        _data('homework', CacheTtl.homework, (_) => service.homework()),
      )
      ..get(
        '/api/grades',
        _data('grades', CacheTtl.grades, (_) => service.grades()),
      )
      ..post('/api/refresh', _refresh)
      ..get('/api/notifications', _notifications)
      ..post('/api/notifications/test', _notificationTest)
      ..post('/api/notifications/check', _notificationCheck);

    return const Pipeline()
        .addMiddleware(_securityHeaders)
        .addHandler(router.call);
  }

  // --- auth ------------------------------------------------------------------

  Future<Response> _login(Request request) async {
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    final client = _clientId(request);
    final wait = limiter.retryAfter(client);
    if (wait != null) {
      return _error(
        429,
        'too_many_attempts',
        'Too many failed logins, try again later',
        headers: {'retry-after': '${wait.inSeconds + 1}'},
      );
    }

    final String? password;
    try {
      final body = await _readLimited(request, _maxLoginBody);
      final decoded = jsonDecode(body);
      password = decoded is Map ? decoded['password'] as String? : null;
    } on Object {
      return _error(400, 'bad_request', 'Expected {"password": "..."}');
    }
    if (password == null || password.isEmpty) {
      return _error(400, 'bad_request', 'Expected {"password": "..."}');
    }

    final hash = passwordHash;
    final ok = await Isolate.run(() => PasswordHasher.verify(password!, hash));
    if (!ok) {
      limiter.recordFailure(client);
      return _error(401, 'invalid_password', 'Wrong password');
    }
    limiter.reset(client);
    final token = sessions.create();
    return _json(
      200,
      {'authenticated': true},
      headers: {'set-cookie': _cookie(token, sessions.ttl)},
    );
  }

  Response _logout(Request request) {
    sessions.revoke(_sessionToken(request));
    return _json(
      200,
      {'authenticated': false},
      headers: {'set-cookie': _cookie('', Duration.zero)},
    );
  }

  Response _me(Request request) =>
      _json(200, {'authenticated': sessions.validate(_sessionToken(request))});

  bool _authorized(Request request) =>
      sessions.validate(_sessionToken(request));

  String _cookie(String value, Duration maxAge) => [
    '$sessionCookie=$value',
    'Path=/',
    'HttpOnly',
    'SameSite=Strict',
    'Max-Age=${maxAge.inSeconds}',
    if (cookieSecure) 'Secure',
  ].join('; ');

  String? _sessionToken(Request request) {
    final header = request.headers['cookie'];
    if (header == null) return null;
    for (final part in header.split(';')) {
      final i = part.indexOf('=');
      if (i < 0) continue;
      if (part.substring(0, i).trim() == sessionCookie) {
        return part.substring(i + 1).trim();
      }
    }
    return null;
  }

  String _clientId(Request request) {
    if (trustProxy) {
      final forwarded = request.headers['x-forwarded-for'];
      if (forwarded != null && forwarded.trim().isNotEmpty) {
        return forwarded.split(',').first.trim();
      }
    }
    final info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return 'unknown';
  }

  // --- data ------------------------------------------------------------------

  Handler _data(
    String key,
    Duration ttl,
    Future<Object?> Function(Request request) load,
  ) {
    return (Request request) async {
      if (!_authorized(request)) {
        return _error(401, 'unauthorized', 'Login required');
      }
      final refresh = const {
        '1',
        'true',
      }.contains(request.url.queryParameters['refresh']);
      try {
        final result = await cache.get<Object?>(
          key,
          ttl,
          () => load(request),
          refresh: refresh,
        );
        return _json(200, {
          'data': result.value,
          'fetchedAt': result.fetchedAt.toUtc().toIso8601String(),
          'cached': result.cached,
          'stale': result.stale,
        });
      } on SphException catch (e) {
        return _sphError(e);
      } on ArgumentError catch (e) {
        return _error(400, 'bad_request', '${e.message}');
      }
    };
  }

  Future<Response> _calendar(Request request) async {
    final q = request.url.queryParameters;
    DateTime? from, to;
    try {
      from = q['from'] == null ? null : _parseDate(q['from']!);
      to = q['to'] == null ? null : _parseDate(q['to']!);
    } on FormatException {
      return _error(400, 'bad_request', 'Dates must be YYYY-MM-DD');
    }
    final today = _now();
    final start = from ?? DateTime(today.year, today.month, today.day);
    final end = to ?? start.add(const Duration(days: 60));
    if (end.isBefore(start)) {
      return _error(400, 'bad_request', '"to" must not be before "from"');
    }
    if (end.difference(start) > _maxCalendarRange) {
      return _error(400, 'bad_request', 'Range must not exceed 400 days');
    }
    return _data(
      'calendar:${_ymd(start)}:${_ymd(end)}',
      CacheTtl.calendar,
      (_) => service.calendar(from: start, to: end),
    )(request);
  }

  Response _refresh(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    cache.clear();
    return Response(204);
  }

  // --- notifications -----------------------------------------------------------

  Response _notifications(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final p = poller;
    if (p == null) return _json(200, {'enabled': false});
    final c = p.config;
    return _json(200, {
      'enabled': true,
      'target': p.notifier.description,
      'kinds': [for (final k in c.kinds) k.name],
      'intervalMinutes': c.interval.inMinutes,
      'gradesIntervalMinutes': c.gradesInterval.inMinutes,
      'activeHours': [c.activeFromHour, c.activeToHour],
      'includeGradeValues': c.includeGradeValues,
      'status': {
        for (final k in c.kinds)
          k.name: {
            ...p.status(k).toJson(),
            'nextRun': p.nextRun(k).toUtc().toIso8601String(),
          },
      },
    });
  }

  Future<Response> _notificationTest(Request request) async {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final p = poller;
    if (p == null) {
      return _error(409, 'notifications_disabled', 'NTFY_TOPIC is not set');
    }
    try {
      await p.notifier.send(
        const AppNotification(
          title: 'Schulportal: Test',
          message: 'Benachrichtigungen funktionieren.',
          tags: ['white_check_mark'],
          clickPath: '/benachrichtigungen',
        ),
      );
      return Response(204);
    } on NotifyException catch (e) {
      return _error(502, 'notify_failed', e.message);
    }
  }

  Future<Response> _notificationCheck(Request request) async {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final p = poller;
    if (p == null) {
      return _error(409, 'notifications_disabled', 'NTFY_TOPIC is not set');
    }
    final sent = await p.runNow();
    return _json(200, {'sent': sent});
  }

  // --- static web UI / fallbacks -----------------------------------------------

  FutureOr<Response> _notFound(Request request) {
    final path = request.url.path;
    if (webDir == null ||
        path == 'api' ||
        path.startsWith('api/') ||
        request.method != 'GET' && request.method != 'HEAD') {
      return _error(404, 'not_found', 'No such endpoint');
    }
    return _static(request);
  }

  late final Handler _staticFiles = createStaticHandler(
    webDir!,
    defaultDocument: 'index.html',
  );

  /// Serves files from [webDir]; unknown paths get index.html (SPA routing).
  Future<Response> _static(Request request) async {
    final response = await _staticFiles(request);
    if (response.statusCode != 404) return response;
    final index = File('$webDir/index.html');
    if (!index.existsSync()) return response;
    return Response.ok(
      index.openRead(),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  // --- helpers ---------------------------------------------------------------

  /// Only same-origin scripts/styles; no inline code, no framing, no plugins.
  static const contentSecurityPolicy =
      "default-src 'self'; script-src 'self'; style-src 'self'; "
      "img-src 'self' data:; connect-src 'self'; manifest-src 'self'; "
      "object-src 'none'; base-uri 'none'; form-action 'self'; "
      "frame-ancestors 'none'";

  static Handler _securityHeaders(Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      final isApi = request.url.path.startsWith('api/');
      return response.change(
        headers: {
          'x-content-type-options': 'nosniff',
          'x-frame-options': 'DENY',
          'referrer-policy': 'no-referrer',
          'content-security-policy': contentSecurityPolicy,
          // API data must not be cached; web UI files are revalidated on each
          // load (ETag/Last-Modified) so updates show up immediately.
          'cache-control': isApi ? 'no-store' : 'no-cache',
        },
      );
    };
  }

  Response _sphError(SphException e) => switch (e) {
    SphAuthException() => _error(
      503,
      'sph_auth_failed',
      e.message,
      extra: {'retryAfter': e.retryAfter?.toUtc().toIso8601String()},
    ),
    SphUnavailableException() => _error(503, 'sph_unavailable', e.message),
    SphFeatureDisabledException() => _error(404, 'feature_disabled', e.message),
    SphNotFoundException() => _error(404, 'not_found', e.message),
    SphDataException() => _error(
      502,
      'sph_bad_response',
      'Unexpected response from Schulportal',
    ),
  };

  static bool _isJson(Request r) =>
      (r.mimeType ?? '').toLowerCase() == 'application/json';

  static Future<String> _readLimited(Request request, int max) async {
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > max) throw const FormatException('Body too large');
    }
    return utf8.decode(bytes);
  }

  static final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static DateTime _parseDate(String s) {
    if (!_datePattern.hasMatch(s)) throw FormatException('Bad date', s);
    final d = DateTime.parse(s);
    if (_ymd(d) != s) throw FormatException('Bad date', s);
    return d;
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static Response _json(
    int status,
    Object? body, {
    Map<String, String> headers = const {},
  }) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );

  static Response _error(
    int status,
    String code,
    String message, {
    Map<String, Object?> extra = const {},
    Map<String, String> headers = const {},
  }) => _json(status, {
    'error': {'code': code, 'message': message, ...extra},
  }, headers: headers);
}
