// Command-line access to SphService; prints JSON.
//
// Usage (from server/):
//   dart run bin/sph.dart <command> [args]
//
// Commands:
//   account                 account info and enabled features
//   timetable               Stundenplan
//   substitutions           Vertretungsplan
//   calendar [from] [to]    Kalender (dates as YYYY-MM-DD; default today … +60 days)
//   courses                 courses from Mein Unterricht
//   homework                current homework
//   course <id>             course details (history, grades, exams)
//   grades                  grades and exams of all courses
//
// Credentials: SPH_SCHOOL_ID, SPH_USERNAME, SPH_PASSWORD (env or server/.env).

import 'dart:convert';
import 'dart:io';

import 'package:lumo_server/lumo_server.dart';

const _usage = '''
Usage: dart run bin/sph.dart <command> [args]

Commands:
  account | timetable | substitutions | courses | homework | grades
  calendar [from] [to]   dates as YYYY-MM-DD
  course <id>''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.writeln(_usage);
    exit(args.isEmpty ? 64 : 0);
  }

  final creds = SphCredentials.fromEnv(loadEnv());
  if (creds == null) {
    stderr.writeln(
      'Missing credentials: set SPH_USERNAME and SPH_PASSWORD '
      '(see server/.env.example).',
    );
    exit(2);
  }

  final service = SphService(
    LiblanisGateway(
      schoolId: creds.schoolId,
      username: creds.username,
      password: creds.password,
    ),
  );

  try {
    final Object? result = switch (args) {
      ['account'] => await service.account(),
      ['timetable'] => await service.timetable(),
      ['substitutions'] => await service.substitutions(),
      ['calendar'] => await service.calendar(),
      ['calendar', final from] => await service.calendar(
        from: DateTime.parse(from),
      ),
      ['calendar', final from, final to] => await service.calendar(
        from: DateTime.parse(from),
        to: DateTime.parse(to),
      ),
      ['courses'] => await service.courses(),
      ['homework'] => await service.homework(),
      ['course', final id] => await service.courseDetails(id),
      ['grades'] => await service.grades(),
      _ => null,
    };
    if (result == null) {
      stderr.writeln(_usage);
      exitCode = 64;
      return;
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } on SphException catch (e) {
    stderr.writeln(e);
    exitCode = switch (e) {
      SphAuthException() => 3,
      SphUnavailableException() => 4,
      SphFeatureDisabledException() || SphNotFoundException() => 5,
      SphDataException() => 6,
    };
  } on FormatException catch (e) {
    stderr.writeln('Invalid date: ${e.message}\n\n$_usage');
    exitCode = 64;
  } finally {
    await service.dispose();
  }
}
