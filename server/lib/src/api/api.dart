import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import '../auth/password.dart';
import '../caseda/caseda.dart';
import '../auth/sessions.dart';
import '../config/app_config.dart';
import '../config/server_settings.dart';
import '../notify/notifier.dart';
import '../notify/poller.dart';
import '../models/models.dart';
import '../sph/errors.dart';
import '../sph/sph_service.dart';
import '../storage/settings_store.dart';
import '../sync/cache_keys.dart';
import '../sync/sync_service.dart';
import '../untis/compare.dart';
import '../untis/merge.dart';
import '../untis/untis.dart';
import '../update/update_service.dart';
import 'cache.dart';
import 'embedded_web.dart';
import 'query_filters.dart';
import 'server_control.dart';

/// How long each kind of data counts as fresh when the background sync does
/// not cover it (disabled, outside active hours). Older entries are still
/// served right away and refreshed in the background.
class CacheTtl {
  static const account = Duration(hours: 1);
  static const timetable = Duration(hours: 6);
  static const substitutions = Duration(minutes: 10);
  static const calendar = Duration(hours: 1);
  static const courses = Duration(hours: 1);
  static const courseDetails = Duration(minutes: 30);
  static const homework = Duration(minutes: 15);

  static const meals = Duration(hours: 2);
  static const allHomework = Duration(minutes: 45);
  static const grades = Duration(hours: 1);
}

const sessionCookie = 'sph_session';
const _maxLoginBody = 4096;
const _maxSettingsBody = 32 * 1024;
const _maxCalendarRange = Duration(days: 400);
const _maxEventStreams = 20;
const _eventPing = Duration(seconds: 25);

/// HTTP API (and optional static web UI) on top of [SphService].
///
/// Endpoints (all JSON):
///   GET  /healthz
///   POST /api/auth/login    {"password": "..."}  → sets session cookie
///   POST /api/auth/logout
///   GET  /api/auth/me
///   GET  /api/account | timetable | substitutions | courses | homework | grades
///   GET  /api/substitutions?alle=1  without the permanent class filter
///   URL filters like on the web UI pages: /api/substitutions?klasse=&art=&
///   ohne_art=&suche=&von=&bis=, /api/calendar?suche=, /api/homework?suche=
///   GET  /api/homework?alle=1   all homework incl. done and older entries
///   GET  /api/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD
///   GET  /api/courses/{id}
///   PUT  /api/courses/{id}/entries/{entry}/homework  {"done": bool}
///   POST /api/refresh       starts a sync of all data (202, async)
///   GET  /api/sync          sync status per task
///   GET  /api/events        Server-Sent Events: update {key, fetchedAt},
///                           sync {running}
///   GET  /api/setup         {setupRequired} (no login needed)
///   GET  /api/server-settings       server settings (secrets only as set/unset)
///   PUT  /api/server-settings       {settings, appPassword?, currentPassword?}
///   POST /api/server-settings/test-login  {schoolId, username, password?}
///   GET  /api/schools?q=…   school search (public list of Schulportal Hessen)
///   GET  /api/meals         school meals (Caseda): balance and own orders
///   POST /api/server-settings/test-caseda  {username, password?, url?}
///   POST /api/server-settings/test-untis   {server, username, password?, school?}
///   GET  /api/update        version, latest release, update state
///   POST /api/update/check  look for a new release now
///   POST /api/update/install  install the latest release (202, async)
/// While the server is not set up, the settings endpoints need the setup
/// token (header X-Setup-Token) instead of a login.
///   GET  /api/settings      user settings (subject colors)
///   PUT  /api/settings      change settings (fields not sent are kept)
///   GET  /api/notifications          notification settings + poll status
///   POST /api/notifications/test     send a test notification
///   POST /api/notifications/check    check for changes now
/// Data endpoints answer from the cache right away (expired entries are
/// refreshed in the background) with `{"data": …, "key": …, "fetchedAt": …,
/// "cached": bool, "stale": bool, "refreshing": bool}`; `?refresh=1` waits
/// for fresh data instead.
class Api {
  /// Replaced when the Schulportal credentials change (see [ServerControl]).
  SphService service;
  String passwordHash;
  final SessionStore sessions;
  final LoginRateLimiter limiter;
  final ResponseCache cache;
  final bool cookieSecure;
  final bool trustProxy;
  final String? webDir;

  /// Web UI compiled into the executable; used when [webDir] is null.
  final EmbeddedWeb? embeddedWeb;

  /// Notifications; null = disabled.
  Poller? poller;

  /// Background sync; null = data is only loaded on demand.
  SyncService? _sync;
  StreamSubscription<bool>? _syncSubscription;
  final _syncStates = StreamController<bool>.broadcast(sync: true);

  SyncService? get sync => _sync;

  /// Replaces the sync (settings changed); open event streams follow it.
  set sync(SyncService? value) {
    _syncSubscription?.cancel();
    _sync = value;
    _syncSubscription = value?.runningChanges.listen(_syncStates.add);
  }

  /// Setup page and server settings; null = not available (tests).
  ServerControl? control;

  /// Update check and installation; null = not available (tests).
  UpdateService? update;

  /// School meals (Caseda); null = not set up.
  MealsGateway? meals;

  /// Balance below this is highlighted in the web UI.
  int mealsBalanceWarningCents = 1000;

  /// WebUntis switched on: its changes are merged into the substitutions.
  bool untisEnabled = false;

  /// PBKDF2 cost for new web UI passwords; null = default (tests: lower).
  final int? passwordIterations;
  final SettingsStore settings;
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
    this.embeddedWeb,
    this.poller,
    SyncService? sync,
    this.control,
    this.passwordIterations,
    SettingsStore? settings,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       settings = settings ?? SettingsStore(),
       sessions = sessions ?? SessionStore(now: now),
       limiter = limiter ?? LoginRateLimiter(now: now),
       cache = cache ?? createCache(now: now) {
    this.sync = sync;
  }

  /// Cache shared by the API and the background sync; with [store] it
  /// survives restarts.
  static ResponseCache createCache({
    DateTime Function()? now,
    CacheStore? store,
  }) => ResponseCache(
    now: now,
    store: store,
    codecFor: CacheKeys.codecFor,
    serveStaleOn: (e) =>
        e is SphUnavailableException ||
        e is SphDataException ||
        e is SphAuthException ||
        e is CasedaException ||
        e is UntisException,
  );

  Handler get handler {
    final router = Router(notFoundHandler: _notFound)
      ..get(
        '/healthz',
        (Request r) => _json(200, {'status': 'ok', 'app': 'lumo'}),
      )
      ..post('/api/auth/login', _login)
      ..post('/api/auth/logout', _logout)
      ..get('/api/auth/me', _me)
      ..get(
        '/api/account',
        _data(CacheKeys.account, CacheTtl.account, (_) => service.account()),
      )
      ..get(
        '/api/timetable',
        _data(
          CacheKeys.timetable,
          CacheTtl.timetable,
          (_) => service.timetable(),
          present: _timetableDifferences,
        ),
      )
      ..get(
        '/api/substitutions',
        _data(
          CacheKeys.substitutions,
          CacheTtl.substitutions,
          (_) => service.substitutions(),
          present: _filterSubstitutions,
        ),
      )
      ..get('/api/calendar', _calendar)
      ..get(
        '/api/courses',
        _data(CacheKeys.courses, CacheTtl.courses, (_) => service.courses()),
      )
      ..get('/api/courses/<id>', (Request r, String id) {
        return _data(
          CacheKeys.course(id),
          CacheTtl.courseDetails,
          (_) => service.courseDetails(id),
        )(r);
      })
      ..put('/api/courses/<id>/entries/<entry>/homework', _setHomeworkDone)
      ..get('/api/homework', (Request r) {
        final all = const {'1', 'true'}.contains(r.url.queryParameters['alle']);
        return all
            ? _data(
                CacheKeys.allHomework,
                CacheTtl.allHomework,
                (_) => service.allHomework(),
                present: _searchHomework,
              )(r)
            : _data(
                CacheKeys.homework,
                CacheTtl.homework,
                (_) => service.homework(),
                present: _searchHomework,
              )(r);
      })
      ..get(
        '/api/grades',
        _data(CacheKeys.grades, CacheTtl.grades, (_) => service.grades()),
      )
      ..post('/api/refresh', _refresh)
      ..get('/api/sync', _syncStatus)
      ..get('/api/events', _events)
      ..get('/api/setup', _setup)
      ..get('/api/server-settings', _getServerSettings)
      ..put('/api/server-settings', _putServerSettings)
      ..post('/api/server-settings/test-login', _testLogin)
      ..post('/api/server-settings/test-caseda', _testCaseda)
      ..post('/api/server-settings/test-untis', _testUntis)
      ..get('/api/meals', _meals)
      ..get('/api/schools', _schools)
      ..get('/api/update', _updateStatus)
      ..post('/api/update/check', _updateCheck)
      ..post('/api/update/install', _updateInstall)
      ..get('/api/settings', _getSettings)
      ..put('/api/settings', _putSettings)
      ..get('/api/notifications', _notifications)
      ..post('/api/notifications/test', _notificationTest)
      ..post('/api/notifications/check', _notificationCheck);

    return const Pipeline()
        .addMiddleware(_securityHeaders)
        .addHandler(router.call);
  }

  // --- auth ------------------------------------------------------------------

  Future<Response> _login(Request request) async {
    if (control?.setupRequired ?? false) return _setupRequired();
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
      !(control?.setupRequired ?? false) &&
      sessions.validate(_sessionToken(request));

  Response _setupRequired() => _error(
    503,
    'setup_required',
    'The server is not set up yet (setup page)',
  );

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
    if (info is HttpConnectionInfo) {
      // IPv4 clients of the dual-stack socket appear as ::ffff:a.b.c.d.
      final a = info.remoteAddress.address;
      return a.startsWith('::ffff:') && a.contains('.') ? a.substring(7) : a;
    }
    return 'unknown';
  }

  // --- data ------------------------------------------------------------------

  /// Data endpoint over the cache. [present] can adapt the cached value for
  /// the response (e.g. apply a filter) and add fields to the envelope.
  Handler _data(
    String key,
    Duration ttl,
    Future<Object?> Function(Request request) load, {
    Map<String, Object?> Function(Object? value, Request request)? present,
  }) {
    return (Request request) async {
      if (control?.setupRequired ?? false) return _setupRequired();
      if (!_authorized(request)) {
        return _error(401, 'unauthorized', 'Login required');
      }
      final refresh = const {
        '1',
        'true',
      }.contains(request.url.queryParameters['refresh']);
      try {
        final result = refresh
            ? await cache.get<Object?>(
                key,
                ttl,
                () => load(request),
                refresh: true,
              )
            : await cache.read<Object?>(
                key,
                sync?.freshFor(key) ?? ttl,
                () => load(request),
              );
        return _json(200, {
          'data': result.value,
          ...?present?.call(result.value, request),
          'key': key,
          'fetchedAt': result.fetchedAt.toUtc().toIso8601String(),
          'cached': result.cached,
          'stale': result.stale,
          'refreshing': result.refreshing,
        });
      } on SphException catch (e) {
        return _sphError(e);
      } on CasedaException catch (e) {
        return _casedaError(e);
      } on ArgumentError catch (e) {
        return _error(400, 'bad_request', '${e.message}');
      }
    };
  }

  // --- school meals (Caseda) ---------------------------------------------------

  /// Balance and own orders; 404 meals_disabled if Caseda is not set up.
  Future<Response> _meals(Request request) async {
    if (control?.setupRequired ?? false) return _setupRequired();
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final m = meals;
    if (m == null) {
      return _error(404, 'meals_disabled', 'School meals are not set up');
    }
    return _data(
      CacheKeys.meals,
      CacheTtl.meals,
      (_) => m.load(_now()),
      present: (_, _) => {
        'balanceWarningCents': mealsBalanceWarningCents,
        'orderUrl': m.orderUrl?.toString(),
      },
    )(request);
  }

  Response _casedaError(CasedaException e) => e.isAuth
      ? _error(503, 'meals_auth_failed', e.message)
      : _error(503, 'meals_unavailable', e.message);

  /// Differences between the Schulportal timetable and WebUntis (second
  /// source): `differences` is only present when there are some.
  Map<String, Object?> _timetableDifferences(Object? value, Request request) {
    if (!untisEnabled || value is! Timetable) return const {};
    final diffs = compareTimetables(
      value,
      cache.peek<UntisSnapshot>(CacheKeys.untis),
      _now(),
    );
    return diffs.isEmpty
        ? const {}
        : {
            'differences': [for (final d in diffs) d.toJson()],
          };
  }

  /// The permanent filter from the settings (own classes, hidden types);
  /// `?alle=1` returns the full plan.
  Map<String, Object?> _filterSubstitutions(Object? value, Request request) {
    final filter = settings.load().substitutionFilter;
    final all = const {
      '1',
      'true',
    }.contains(request.url.queryParameters['alle']);
    if (value is! List<SubstitutionDay>) return const {};
    // WebUntis (second source) adds what the Schulportal plan does not have.
    final plan = untisEnabled
        ? mergeUntis(value, cache.peek<UntisSnapshot>(CacheKeys.untis))
        : value;
    // URL filters (klasse, art, ohne_art, suche, von, bis) on top.
    List<SubstitutionDay> query(List<SubstitutionDay> days) =>
        filterSubstitutionsByQuery(days, request.url.queryParameters) ?? days;
    if (all || !filter.isActive) {
      return {
        'data': query(plan),
        'filter': {'active': false, 'hidden': 0},
      };
    }
    final (days, hidden) = filter.apply(plan);
    return {
      'data': query(days),
      'filter': {'active': true, 'hidden': hidden, 'classes': filter.classes},
    };
  }

  /// `?suche=` for calendar and homework, like on the web UI pages.
  Map<String, Object?> _searchCalendar(Object? value, Request request) {
    if (value is! List<CalendarEntry>) return const {};
    final found = filterCalendarByQuery(value, request.url.queryParameters);
    return found == null ? const {} : {'data': found};
  }

  Map<String, Object?> _searchHomework(Object? value, Request request) {
    if (value is! List<Homework>) return const {};
    final found = filterHomeworkByQuery(value, request.url.queryParameters);
    return found == null ? const {} : {'data': found};
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
    final (defaultStart, defaultEnd) = CacheKeys.defaultCalendarRange(_now());
    final start = from ?? defaultStart;
    final end =
        to ?? (from == null ? defaultEnd : start.add(const Duration(days: 60)));
    if (end.isBefore(start)) {
      return _error(400, 'bad_request', '"to" must not be before "from"');
    }
    if (end.difference(start) > _maxCalendarRange) {
      return _error(400, 'bad_request', 'Range must not exceed 400 days');
    }
    return _data(
      CacheKeys.calendar(start, end),
      CacheTtl.calendar,
      (_) => service.calendar(from: start, to: end),
      present: _searchCalendar,
    )(request);
  }

  Future<Response> _setHomeworkDone(
    Request request,
    String courseId,
    String entryId,
  ) async {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    final bool done;
    try {
      final body = jsonDecode(await _readLimited(request, _maxLoginBody));
      final value = body is Map ? body['done'] : null;
      if (value is! bool) throw const FormatException();
      done = value;
    } on FormatException {
      return _error(400, 'bad_request', 'Expected {"done": true|false}');
    }
    try {
      await service.setHomeworkDone(courseId, entryId, done);
    } on SphException catch (e) {
      return _sphError(e);
    } on ArgumentError catch (e) {
      return _error(400, 'bad_request', '${e.message}');
    }
    // Apply the change to cached data instead of discarding it: reloading the
    // full homework list takes one portal request per course.
    List<Homework> patch(List<Homework> list) => [
      for (final h in list)
        h.courseId == courseId && h.entryId == entryId ? h.withDone(done) : h,
    ];
    cache.update<List<Homework>>(CacheKeys.homework, patch);
    cache.update<List<Homework>>(CacheKeys.allHomework, patch);
    cache.update<CourseDetails>(
      CacheKeys.course(courseId),
      (d) => d.withHistory([
        for (final e in d.history)
          e.id == entryId ? e.withHomeworkDone(done) : e,
      ]),
    );
    return _json(200, {'done': done});
  }

  /// Starts a sync of all data and answers right away; the web UI follows
  /// the progress via /api/events or /api/sync.
  Response _refresh(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final s = sync;
    if (s == null) {
      cache.clear();
      return Response(204);
    }
    s.refreshNow().ignore();
    return _json(202, {'refreshing': true});
  }

  Response _syncStatus(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final s = sync;
    if (s == null) return _json(200, {'enabled': false, 'running': false});
    final c = s.config;
    return _json(200, {
      'enabled': c.enabled,
      'running': s.running,
      'activeHours': [c.activeFromHour, c.activeToHour],
      'tasks': {
        for (final t in s.tasks)
          t.name: {
            ...s.status(t).toJson(),
            'intervalMinutes': c.intervalFor(t).inMinutes,
            'nextRun': c.enabled
                ? s.nextRun(t).toUtc().toIso8601String()
                : null,
          },
      },
    });
  }

  // --- setup and server settings ------------------------------------------------

  /// Setup token (setup mode) or login (afterwards).
  bool _settingsAuthorized(Request request) {
    final c = control;
    if (c == null) return false;
    if (c.setupRequired) {
      return c.checkSetupToken(request.headers['x-setup-token']);
    }
    return _authorized(request);
  }

  Response _settingsDenied() => control?.setupRequired ?? false
      ? _error(403, 'setup_token_invalid', 'Missing or wrong setup token')
      : _error(401, 'unauthorized', 'Login required');

  Response _setup(Request request) =>
      _json(200, {'setupRequired': control?.setupRequired ?? false});

  Response _getServerSettings(Request request) {
    if (control == null) return _error(404, 'not_found', 'Not available');
    if (!_settingsAuthorized(request)) return _settingsDenied();
    return _json(200, control!.describeSettings());
  }

  Future<Response> _putServerSettings(Request request) async {
    final c = control;
    if (c == null) return _error(404, 'not_found', 'Not available');
    if (!_settingsAuthorized(request)) return _settingsDenied();
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    final Map<String, String> changes;
    final String? appPassword, currentPassword;
    try {
      final body = jsonDecode(await _readLimited(request, _maxSettingsBody));
      if (body is! Map) throw const FormatException('Expected an object');
      final settings = body['settings'] ?? const {};
      if (settings is! Map) {
        throw const FormatException('"settings" must be an object');
      }
      changes = {};
      for (final MapEntry(:key, :value) in settings.entries) {
        if (key is! String ||
            !ServerSettingKeys.editable.contains(key) ||
            key == 'APP_PASSWORD_HASH') {
          throw FormatException('Unknown setting: $key');
        }
        if (value is! String && value is! num && value is! bool) {
          throw FormatException('Invalid value for $key');
        }
        changes[key] = '$value'.trim();
      }
      appPassword = body['appPassword'] as String?;
      currentPassword = body['currentPassword'] as String?;
    } on FormatException catch (e) {
      return _error(400, 'bad_request', e.message);
    } on TypeError {
      return _error(400, 'bad_request', 'Invalid request');
    }

    final wasSetup = c.setupRequired;
    var passwordChanged = false;
    if (appPassword != null && appPassword.isNotEmpty) {
      if (appPassword.length < 8) {
        return _error(
          400,
          'invalid_settings',
          'Password too short',
          extra: {
            'problems': ['APP_PASSWORD must have at least 8 characters'],
          },
        );
      }
      if (!wasSetup) {
        final hash = passwordHash;
        final current = currentPassword ?? '';
        final ok = await Isolate.run(
          () => PasswordHasher.verify(current, hash),
        );
        if (!ok) {
          return _error(403, 'invalid_password', 'Current password is wrong');
        }
      }
      final plain = appPassword;
      final iterations = passwordIterations ?? PasswordHasher.defaultIterations;
      changes['APP_PASSWORD_HASH'] = await Isolate.run(
        () => PasswordHasher.hash(plain, iterations: iterations),
      );
      passwordChanged = true;
    }

    final ApplyResult result;
    try {
      result = await c.apply(changes);
    } on ConfigException catch (e) {
      return _error(
        400,
        'invalid_settings',
        'Invalid settings',
        extra: {'problems': e.problems},
      );
    } on SphAuthException catch (e) {
      return _error(400, 'sph_login_failed', e.message);
    } on SphException catch (e) {
      return _sphError(e);
    } on CasedaException catch (e) {
      return e.isAuth
          ? _error(400, 'meals_login_failed', e.message)
          : _error(503, 'meals_unavailable', e.message);
    } on UntisException catch (e) {
      return e.isAuth
          ? _error(400, 'untis_login_failed', e.message)
          : _error(503, 'untis_unavailable', e.message);
    }

    final headers = <String, String>{};
    if (wasSetup && !c.setupRequired) {
      // Setup done: logged in right away.
      headers['set-cookie'] = _cookie(sessions.create(), sessions.ttl);
    } else if (passwordChanged) {
      sessions.revokeAllExcept(_sessionToken(request));
    }
    return _json(200, {
      'saved': true,
      'setupRequired': c.setupRequired,
      'restartRequired': result.restartRequired,
      'accountChanged': result.accountChanged,
    }, headers: headers);
  }

  final _testLogins = <DateTime>[];

  /// Tests a Caseda login (school meals) without storing it.
  Future<Response> _testCaseda(Request request) async {
    final c = control;
    if (c == null) return _error(404, 'not_found', 'Not available');
    if (!_settingsAuthorized(request)) return _settingsDenied();
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    final now = _now();
    _testLogins.removeWhere(
      (t) => now.difference(t) > const Duration(minutes: 5),
    );
    if (_testLogins.length >= 5) {
      return _error(
        429,
        'too_many_attempts',
        'Too many test logins, try again later',
        headers: {'retry-after': '300'},
      );
    }
    final String username;
    final String? password;
    final String? url;
    try {
      final body = jsonDecode(await _readLimited(request, _maxLoginBody));
      if (body is! Map) throw const FormatException();
      username = (body['username'] as String).trim();
      password = body['password'] as String?;
      url = body['url'] as String?;
      if (username.isEmpty) throw const FormatException();
    } on Object {
      return _error(400, 'bad_request', 'Expected {"username", "password"?}');
    }
    _testLogins.add(now);
    try {
      await c.testCasedaLogin(
        username: username,
        password: password == null || password.isEmpty ? null : password,
        url: url == null || url.trim().isEmpty ? null : url.trim(),
      );
      return _json(200, {'ok': true});
    } on CasedaException catch (e) {
      return e.isAuth
          ? _error(400, 'meals_login_failed', e.message)
          : _error(503, 'meals_unavailable', e.message);
    } on ArgumentError catch (e) {
      return _error(400, 'bad_request', '${e.message}');
    }
  }

  /// Tests a WebUntis login (second source for substitutions) without
  /// storing it; answers with the class of the account.
  Future<Response> _testUntis(Request request) async {
    final c = control;
    if (c == null) return _error(404, 'not_found', 'Not available');
    if (!_settingsAuthorized(request)) return _settingsDenied();
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    final now = _now();
    _testLogins.removeWhere(
      (t) => now.difference(t) > const Duration(minutes: 5),
    );
    if (_testLogins.length >= 5) {
      return _error(
        429,
        'too_many_attempts',
        'Too many test logins, try again later',
        headers: {'retry-after': '300'},
      );
    }
    final String server;
    final String username;
    final String? password;
    final String? school;
    try {
      final body = jsonDecode(await _readLimited(request, _maxLoginBody));
      if (body is! Map) throw const FormatException();
      server = (body['server'] as String).trim();
      username = (body['username'] as String).trim();
      password = body['password'] as String?;
      school = body['school'] as String?;
      if (server.isEmpty || username.isEmpty) throw const FormatException();
    } on Object {
      return _error(
        400,
        'bad_request',
        'Expected {"server", "username", "password"?, "school"?}',
      );
    }
    _testLogins.add(now);
    try {
      final className = await c.testUntisLogin(
        server: server,
        username: username,
        password: password == null || password.isEmpty ? null : password,
        school: school == null || school.trim().isEmpty ? null : school.trim(),
      );
      return _json(200, {'ok': true, 'className': className});
    } on UntisException catch (e) {
      return e.isAuth
          ? _error(400, 'untis_login_failed', e.message)
          : _error(503, 'untis_unavailable', e.message);
    } on ArgumentError catch (e) {
      return _error(400, 'bad_request', '${e.message}');
    }
  }

  Future<Response> _testLogin(Request request) async {
    final c = control;
    if (c == null) return _error(404, 'not_found', 'Not available');
    if (!_settingsAuthorized(request)) return _settingsDenied();
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    // Protects the Schulportal account against lockout by repeated tries.
    final now = _now();
    _testLogins.removeWhere(
      (t) => now.difference(t) > const Duration(minutes: 5),
    );
    if (_testLogins.length >= 5) {
      return _error(
        429,
        'too_many_attempts',
        'Too many test logins, try again later',
        headers: {'retry-after': '300'},
      );
    }
    final int schoolId;
    final String username;
    final String? password;
    try {
      final body = jsonDecode(await _readLimited(request, _maxLoginBody));
      if (body is! Map) throw const FormatException();
      schoolId = int.parse('${body['schoolId']}');
      username = (body['username'] as String).trim();
      password = body['password'] as String?;
      if (username.isEmpty) throw const FormatException();
    } on Object {
      return _error(
        400,
        'bad_request',
        'Expected {"schoolId", "username", "password"?}',
      );
    }
    _testLogins.add(now);
    try {
      await c.testLogin(
        schoolId: schoolId,
        username: username,
        password: password == null || password.isEmpty ? null : password,
      );
      return _json(200, {'ok': true});
    } on SphAuthException catch (e) {
      return _error(400, 'sph_login_failed', e.message);
    } on SphException catch (e) {
      return _sphError(e);
    }
  }

  Future<Response> _schools(Request request) async {
    final c = control;
    if (c == null) return _error(404, 'not_found', 'Not available');
    if (!_settingsAuthorized(request)) return _settingsDenied();
    final q = request.url.queryParameters['q'] ?? '';
    try {
      final schools = await c.searchSchools(q);
      return _json(200, [for (final s in schools) s.toJson()]);
    } on Object {
      return _error(
        503,
        'sph_unavailable',
        'School list of Schulportal not reachable',
      );
    }
  }

  // --- app updates ---------------------------------------------------------------

  Response _updateStatus(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final u = update;
    if (u == null) return _json(200, {'mode': 'manual', 'available': false});
    return _json(200, u.status());
  }

  Future<Response> _updateCheck(Request request) async {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final u = update;
    if (u == null) return _error(404, 'not_found', 'Not available');
    await u.check();
    return _json(200, u.status());
  }

  Response _updateInstall(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final u = update;
    if (u == null || !u.canInstall) {
      return _error(409, 'no_update', 'No update can be installed');
    }
    u.install();
    return _json(202, u.status());
  }

  // --- live updates (Server-Sent Events) -----------------------------------------

  final _eventStreams = <StreamController<List<int>>>{};

  /// Pushes cache updates and sync start/end to the web UI.
  Response _events(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    if (_eventStreams.length >= _maxEventStreams) {
      return _error(503, 'too_many_streams', 'Too many open event streams');
    }
    final token = _sessionToken(request);
    final subscriptions = <StreamSubscription<Object?>>[];
    Timer? ping;
    late final StreamController<List<int>> controller;

    void write(String text) {
      if (!controller.isClosed) controller.add(utf8.encode(text));
    }

    void send(String event, Object data) =>
        write('event: $event\ndata: ${jsonEncode(data)}\n\n');

    void cleanup() {
      ping?.cancel();
      for (final s in subscriptions) {
        s.cancel();
      }
      subscriptions.clear();
      _eventStreams.remove(controller);
    }

    controller = StreamController<List<int>>(
      onListen: () {
        // Reconnect delay for the browser's EventSource.
        write('retry: 5000\n\n');
        send('sync', {'running': sync?.running ?? false});
        subscriptions.add(
          cache.updates.listen(
            (u) => send('update', {
              'key': u.key,
              'fetchedAt': u.fetchedAt.toUtc().toIso8601String(),
            }),
          ),
        );
        subscriptions.add(
          _syncStates.stream.listen((r) => send('sync', {'running': r})),
        );
        ping = Timer.periodic(_eventPing, (_) {
          if (!sessions.validate(token)) {
            cleanup();
            controller.close();
            return;
          }
          write(': ping\n\n');
        });
      },
      onCancel: cleanup,
    );
    _eventStreams.add(controller);
    return Response.ok(
      controller.stream,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        // Keeps HttpServer.autoCompress from buffering the stream.
        'content-encoding': 'identity',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  /// Ends open event streams (on shutdown; they would keep the server open).
  /// Does not wait for slow clients to receive the end of the stream.
  Future<void> close() async {
    for (final c in _eventStreams.toList()) {
      _eventStreams.remove(c);
      c.close().ignore();
    }
    await _syncSubscription?.cancel();
  }

  // --- settings ----------------------------------------------------------------

  Response _getSettings(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    return _json(200, settings.load().toJson());
  }

  Future<Response> _putSettings(Request request) async {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    if (!_isJson(request)) {
      return _error(415, 'unsupported_media_type', 'Use application/json');
    }
    final AppSettings parsed;
    try {
      // Fields not sent keep their stored value.
      parsed = AppSettings.fromJson(
        jsonDecode(await _readLimited(request, _maxSettingsBody)),
        base: settings.load(),
      );
    } on FormatException catch (e) {
      return _error(400, 'bad_request', e.message);
    }
    settings.save(parsed);
    return _json(200, parsed.toJson());
  }

  // --- notifications -----------------------------------------------------------

  Response _notifications(Request request) {
    if (!_authorized(request)) {
      return _error(401, 'unauthorized', 'Login required');
    }
    final p = poller;
    if (p == null) return _json(200, {'enabled': false});
    final c = p.config;
    final sc = p.sync.config;
    return _json(200, {
      'enabled': true,
      'target': p.notifier.description,
      'kinds': [for (final k in c.kinds) k.name],
      'sync': sc.enabled,
      'intervalMinutes': sc.interval.inMinutes,
      'gradesIntervalMinutes': sc.detailsInterval.inMinutes,
      'activeHours': [sc.activeFromHour, sc.activeToHour],
      'includeGradeValues': c.includeGradeValues,
      'status': {
        for (final k in c.kinds)
          k.name: {
            ...p.status(k).toJson(),
            'nextRun': sc.enabled
                ? p.nextRun(k).toUtc().toIso8601String()
                : null,
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
    if (webDir == null && (embeddedWeb?.isEmpty ?? true) ||
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
    if (webDir == null) {
      return embeddedWeb!.serve(request) ??
          _error(404, 'not_found', 'No such file');
    }
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
