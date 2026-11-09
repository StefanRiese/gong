import 'dart:async';

import '../api/api.dart' show CacheTtl;
import '../api/cache.dart';
import '../sph/errors.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import 'change_detector.dart';
import 'notifier.dart';

/// What to watch.
enum WatchKind {
  substitutions,
  homework,
  grades;

  static WatchKind? parse(String s) {
    for (final k in values) {
      if (k.name == s.trim().toLowerCase()) return k;
    }
    return null;
  }
}

class PollerConfig {
  final Set<WatchKind> kinds;
  final Duration interval;
  final Duration gradesInterval;

  /// Polling only between these hours (local time), e.g. 6 and 22.
  final int activeFromHour;
  final int activeToHour;
  final bool includeGradeValues;

  const PollerConfig({
    this.kinds = const {
      WatchKind.substitutions,
      WatchKind.homework,
      WatchKind.grades,
    },
    this.interval = const Duration(minutes: 20),
    this.gradesInterval = const Duration(hours: 2),
    this.activeFromHour = 6,
    this.activeToHour = 22,
    this.includeGradeValues = false,
  });

  Duration intervalFor(WatchKind kind) =>
      kind == WatchKind.grades ? gradesInterval : interval;

  bool isActive(DateTime t) => activeFromHour <= activeToHour
      ? t.hour >= activeFromHour && t.hour < activeToHour
      : t.hour >= activeFromHour || t.hour < activeToHour;
}

/// Status of one watched kind (persisted in the database).
class PollStatus {
  final DateTime? lastRun;
  final DateTime? lastSuccess;
  final String? lastError;
  final int sent;
  final bool baseline;

  const PollStatus({
    this.lastRun,
    this.lastSuccess,
    this.lastError,
    this.sent = 0,
    this.baseline = false,
  });

  factory PollStatus.fromJson(Map<String, Object?>? j) {
    if (j == null) return const PollStatus();
    DateTime? d(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return PollStatus(
      lastRun: d(j['lastRun']),
      lastSuccess: d(j['lastSuccess']),
      lastError: j['lastError'] as String?,
      sent: (j['sent'] as num?)?.toInt() ?? 0,
      baseline: j['baseline'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'lastRun': lastRun?.toUtc().toIso8601String(),
    'lastSuccess': lastSuccess?.toUtc().toIso8601String(),
    'lastError': lastError,
    'sent': sent,
    'baseline': baseline,
  };
}

/// Periodically loads data, detects new items and sends notifications.
///
/// - the first successful run per kind only records the current state
/// - an item is marked as seen only after its notification was sent, so
///   failed deliveries are retried on the next run
/// - loads go through [ResponseCache] (refresh), which keeps the web UI fast
class Poller {
  final SphService service;
  final ResponseCache cache;
  final AppDatabase db;
  final Notifier notifier;
  final PollerConfig config;
  final void Function(String message) log;
  final DateTime Function() _now;

  Timer? _timer;
  Future<void>? _running;

  /// Forgotten fingerprints are pruned after this time.
  static const _retention = Duration(days: 90);

  Poller({
    required this.service,
    required this.cache,
    required this.db,
    required this.notifier,
    this.config = const PollerConfig(),
    void Function(String message)? log,
    DateTime Function()? now,
  }) : log = log ?? ((_) {}),
       _now = now ?? DateTime.now;

  /// Starts checking once a minute which kinds are due.
  void start() {
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    Timer(const Duration(seconds: 20), _tick);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _running;
  }

  PollStatus status(WatchKind kind) =>
      PollStatus.fromJson(db.getJson('poll:${kind.name}'));

  /// Next time [kind] is due (ignoring active hours). Never run → due
  /// immediately (a fixed past time, so it is due regardless of clock ticks).
  DateTime nextRun(WatchKind kind) {
    final last = status(kind).lastRun;
    return last == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : last.add(config.intervalFor(kind));
  }

  /// Kinds that are due at [now] (respecting active hours).
  List<WatchKind> dueKinds(DateTime now) => !config.isActive(now)
      ? const []
      : [
          for (final k in config.kinds)
            if (!nextRun(k).isAfter(now)) k,
        ];

  void _tick() {
    if (_running != null) return;
    final due = dueKinds(_now());
    if (due.isEmpty) return;
    _running = _guard(_runKinds(due));
  }

  /// Never lets an error escape from the timer (it would end the program).
  Future<void> _guard(Future<int> f) => f
      .then<void>(
        (_) {},
        onError: (Object e, StackTrace st) => log('poller error: $e\n$st'),
      )
      .whenComplete(() => _running = null);

  /// Runs the given kinds now (all configured kinds by default), regardless
  /// of schedule and active hours. Returns the number of notifications sent.
  Future<int> runNow([Iterable<WatchKind>? kinds]) async {
    while (_running != null) {
      await _running;
    }
    final f = _runKinds((kinds ?? config.kinds).toList());
    _running = _guard(f);
    return f;
  }

  Future<int> _runKinds(List<WatchKind> kinds) async {
    var total = 0;
    for (final k in kinds) {
      total += await _run(k);
    }
    return total;
  }

  Future<int> _run(WatchKind kind) async {
    final started = _now();
    final previous = status(kind);
    Detection detection;
    try {
      detection = await _detect(kind, db.seen(kind.name));
    } catch (e) {
      final message = _describe(e);
      log('poll ${kind.name}: ${e is SphException ? e.message : e}');
      _save(
        kind,
        PollStatus(
          lastRun: started,
          lastSuccess: previous.lastSuccess,
          lastError: message,
          sent: previous.sent,
          baseline: previous.baseline,
        ),
      );
      return 0;
    }

    var sent = 0;
    String? error;
    if (!previous.baseline) {
      db.markSeen(kind.name, detection.current, started);
      log(
        'poll ${kind.name}: baseline recorded '
        '(${detection.current.length} items, no notifications)',
      );
    } else {
      for (final p in detection.pending) {
        try {
          await notifier.send(p.notification);
          db.markSeen(kind.name, p.fingerprints, started);
          sent++;
          log('notify ${kind.name}: ${p.notification.title}');
        } on NotifyException catch (e) {
          error = 'Senden fehlgeschlagen: ${e.message}';
          log('notify ${kind.name} failed: ${e.message}');
          break; // retry the rest on the next run
        }
      }
      // Items that need no notification (e.g. homework already done).
      final pendingFps = {for (final p in detection.pending) ...p.fingerprints};
      db.markSeen(kind.name, detection.current.difference(pendingFps), started);
    }
    db.pruneSeen(kind.name, detection.current, started.subtract(_retention));

    _save(
      kind,
      PollStatus(
        lastRun: started,
        lastSuccess: started,
        lastError: error,
        sent: previous.sent + sent,
        baseline: true,
      ),
    );
    return sent;
  }

  /// Keeps the full homework list (one request per course) fresh for the web
  /// UI: reloaded when older than [allHomeworkRefresh]. Failures are ignored
  /// here; the web UI then loads it on demand.
  Future<void> _warmAllHomework() async {
    final age = cache.fetchedAt('homework:all');
    if (age != null && _now().difference(age) < allHomeworkRefresh) return;
    try {
      await cache.get(
        'homework:all',
        CacheTtl.allHomework,
        service.allHomework,
        refresh: true,
      );
    } catch (e) {
      log('warm homework list: $e');
    }
  }

  /// Minimum age before the poller reloads the full homework list.
  static const allHomeworkRefresh = Duration(minutes: 25);

  /// Loads fresh data; stale cache data (portal down) counts as a failure.
  Future<T> _load<T>(
    String key,
    Duration ttl,
    Future<T> Function() load,
  ) async {
    final r = await cache.get<T>(key, ttl, load, refresh: true);
    if (r.stale) {
      throw const SphUnavailableException(
        'Schulportal not reachable (only cached data available)',
      );
    }
    return r.value;
  }

  Future<Detection> _detect(WatchKind kind, Set<String> seen) async {
    switch (kind) {
      case WatchKind.substitutions:
        final days = await _load(
          'substitutions',
          CacheTtl.substitutions,
          service.substitutions,
        );
        return detectSubstitutions(days, seen, _now());
      case WatchKind.homework:
        final items = await _load(
          'homework',
          CacheTtl.homework,
          service.homework,
        );
        await _warmAllHomework();
        return detectHomework(items, seen);
      case WatchKind.grades:
        final courses = await _load('grades', CacheTtl.grades, service.grades);
        return detectGrades(
          courses,
          seen,
          includeValues: config.includeGradeValues,
        );
    }
  }

  /// Short German description for the status page.
  static String _describe(Object e) => switch (e) {
    SphUnavailableException() => 'Schulportal nicht erreichbar',
    SphAuthException() => 'Anmeldung beim Schulportal fehlgeschlagen',
    SphFeatureDisabledException() => 'Bereich nicht freigeschaltet',
    SphDataException() => 'Unerwartete Daten vom Schulportal',
    _ => 'Unerwarteter Fehler',
  };

  void _save(WatchKind kind, PollStatus s) =>
      db.setJson('poll:${kind.name}', s.toJson());
}
