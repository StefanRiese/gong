import 'dart:async';

import '../models/models.dart';
import '../sph/sph_service.dart';
import '../storage/app_database.dart';
import '../storage/settings_store.dart';
import '../sync/sync_service.dart';
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

/// What to notify about; schedule and active hours come from [SyncConfig].
class PollerConfig {
  final Set<WatchKind> kinds;
  final bool includeGradeValues;

  const PollerConfig({
    this.kinds = const {
      WatchKind.substitutions,
      WatchKind.homework,
      WatchKind.grades,
    },
    this.includeGradeValues = false,
  });
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

/// Detects new items in the data of the [SyncService] and sends
/// notifications.
///
/// - the first successful run per kind only records the current state
/// - an item is marked as seen only after its notification was sent, so
///   failed deliveries are retried on the next run
class Poller {
  final SyncService sync;
  final AppDatabase db;
  final Notifier notifier;
  final PollerConfig config;
  final void Function(String message) log;
  final DateTime Function() _now;

  /// Permanent filter of the substitution plan (own classes); null = all.
  final SubstitutionFilter Function()? substitutionFilter;

  int _sentTotal = 0;

  /// Forgotten fingerprints are pruned after this time.
  static const _retention = Duration(days: 90);

  Poller({
    required this.sync,
    required this.db,
    required this.notifier,
    this.config = const PollerConfig(),
    this.substitutionFilter,
    void Function(String message)? log,
    DateTime Function()? now,
  }) : log = log ?? ((_) {}),
       _now = now ?? DateTime.now {
    sync.addListener(_onData);
    sync.addFailureListener(_onFailure);
  }

  static SyncTask taskFor(WatchKind kind) => switch (kind) {
    WatchKind.substitutions => SyncTask.substitutions,
    WatchKind.homework => SyncTask.homework,
    WatchKind.grades => SyncTask.lessons,
  };

  static WatchKind? _kindFor(SyncTask task) => switch (task) {
    SyncTask.substitutions || SyncTask.untis => WatchKind.substitutions,
    SyncTask.homework => WatchKind.homework,
    SyncTask.lessons => WatchKind.grades,
    _ => null,
  };

  PollStatus status(WatchKind kind) =>
      PollStatus.fromJson(db.getJson('poll:${kind.name}'));

  /// Next scheduled check of [kind] (the sync of its data).
  DateTime nextRun(WatchKind kind) => sync.nextRun(taskFor(kind));

  /// Syncs the given kinds (all configured kinds by default) now and returns
  /// the number of notifications sent.
  Future<int> runNow([Iterable<WatchKind>? kinds]) async {
    final before = _sentTotal;
    await sync.refreshNow([
      for (final k in (kinds ?? config.kinds)) taskFor(k),
    ]);
    return _sentTotal - before;
  }

  Future<void> _onData(SyncTask task, Object? data) async {
    final kind = _kindFor(task);
    if (kind == null || !config.kinds.contains(kind)) return;
    // WebUntis task: null until the Schulportal plan is known.
    if (data == null) return;
    final seen = db.seen(kind.name);
    final detection = switch (kind) {
      WatchKind.substitutions => detectSubstitutions(
        data as List<SubstitutionDay>,
        seen,
        _now(),
        include: substitutionFilter?.call().matches,
      ),
      WatchKind.homework => detectHomework(data as List<Homework>, seen),
      WatchKind.grades => detectGrades(
        (data as LessonsSnapshot).grades,
        seen,
        includeValues: config.includeGradeValues,
      ),
    };
    _sentTotal += await _process(kind, detection);
  }

  void _onFailure(SyncTask task, Object error) {
    final kind = _kindFor(task);
    if (kind == null || !config.kinds.contains(kind)) return;
    final previous = status(kind);
    _save(
      kind,
      PollStatus(
        lastRun: _now(),
        lastSuccess: previous.lastSuccess,
        lastError: SyncService.describeError(error),
        sent: previous.sent,
        baseline: previous.baseline,
      ),
    );
  }

  Future<int> _process(WatchKind kind, Detection detection) async {
    final started = _now();
    final previous = status(kind);
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

  void _save(WatchKind kind, PollStatus s) =>
      db.setJson('poll:${kind.name}', s.toJson());
}
