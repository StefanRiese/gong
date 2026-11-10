// Proof of concept: changed lessons from WebUntis (REST interface of the web
// app), compared with the
// Schulportal substitution plan.
//
// Credentials from the environment or server/.env:
//   UNTIS_SERVER=xyz.webuntis.com  UNTIS_SCHOOL=xyz
//   UNTIS_USERNAME=…  UNTIS_PASSWORD=…
//
//   dart run bin/untis.dart [days]            changes and comparison (default 14 days)
//   dart run bin/untis.dart --summary [days]  counts only (for logs / debugging)

import 'dart:io';

import 'package:gong_server/gong_server.dart';

Future<void> main(List<String> args) async {
  final summary = args.contains('--summary');
  final rest = args.where((a) => !a.startsWith('--')).toList();
  final days = rest.isEmpty ? 14 : int.parse(rest.first);

  final env = loadEnv();
  String? need(String key) {
    final v = env[key];
    return v == null || v.isEmpty ? null : v;
  }

  final server = need('UNTIS_SERVER');
  final school = need('UNTIS_SCHOOL');
  final user = need('UNTIS_USERNAME');
  final password = need('UNTIS_PASSWORD');
  if (server == null || school == null || user == null || password == null) {
    stderr.writeln(
      'UNTIS_SERVER, UNTIS_SCHOOL, UNTIS_USERNAME, UNTIS_PASSWORD needed',
    );
    exit(2);
  }

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final client = UntisClient(
    server: server,
    school: school,
    username: user,
    password: password,
  );

  List<UntisChange> changes;
  List<UntisLesson> lessons;
  String? className;
  try {
    await client.login();
    className = client.klasse?.$2;
    (changes, lessons) = await client.load(today, days: days);
  } on UntisException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  } finally {
    await client.logout();
    client.close();
  }

  // Schulportal plan for comparison (optional).
  List<SubstitutionDay>? portal;
  Timetable? timetable;
  final creds = SphCredentials.fromEnv(env);
  if (creds != null) {
    final service = SphService(
      LiblanisGateway(
        schoolId: creds.schoolId,
        username: creds.username,
        password: creds.password,
      ),
    );
    try {
      portal = await service.substitutions();
      timetable = await service.timetable();
    } on SphException catch (e) {
      stderr.writeln('Schulportal: $e');
    } finally {
      await service.dispose();
    }
  }

  // Only the days WebUntis was asked for.
  final until = today.add(Duration(days: days));
  portal = portal?.where((d) => d.date.isBefore(until)).toList();
  final lastPortalDay = portal == null || portal.isEmpty
      ? null
      : portal.map((d) => d.date).reduce((a, b) => a.isAfter(b) ? a : b);
  final inPortal = <UntisChange>[];
  final onlyUntis = <UntisChange>[];
  final beyond = <UntisChange>[];
  for (final c in changes) {
    if (lastPortalDay != null && c.date.isAfter(lastPortalDay)) {
      beyond.add(c);
    } else if (portal != null && _matches(c, portal, className)) {
      inPortal.add(c);
    } else {
      onlyUntis.add(c);
    }
  }

  // Portal entries of the class that WebUntis does not show.
  var portalOnly = 0;
  var portalOwn = 0;
  for (final d in portal ?? const <SubstitutionDay>[]) {
    for (final s in d.entries) {
      if (!_sameClass(s.className, className)) continue;
      portalOwn++;
      final hit = changes.any(
        (c) => _sameDay(c.date, d.date) && _periodsOverlap(c.period, s.period),
      );
      if (!hit) portalOnly++;
    }
  }

  Map<String, int> byType(List<UntisChange> list) {
    final m = <String, int>{};
    for (final c in list) {
      m[c.type] = (m[c.type] ?? 0) + 1;
    }
    return m;
  }

  stdout.writeln(
    'WebUntis: login ok; class ${className ?? '?'}; '
    'changes in $days days: ${changes.length} ${byType(changes)}',
  );
  if (portal == null) {
    stdout.writeln('Schulportal: not compared (no credentials or error)');
  } else {
    stdout.writeln(
      'Schulportal: ${portal.length} days up to '
      '${lastPortalDay?.toIso8601String().substring(0, 10) ?? '-'}; '
      '$portalOwn entries for the class, $portalOnly not in WebUntis',
    );
    stdout.writeln(
      'WebUntis changes: ${inPortal.length} also in Schulportal, '
      '${onlyUntis.length} only in WebUntis ${byType(onlyUntis)}, '
      '${beyond.length} after the Schulportal plan ${byType(beyond)}',
    );
  }
  if (timetable != null) {
    final diffs = compareTimetables(
      timetable,
      UntisSnapshot(
        className: className ?? '',
        changes: changes,
        lessons: lessons,
      ),
      today,
    );
    stdout.writeln(
      'Timetable: ${lessons.length} WebUntis lessons in 2 weeks, '
      '${diffs.length} differences from the Schulportal timetable',
    );
    if (!summary) {
      for (final d in diffs) {
        stdout.writeln('  ${d.text}');
      }
    }
  }
  if (summary) return;
  for (final (label, list) in [
    ('Only in WebUntis', onlyUntis),
    ('After the Schulportal plan', beyond),
    ('Also in Schulportal', inPortal),
  ]) {
    if (list.isEmpty) continue;
    stdout.writeln('\n$label:');
    for (final c in list) {
      stdout.writeln('  $c');
    }
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "05e" and "5e" are the same class.
String _normClass(String s) =>
    s.trim().toLowerCase().replaceFirst(RegExp(r'^0+'), '');

bool _sameClass(String? portalClasses, String? untisClass) {
  if (portalClasses == null || untisClass == null) return false;
  final want = _normClass(untisClass);
  return portalClasses
      .split(RegExp(r'[,\s]+'))
      .where((c) => c.isNotEmpty)
      .any((c) => _normClass(c) == want);
}

(int, int)? _range(String? period) {
  if (period == null) return null;
  final n = RegExp(
    r'\d+',
  ).allMatches(period).map((m) => int.parse(m[0]!)).toList();
  if (n.isEmpty) return null;
  return (n.first, n.last);
}

bool _periodsOverlap(String? a, String? b) {
  final ra = _range(a);
  final rb = _range(b);
  if (ra == null || rb == null) return false;
  return ra.$1 <= rb.$2 && rb.$1 <= ra.$2;
}

bool _matches(UntisChange c, List<SubstitutionDay> portal, String? className) {
  for (final d in portal) {
    if (!_sameDay(d.date, c.date)) continue;
    for (final s in d.entries) {
      if (_sameClass(s.className, className) &&
          _periodsOverlap(c.period, s.period)) {
        return true;
      }
    }
  }
  return false;
}
