// Milestone 1 spike: verify liblanis against our school.
//
// Usage (from server/):
//   dart run bin/spike.dart              # SQLite check + login + summary
//   dart run bin/spike.dart --db-only    # SQLite check only (no network)
//   dart run bin/spike.dart --details    # also print homework, grades, etc.
//
// Credentials are read from environment variables or server/.env:
//   SPH_SCHOOL_ID (default 6128), SPH_USERNAME, SPH_PASSWORD

import 'dart:io';

import 'package:liblanis/easy_client.dart';

const userAgent = 'schulportal-client-spike/0.1';

Future<void> main(List<String> args) async {
  final dbOnly = args.contains('--db-only');
  final details = args.contains('--details');

  final dbOk = checkSqlite();
  if (dbOnly) exit(dbOk ? 0 : 1);

  final env = loadEnv();
  final schoolId = int.tryParse(env['SPH_SCHOOL_ID'] ?? '6128');
  final username = env['SPH_USERNAME'];
  final password = env['SPH_PASSWORD'];
  if (schoolId == null ||
      username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    stderr.writeln(
      'Missing credentials: set SPH_USERNAME and SPH_PASSWORD '
      '(see server/.env.example).',
    );
    exit(2);
  }

  final client = EasyLanisClient.ephemeral(
    schoolId: schoolId,
    username: username,
    password: password,
    userAgent: userAgent,
  );

  try {
    section('Login');
    try {
      await client.login();
    } on WrongCredentialsException {
      stderr.writeln('Login failed: wrong username or password.');
      exit(3);
    } on LanisException catch (e) {
      stderr.writeln('Login failed: ${e.runtimeType}: $e');
      exit(3);
    }
    print('Logged in to school $schoolId as $username');
    print('Account type: ${client.session?.accountTypeOrNull?.name}');

    section('Applets enabled for this account');
    final applets = client.supportedApplets.toList()..sort();
    for (final a in applets) {
      print('  - $a');
    }

    final results = <String, String>{};
    Future<void> probe(String name, Future<String> Function() run) async {
      section(name);
      try {
        final summary = await run();
        results[name] = 'OK  $summary';
      } catch (e) {
        print('  ERROR: ${e.runtimeType}: $e');
        results[name] = 'ERR ${e.runtimeType}';
      }
    }

    final p = client.parsers;

    await probe('Stundenplan', () async {
      final tt = await p.timetable.getHome();
      final own = tt.planForOwn ?? tt.planForAll ?? [];
      final lessons = own.fold<int>(0, (n, day) => n + day.length);
      if (details) {
        const dayNames = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
        for (var i = 0; i < own.length; i++) {
          print('  ${i < dayNames.length ? dayNames[i] : 'Tag $i'}:');
          for (final s in own[i]) {
            print(
              '    ${s.startTime}-${s.endTime}  ${s.name ?? '?'}'
              '  ${s.raum ?? ''}  ${s.lehrer ?? ''}',
            );
          }
        }
      }
      return '${own.length} days, $lessons lessons'
          '${tt.weekBadge != null ? ', week ${tt.weekBadge}' : ''}';
    });

    await probe('Vertretungsplan', () async {
      final plan = await p.substitutions.getHome();
      final count = plan.days.fold<int>(
        0,
        (n, d) => n + d.substitutions.length,
      );
      if (details) {
        for (final d in plan.days) {
          print('  ${d.parsedDate}: ${d.substitutions.length} entries');
          for (final s in d.substitutions) {
            print(
              '    ${s.stunde}. Std  ${s.fach ?? ''}  ${s.art ?? ''}'
              '  ${s.raum ?? ''}  ${s.hinweis ?? ''}',
            );
          }
        }
      }
      return '${plan.days.length} days, $count substitutions';
    });

    await probe('Kalender', () async {
      final events = await p.calendar.getHome();
      if (details) {
        for (final e in events.take(20)) {
          print(
            '  ${e.startTime.toIso8601String().substring(0, 10)}'
            '  ${e.title}',
          );
        }
      }
      return '${events.length} events';
    });

    await probe('Mein Unterricht (Hausaufgaben, Noten)', () async {
      final lessons = await p.lessonsStudent.getHome();
      var homework = 0, marks = 0, exams = 0, detailErrors = 0;
      for (final l in lessons) {
        final hw = l.currentEntry?.homework;
        if (hw != null) {
          homework++;
          if (details) {
            print(
              '  [HA] ${l.name}: ${hw.description.trim()}'
              '${hw.homeWorkDone ? ' (erledigt)' : ''}',
            );
          }
        }
        try {
          final d = await p.lessonsStudent.getDetailedCourseView(
            l.courseURL.toString(),
          );
          marks += d.marks.length;
          exams += d.exams.length;
          if (details) {
            for (final m in d.marks) {
              print('  [Note] ${l.name}: ${m.name} ${m.date} → ${m.mark}');
            }
            for (final x in d.exams) {
              print('  [Klausur] ${l.name}: ${x.name} ${x.value ?? ''}');
            }
          }
        } catch (e) {
          detailErrors++;
          print('  detail view failed for ${l.name}: ${e.runtimeType}');
        }
      }
      return '${lessons.length} courses, $homework current homework, '
          '$marks marks, $exams exams'
          '${detailErrors > 0 ? ', $detailErrors detail errors' : ''}';
    });

    await probe('Nachrichten', () async {
      final convs = await p.conversations.getHome();
      final unread = convs.where((c) => c.unread).length;
      if (details) {
        for (final c in convs.take(10)) {
          print('  ${c.date}  ${c.unread ? '*' : ' '} ${c.title}');
        }
      }
      return '${convs.length} conversations, $unread unread';
    });

    section('Summary');
    print('  SQLite (file DB)  ${dbOk ? 'OK' : 'ERR'}');
    results.forEach((k, v) => print('  ${k.padRight(40)} $v'));
  } finally {
    try {
      await client.logout();
    } catch (_) {}
    await client.dispose();
  }
}

/// Opens a file-based liblanis database to verify native SQLite works here.
bool checkSqlite() {
  section('SQLite check');
  final dir = Directory.systemTemp.createTempSync('sph_spike_');
  try {
    final db = LanisDatabase.open(
      path: '${dir.path}/test.db',
      secretStore: MemorySecretStore(),
    );
    db.setSharedSetting('spike', 'ok');
    final ok = db.getSharedSetting('spike') == 'ok';
    db.dispose();
    print(ok ? '  OK (${Platform.operatingSystem})' : '  read-back mismatch');
    return ok;
  } catch (e) {
    print('  FAILED: $e');
    return false;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Environment variables take precedence; server/.env only fills gaps.
Map<String, String> loadEnv() {
  final env = Map<String, String>.from(Platform.environment);
  final file = File('.env');
  if (file.existsSync()) {
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
      final i = line.indexOf('=');
      final key = line.substring(0, i).trim();
      var value = line.substring(i + 1).trim();
      if (value.length >= 2 &&
          (value.startsWith('"') && value.endsWith('"') ||
              value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      env.putIfAbsent(key, () => value);
    }
  }
  return env;
}

void section(String title) => print('\n== $title');
