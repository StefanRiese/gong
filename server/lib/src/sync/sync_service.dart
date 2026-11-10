import 'dart:async';
import 'dart:math';

import '../api/cache.dart';
import '../caseda/caseda.dart';
import '../models/models.dart';
import '../sph/errors.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import 'cache_keys.dart';

/// Kinds of data kept in sync with Schulportal.
enum SyncTask {
  account,
  timetable,
  substitutions,
  homework,
  calendar,

  /// All course pages: course details, grades, full homework list, courses.
  lessons,

  /// School meals (Caseda): balance and own orders; only when set up.
  meals,
}

class SyncConfig {
  /// Background sync on (otherwise only on demand / manual refresh).
  final bool enabled;

  /// Substitutions and current homework.
  final Duration interval;

  /// Course pages (grades, all homework, course details): one request per
  /// course, so less often.
  final Duration detailsInterval;
  final Duration calendarInterval;

  /// Account and timetable.
  final Duration slowInterval;

  /// School meals: balance and orders.
  final Duration mealsInterval;

  /// Sync only between these hours (local time), e.g. 6 and 22.
  final int activeFromHour;
  final int activeToHour;

  /// Pause between two tasks (spreads the requests to the portal).
  final Duration pause;

  const SyncConfig({
    this.enabled = true,
    this.interval = const Duration(minutes: 15),
    this.detailsInterval = const Duration(hours: 2),
    this.calendarInterval = const Duration(hours: 1),
    this.slowInterval = const Duration(hours: 6),
    this.mealsInterval = const Duration(hours: 2),
    this.activeFromHour = 6,
    this.activeToHour = 22,
    this.pause = const Duration(seconds: 2),
  });

  Duration intervalFor(SyncTask task) => switch (task) {
    SyncTask.substitutions || SyncTask.homework => interval,
    SyncTask.lessons => detailsInterval,
    SyncTask.calendar => calendarInterval,
    SyncTask.account || SyncTask.timetable => slowInterval,
    SyncTask.meals => mealsInterval,
  };

  bool isActive(DateTime t) => activeFromHour <= activeToHour
      ? t.hour >= activeFromHour && t.hour < activeToHour
      : t.hour >= activeFromHour || t.hour < activeToHour;
}

/// Status of one sync task (persisted in the database).
class SyncStatus {
  final DateTime? lastRun;
  final DateTime? lastSuccess;
  final String? lastError;

  /// Failed runs in a row (for the retry backoff).
  final int failures;

  const SyncStatus({
    this.lastRun,
    this.lastSuccess,
    this.lastError,
    this.failures = 0,
  });

  factory SyncStatus.fromJson(Map<String, Object?>? j) {
    if (j == null) return const SyncStatus();
    DateTime? d(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return SyncStatus(
      lastRun: d(j['lastRun']),
      lastSuccess: d(j['lastSuccess']),
      lastError: j['lastError'] as String?,
      failures: (j['failures'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
    'lastRun': lastRun?.toUtc().toIso8601String(),
    'lastSuccess': lastSuccess?.toUtc().toIso8601String(),
    'lastError': lastError,
    'failures': failures,
  };
}

/// Called with the fresh data of a task (e.g. change detection).
typedef SyncListener = Future<void> Function(SyncTask task, Object? data);

/// Called when a task failed.
typedef SyncFailureListener = void Function(SyncTask task, Object error);

/// Keeps the cached portal data fresh in the background, so the web UI can
/// answer from the cache right away.
///
/// - every task runs at its own interval during active hours, one at a time
///   with a short pause in between
/// - failures are retried sooner (5, 10, 20 … min, at most the interval)
/// - [refreshNow] runs tasks immediately (manual refresh, notification check)
/// - listeners get the fresh data after each successful task
class SyncService {
  final SphService service;
  final ResponseCache cache;
  final AppDatabase db;
  final SyncConfig config;
  final void Function(String message) log;
  final DateTime Function() _now;

  final _listeners = <SyncListener>[];
  final _failureListeners = <SyncFailureListener>[];
  final _runningChanges = StreamController<bool>.broadcast(sync: true);
  final _random = Random();

  Timer? _timer;
  Future<void>? _running;
  bool _stopped = false;

  static const _firstRetry = Duration(minutes: 5);

  /// Extra time an entry counts as fresh beyond its sync interval, so web UI
  /// requests do not trigger loads shortly before the sync would.
  static const _grace = Duration(minutes: 5);

  /// School meals (Caseda); null = not set up, the task is skipped.
  final MealsGateway? meals;

  SyncService({
    required this.service,
    required this.cache,
    required this.db,
    this.meals,
    this.config = const SyncConfig(),
    void Function(String message)? log,
    DateTime Function()? now,
  }) : log = log ?? ((_) {}),
       _now = now ?? DateTime.now;

  void addListener(SyncListener l) => _listeners.add(l);
  void addFailureListener(SyncFailureListener l) => _failureListeners.add(l);

  /// True while tasks run; changes are reported by [runningChanges].
  bool get running => _running != null;
  Stream<bool> get runningChanges => _runningChanges.stream;

  /// Starts the schedule (no-op if background sync is disabled).
  void start() {
    if (!config.enabled || _timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    Timer(const Duration(seconds: 5), _tick);
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _running;
    await _runningChanges.close();
  }

  SyncStatus status(SyncTask task) =>
      SyncStatus.fromJson(db.getJson('sync:${task.name}'));

  /// Next time [task] is due (ignoring active hours). Never run → due now.
  DateTime nextRun(SyncTask task) {
    final s = status(task);
    final last = s.lastRun;
    if (last == null) return DateTime.fromMillisecondsSinceEpoch(0);
    final interval = config.intervalFor(task);
    if (s.failures == 0) return last.add(interval);
    final retry = _firstRetry * pow(2, min(s.failures - 1, 6)).toInt();
    return last.add(retry < interval ? retry : interval);
  }

  /// Tasks due at [now] (respecting active hours), in priority order.
  List<SyncTask> dueTasks(DateTime now) => !config.isActive(now)
      ? const []
      : [
          for (final t in tasks)
            if (!nextRun(t).isAfter(now)) t,
        ];

  /// Tasks of this installation (without meals if Caseda is not set up).
  List<SyncTask> get tasks => [
    for (final t in SyncTask.values)
      if (t != SyncTask.meals || meals != null) t,
  ];

  /// How long a cached entry counts as fresh for the web UI while the
  /// background sync keeps it up to date; null if the sync does not cover
  /// [key] right now (disabled, outside active hours).
  Duration? freshFor(String key) {
    if (!config.enabled || !config.isActive(_now())) return null;
    final task = taskFor(key);
    return task == null ? null : config.intervalFor(task) + _grace;
  }

  /// The task that refreshes cache [key].
  static SyncTask? taskFor(String key) {
    if (key.startsWith('course:')) return SyncTask.lessons;
    if (key.startsWith('calendar:')) return SyncTask.calendar;
    return switch (key) {
      CacheKeys.account => SyncTask.account,
      CacheKeys.timetable => SyncTask.timetable,
      CacheKeys.substitutions => SyncTask.substitutions,
      CacheKeys.homework => SyncTask.homework,
      CacheKeys.courses ||
      CacheKeys.grades ||
      CacheKeys.allHomework => SyncTask.lessons,
      CacheKeys.meals => SyncTask.meals,
      _ => null,
    };
  }

  /// Runs [tasks] (all by default) now, regardless of schedule and active
  /// hours; waits for a run in progress first.
  Future<void> refreshNow([Iterable<SyncTask>? tasks]) async {
    while (_running != null) {
      await _running;
    }
    await _runTasks((tasks ?? this.tasks).where(this.tasks.contains).toList());
  }

  void _tick() {
    if (_running != null || _stopped) return;
    final due = dueTasks(_now());
    if (due.isNotEmpty) _runTasks(due).ignore();
  }

  Future<void> _runTasks(List<SyncTask> tasks) {
    final run = () async {
      for (var i = 0; i < tasks.length && !_stopped; i++) {
        if (i > 0 && config.pause > Duration.zero) {
          final ms = config.pause.inMilliseconds;
          await Future<void>.delayed(
            Duration(milliseconds: ms + _random.nextInt(ms + 1)),
          );
        }
        await _run(tasks[i]);
      }
    }();
    final guarded = run
        .catchError((Object e, StackTrace st) => log('sync error: $e\n$st'))
        .whenComplete(() {
          _running = null;
          if (!_runningChanges.isClosed) _runningChanges.add(false);
        });
    _running = guarded;
    if (!_runningChanges.isClosed) _runningChanges.add(true);
    return guarded;
  }

  Future<void> _run(SyncTask task) async {
    final started = _now();
    final previous = status(task);
    Object? data;
    try {
      data = await _load(task);
    } on SphFeatureDisabledException {
      // Not enabled for this account: nothing to sync, no retries.
      _save(task, SyncStatus(lastRun: started, lastSuccess: started));
      return;
    } catch (e) {
      log('sync ${task.name}: ${e is SphException ? e.message : e}');
      _save(
        task,
        SyncStatus(
          lastRun: started,
          lastSuccess: previous.lastSuccess,
          lastError: describeError(e),
          failures: previous.failures + 1,
        ),
      );
      for (final l in _failureListeners) {
        l(task, e);
      }
      return;
    }
    _save(task, SyncStatus(lastRun: started, lastSuccess: started));
    for (final l in _listeners) {
      try {
        await l(task, data);
      } catch (e, st) {
        log('sync listener ${task.name}: $e\n$st');
      }
    }
  }

  Future<Object?> _load(SyncTask task) async {
    switch (task) {
      case SyncTask.account:
        return _fresh(CacheKeys.account, service.account);
      case SyncTask.timetable:
        return _fresh(CacheKeys.timetable, service.timetable);
      case SyncTask.substitutions:
        return _fresh(CacheKeys.substitutions, service.substitutions);
      case SyncTask.homework:
        final current = await _fresh(CacheKeys.homework, service.homework);
        _mergeIntoAllHomework(current);
        return current;
      case SyncTask.calendar:
        final (from, to) = CacheKeys.defaultCalendarRange(_now());
        return _fresh(
          CacheKeys.calendar(from, to),
          () => service.calendar(from: from, to: to),
        );
      case SyncTask.lessons:
        final snap = await service.lessonsSnapshot();
        cache.put(CacheKeys.courses, snap.courses);
        for (final MapEntry(:key, :value) in snap.details.entries) {
          cache.put(CacheKeys.course(key), value);
        }
        cache.put(CacheKeys.grades, snap.grades);
        cache.put(CacheKeys.allHomework, snap.allHomework);
        return snap;
      case SyncTask.meals:
        final snap = await meals!.load(_now());
        cache.put(CacheKeys.meals, snap);
        return snap;
    }
  }

  /// Loads [key] from the portal; stale cache data (portal down) counts as
  /// a failure.
  Future<T> _fresh<T>(String key, Future<T> Function() load) async {
    final r = await cache.get<T>(key, Duration.zero, load, refresh: true);
    if (r.stale) {
      throw const SphUnavailableException(
        'Schulportal not reachable (only cached data available)',
      );
    }
    return r.value;
  }

  /// New homework from the overview appears in the full list right away,
  /// not only after the next (slower) course page sync.
  void _mergeIntoAllHomework(List<Homework> current) {
    cache.update<List<Homework>>(CacheKeys.allHomework, (all) {
      final byEntry = {for (final h in all) '${h.courseId}/${h.entryId}': h};
      for (final h in current) {
        byEntry['${h.courseId}/${h.entryId}'] = h;
      }
      return sortHomework(byEntry.values);
    });
  }

  void _save(SyncTask task, SyncStatus s) =>
      db.setJson('sync:${task.name}', s.toJson());

  /// Short German description for status pages.
  static String describeError(Object e) => switch (e) {
    SphUnavailableException() => 'Schulportal nicht erreichbar',
    SphAuthException() => 'Anmeldung beim Schulportal fehlgeschlagen',
    SphFeatureDisabledException() => 'Bereich nicht freigeschaltet',
    SphDataException() => 'Unerwartete Daten vom Schulportal',
    CasedaException(isAuth: true) => 'Anmeldung bei Caseda fehlgeschlagen',
    CasedaException() => 'Caseda Schulmenü nicht erreichbar',
    _ => 'Unerwarteter Fehler',
  };
}
