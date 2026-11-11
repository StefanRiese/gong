import '../notify/poller.dart';
import '../sync/sync_service.dart';

/// How a service is doing, as an LED: green, yellow, red, gray.
enum HealthState {
  /// Reachable and up to date.
  ok,

  /// Works with limits: a failed attempt that is retried, or old data.
  warn,

  /// Does not work: login rejected, unreachable for several attempts.
  error,

  /// Nothing known (yet), or checking is switched off.
  unknown,
}

/// Health of one service (Schulportal, Caseda, WebUntis, ntfy, updates).
class ServiceHealth {
  /// `schulportal`, `caseda`, `untis`, `ntfy` or `updates`.
  final String key;

  /// German name for the web UI.
  final String name;
  final HealthState state;

  /// German one-liner: what is going on.
  final String detail;
  final DateTime? lastSuccess;

  /// Failed attempts in a row.
  final int failures;

  const ServiceHealth({
    required this.key,
    required this.name,
    required this.state,
    required this.detail,
    this.lastSuccess,
    this.failures = 0,
  });

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'state': state.name,
    'detail': detail,
    'lastSuccess': lastSuccess?.toUtc().toIso8601String(),
    'failures': failures,
  };
}

/// After this many failed attempts in a row a service counts as down.
const failuresUntilError = 3;

/// Data older than this (three sync intervals, at least 12 hours) counts as
/// old although nothing failed – e.g. the sync stopped for another reason.
Duration staleAfter(Duration interval) {
  final three = interval * 3;
  return three < const Duration(hours: 12) ? const Duration(hours: 12) : three;
}

/// Health of a service that is kept up to date by the sync [tasks] (the ones
/// that apply; null when there are none, i.e. the service is not set up).
ServiceHealth? healthOfTasks({
  required String key,
  required String name,
  required SyncService sync,
  required Iterable<SyncTask> tasks,
  required DateTime now,
}) {
  final applicable = tasks.where(sync.tasks.contains).toList();
  if (applicable.isEmpty) return null;
  ServiceHealth result(
    HealthState state,
    String detail, {
    DateTime? lastSuccess,
    int failures = 0,
  }) => ServiceHealth(
    key: key,
    name: name,
    state: state,
    detail: detail,
    lastSuccess: lastSuccess,
    failures: failures,
  );

  if (!sync.config.enabled) {
    return result(
      HealthState.unknown,
      'Der Abgleich im Hintergrund ist ausgeschaltet',
    );
  }
  final statuses = [for (final t in applicable) (t, sync.status(t))];
  DateTime? lastSuccess;
  for (final (_, s) in statuses) {
    final ok = s.lastSuccess;
    if (ok != null && (lastSuccess == null || ok.isAfter(lastSuccess))) {
      lastSuccess = ok;
    }
  }
  if (statuses.every((e) => e.$2.lastRun == null)) {
    return result(HealthState.unknown, 'Noch nicht abgefragt');
  }

  final failing = [
    for (final e in statuses)
      if (e.$2.failures > 0) e.$2,
  ]..sort((a, b) => b.failures.compareTo(a.failures));
  if (failing.isNotEmpty) {
    final worst = failing.first;
    final what = worst.lastError ?? 'Abfrage fehlgeschlagen';
    if (what.contains('Anmeldung')) {
      return result(
        HealthState.error,
        '$what – bitte die Zugangsdaten prüfen',
        lastSuccess: lastSuccess,
        failures: worst.failures,
      );
    }
    if (worst.failures >= failuresUntilError) {
      return result(
        HealthState.error,
        '$what (${worst.failures}. Versuch in Folge)',
        lastSuccess: lastSuccess,
        failures: worst.failures,
      );
    }
    return result(
      HealthState.warn,
      '$what – wird erneut versucht',
      lastSuccess: lastSuccess,
      failures: worst.failures,
    );
  }

  for (final (task, s) in statuses) {
    final ok = s.lastSuccess;
    if (ok != null &&
        now.difference(ok) > staleAfter(sync.config.intervalFor(task))) {
      return result(
        HealthState.warn,
        'Die Daten sind veraltet',
        lastSuccess: lastSuccess,
      );
    }
  }
  return result(HealthState.ok, 'Verbunden', lastSuccess: lastSuccess);
}

/// Health of the ntfy server for notifications; null when notifications are
/// off. [reachable] is the result of a check of the server (null = not known),
/// [statuses] the state of every watched kind of every account.
ServiceHealth? healthOfNtfy({
  required bool configured,
  required bool? reachable,
  required Iterable<PollStatus> statuses,
}) {
  if (!configured) return null;
  const name = 'Benachrichtigungen (ntfy)';
  if (reachable == false) {
    return const ServiceHealth(
      key: 'ntfy',
      name: name,
      state: HealthState.error,
      detail: 'Der ntfy-Server ist nicht erreichbar',
    );
  }
  final failed = statuses
      .where((s) => (s.lastError ?? '').startsWith('Senden fehlgeschlagen'))
      .firstOrNull;
  if (failed != null) {
    return ServiceHealth(
      key: 'ntfy',
      name: name,
      state: HealthState.error,
      detail: failed.lastError!,
    );
  }
  if (reachable == null) {
    return const ServiceHealth(
      key: 'ntfy',
      name: name,
      state: HealthState.unknown,
      detail: 'Noch nicht geprüft',
    );
  }
  return const ServiceHealth(
    key: 'ntfy',
    name: name,
    state: HealthState.ok,
    detail: 'Erreichbar',
  );
}

/// Health of the check for new releases (GitHub), from `UpdateService.status()`;
/// null when the check is switched off.
ServiceHealth? healthOfUpdates(Map<String, Object?> status) {
  const name = 'Update-Server (GitHub)';
  if (status['checkEnabled'] == false) return null;
  final error = status['checkError'];
  if (error != null) {
    return ServiceHealth(
      key: 'updates',
      name: name,
      state: HealthState.warn,
      detail: '$error',
    );
  }
  final checked = DateTime.tryParse('${status['checkedAt']}');
  if (checked == null) {
    return const ServiceHealth(
      key: 'updates',
      name: name,
      state: HealthState.unknown,
      detail: 'Noch nicht geprüft',
    );
  }
  return ServiceHealth(
    key: 'updates',
    name: name,
    state: HealthState.ok,
    detail: status['available'] == true
        ? 'Update ${status['latest']} verfügbar'
        : 'Verbunden',
    lastSuccess: checked,
  );
}
