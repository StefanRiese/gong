import 'dart:async';

import 'package:liblanis/easy_client.dart' as lanis;

import '../models/models.dart';
import 'errors.dart';
import 'mappers.dart';
import 'sph_gateway.dart';

/// Access to Schulportal Hessen for one account.
///
/// Session policy:
/// - logs in lazily on the first request; concurrent requests share one login
/// - if a request fails, logs in again once and retries (covers expired
///   sessions); auth errors are never retried
/// - after a failed login due to credentials, no new login is attempted
///   before [authRetryDelay] has passed (protects against account lockout)
/// - logs out after [idleTimeout] without requests, instead of pinging the
///   portal permanently
class SphService {
  final SphGateway _gateway;
  final Duration idleTimeout;
  final Duration authRetryDelay;
  final DateTime Function() _now;

  Future<void>? _login;
  int _inFlight = 0;
  Timer? _idleTimer;
  SphAuthException? _authFailure;
  DateTime? _authBlockedUntil;
  Map<String, lanis.Lesson>? _lessonIndex;
  bool _disposed = false;

  SphService(
    this._gateway, {
    this.idleTimeout = const Duration(minutes: 5),
    this.authRetryDelay = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  bool get isLoggedIn => _gateway.isLoggedIn;

  /// Account info and enabled features. Logs in if needed.
  Future<AccountInfo> account() => _run(null, () async {
    return AccountInfo(
      schoolId: _gateway.schoolId,
      username: _gateway.username,
      accountType: _gateway.accountType,
      features: _features(),
    );
  });

  Future<Timetable> timetable() => _run(
    SphFeature.timetable,
    () async => mapTimetable(await _gateway.timetable()),
  );

  Future<List<SubstitutionDay>> substitutions() => _run(
    SphFeature.substitutions,
    () async => mapSubstitutions(await _gateway.substitutions()),
  );

  /// Calendar entries between [from] and [to] (defaults: today … +60 days).
  Future<List<CalendarEntry>> calendar({DateTime? from, DateTime? to}) {
    final today = _today();
    final start = from ?? today;
    final end = to ?? today.add(const Duration(days: 60));
    if (end.isBefore(start)) {
      throw ArgumentError('"to" must not be before "from"');
    }
    return _run(
      SphFeature.calendar,
      () async => mapCalendar(await _gateway.calendar(start, end)),
    );
  }

  Future<List<Course>> courses() => _run(
    SphFeature.lessons,
    () async => [for (final l in await _loadLessons()) mapCourse(l)],
  );

  /// Current homework from the "Mein Unterricht" overview (one request).
  Future<List<Homework>> homework() => _run(
    SphFeature.lessons,
    () async => mapCurrentHomework(await _loadLessons()),
  );

  /// Full course view: lesson history incl. homework, grades, exams.
  Future<CourseDetails> courseDetails(String courseId) =>
      _run(SphFeature.lessons, () async {
        final lesson = await _findLesson(courseId);
        return mapCourseDetails(await _gateway.lessonDetails(lesson.courseURL));
      });

  /// Grades and exams of all courses. Needs one request per course.
  Future<List<CourseGrades>> grades() => _run(SphFeature.lessons, () async {
    final lessons = await _loadLessons();
    final result = <CourseGrades>[];
    for (final l in lessons) {
      final details = await _gateway.lessonDetails(l.courseURL);
      result.add(mapCourseGrades(mapCourse(l), details));
    }
    return result;
  });

  /// Logs out now (e.g. on shutdown). The next request logs in again.
  Future<void> logout() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _lessonIndex = null;
    if (_gateway.isLoggedIn) {
      try {
        await _gateway.logout();
      } catch (_) {
        // Best effort; the portal session expires on its own.
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await logout();
    await _gateway.dispose();
  }

  // ---------------------------------------------------------------------------

  Set<SphFeature> _features() {
    final applets = _gateway.enabledApplets;
    return {
      for (final f in SphFeature.values)
        if (applets.contains(f.applet)) f,
    };
  }

  DateTime _today() {
    final n = _now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<lanis.Lessons> _loadLessons() async {
    final lessons = await _gateway.lessons();
    _lessonIndex = {for (final l in lessons) l.courseID: l};
    return lessons;
  }

  Future<lanis.Lesson> _findLesson(String courseId) async {
    final known = _lessonIndex?[courseId];
    if (known != null) return known;
    await _loadLessons();
    final lesson = _lessonIndex![courseId];
    if (lesson == null) {
      throw SphNotFoundException('Unknown course "$courseId"');
    }
    return lesson;
  }

  /// Runs [action] with a valid session; re-logs in and retries once on
  /// failure. Checks that [feature] is enabled for the account.
  Future<T> _run<T>(SphFeature? feature, Future<T> Function() action) async {
    if (_disposed) throw StateError('SphService has been disposed');
    _inFlight++;
    _idleTimer?.cancel();
    try {
      await _ensureLoggedIn();
      _checkFeature(feature);
      try {
        return await action();
      } on SphException catch (e) {
        if (e is! SphDataException) rethrow;
        // fall through to retry
      } catch (_) {
        // fall through to retry
      }
      await _relogin();
      _checkFeature(feature);
      try {
        return await action();
      } on SphException {
        rethrow;
      } catch (e) {
        throw _mapError(e);
      }
    } finally {
      _inFlight--;
      _scheduleIdleLogout();
    }
  }

  void _checkFeature(SphFeature? feature) {
    if (feature == null) return;
    if (!_gateway.enabledApplets.contains(feature.applet)) {
      throw SphFeatureDisabledException(
        '${feature.name} (${feature.applet}) is not enabled for this account',
      );
    }
  }

  Future<void> _ensureLoggedIn() {
    if (_gateway.isLoggedIn && _login == null) return Future.value();
    return _startLogin();
  }

  Future<void> _relogin() {
    _lessonIndex = null;
    return _startLogin();
  }

  /// Single-flight login: concurrent callers share one attempt. The shared
  /// future is cleared only after it completes, so a login that fails
  /// synchronously cannot leave a stale failed future behind.
  Future<void> _startLogin() {
    final running = _login;
    if (running != null) return running;
    final attempt = _doLogin();
    _login = attempt;
    attempt.whenComplete(() {
      if (identical(_login, attempt)) _login = null;
    }).ignore();
    return attempt;
  }

  Future<void> _doLogin() async {
    final blockedUntil = _authBlockedUntil;
    if (blockedUntil != null && _now().isBefore(blockedUntil)) {
      throw _authFailure!;
    }
    try {
      await _gateway.login();
      _authFailure = null;
      _authBlockedUntil = null;
    } catch (e) {
      final mapped = _mapError(e);
      if (mapped is SphAuthException) {
        _authBlockedUntil = mapped.retryAfter ?? _now().add(authRetryDelay);
        _authFailure = SphAuthException(
          mapped.message,
          retryAfter: _authBlockedUntil,
          cause: mapped.cause,
        );
        throw _authFailure!;
      }
      throw mapped;
    }
  }

  void _scheduleIdleLogout() {
    if (_inFlight > 0 || _disposed) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      if (_inFlight == 0 && _login == null) unawaited(logout());
    });
  }

  SphException _mapError(Object e) {
    return switch (e) {
      SphException() => e,
      lanis.WrongCredentialsException() => SphAuthException(
        'Wrong username or password',
        cause: e,
      ),
      lanis.CredentialsIncompleteException() => SphAuthException(
        'Username or password missing',
        cause: e,
      ),
      lanis.LoginTimeoutException() => SphAuthException(
        'Portal blocks logins for ${e.time} after failed attempts',
        cause: e,
      ),
      lanis.LanisDownException() => SphUnavailableException(
        'Schulportal is down or under maintenance',
        e,
      ),
      lanis.NoConnectionException() || lanis.NetworkException() =>
        SphUnavailableException('Schulportal is not reachable', e),
      _ => SphDataException('Unexpected response from Schulportal: $e', e),
    };
  }
}
