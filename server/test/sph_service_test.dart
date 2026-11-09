import 'dart:async';

import 'package:liblanis/easy_client.dart' as lanis;
import 'package:schulportal_server/schulportal_server.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

void main() {
  late FakeGateway gw;
  late SphService service;
  var now = DateTime(2026, 11, 9, 12);

  SphService create({Duration idle = const Duration(minutes: 5)}) =>
      SphService(gw, idleTimeout: idle, now: () => now);

  setUp(() {
    now = DateTime(2026, 11, 9, 12);
    gw = FakeGateway();
    service = create();
  });

  tearDown(() => service.dispose());

  group('session', () {
    test('logs in lazily on first request, then reuses the session', () async {
      expect(gw.loginCalls, 0);
      await service.timetable();
      await service.substitutions();
      expect(gw.loginCalls, 1);
    });

    test('concurrent requests share one login', () async {
      gw.loginGate = Completer();
      final futures = [
        service.timetable(),
        service.substitutions(),
        service.homework(),
      ];
      await Future<void>.delayed(Duration.zero);
      gw.loginGate!.complete();
      await Future.wait(futures);
      expect(gw.loginCalls, 1);
    });

    test('re-logs in once and retries when the session expired', () async {
      await service.timetable();
      gw.expireSession();
      final tt = await service.timetable();
      expect(tt.lessons, isNotEmpty);
      expect(gw.loginCalls, 2);
    });

    test('gives up after one retry with SphDataException', () async {
      gw.dataErrors.addAll([
        const FormatException('bad html'),
        const FormatException('bad html'),
      ]);
      await expectLater(service.timetable(), throwsA(isA<SphDataException>()));
      expect(gw.loginCalls, 2);
    });

    test('logs out after the idle timeout', () async {
      service = create(idle: const Duration(milliseconds: 20));
      await service.timetable();
      expect(gw.isLoggedIn, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(gw.isLoggedIn, isFalse);
      expect(gw.logoutCalls, 1);

      await service.timetable();
      expect(gw.loginCalls, 2);
    });

    test('dispose logs out and disposes the gateway', () async {
      await service.timetable();
      await service.dispose();
      expect(gw.logoutCalls, 1);
      expect(gw.disposed, isTrue);
      expect(() => service.timetable(), throwsStateError);
    });
  });

  group('errors', () {
    test('wrong credentials → SphAuthException, no retry', () async {
      gw.loginErrors.add(lanis.WrongCredentialsException());
      await expectLater(service.timetable(), throwsA(isA<SphAuthException>()));
      expect(gw.loginCalls, 1);
    });

    test('after auth failure, logins are blocked until retry delay', () async {
      gw.loginErrors.add(lanis.WrongCredentialsException());
      await expectLater(service.timetable(), throwsA(isA<SphAuthException>()));

      now = now.add(const Duration(minutes: 5));
      final e = await service.timetable().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(e, isA<SphAuthException>());
      expect((e as SphAuthException).retryAfter, DateTime(2026, 11, 9, 12, 10));
      expect(gw.loginCalls, 1, reason: 'no login attempt while blocked');

      now = now.add(const Duration(minutes: 6));
      await service.timetable();
      expect(gw.loginCalls, 2);
    });

    test('portal login lockout → SphAuthException', () async {
      gw.loginErrors.add(lanis.LoginTimeoutException('5 Minuten'));
      await expectLater(
        service.timetable(),
        throwsA(
          isA<SphAuthException>().having(
            (e) => e.message,
            'message',
            contains('5 Minuten'),
          ),
        ),
      );
    });

    test('portal down → SphUnavailableException', () async {
      gw.loginErrors.add(lanis.LanisDownException());
      await expectLater(
        service.timetable(),
        throwsA(isA<SphUnavailableException>()),
      );
    });

    test('no connection → SphUnavailableException', () async {
      gw.loginErrors.add(lanis.NoConnectionException());
      await expectLater(
        service.timetable(),
        throwsA(isA<SphUnavailableException>()),
      );
    });

    test('disabled applet → SphFeatureDisabledException', () async {
      gw.applets = {'stundenplan.php'};
      await expectLater(
        service.substitutions(),
        throwsA(isA<SphFeatureDisabledException>()),
      );
    });

    test('unknown course → SphNotFoundException', () async {
      await expectLater(
        service.courseDetails('999'),
        throwsA(isA<SphNotFoundException>()),
      );
    });
  });

  group('data', () {
    test('account lists enabled features', () async {
      final a = await service.account();
      expect(a.schoolId, 6128);
      expect(a.accountType, 'student');
      expect(a.features, {
        SphFeature.timetable,
        SphFeature.substitutions,
        SphFeature.calendar,
        SphFeature.lessons,
      });
    });

    test('calendar defaults to today … +60 days', () async {
      await service.calendar();
      expect(gw.lastCalendarFrom, DateTime(2026, 11, 9));
      expect(gw.lastCalendarTo, DateTime(2027, 1, 8));
    });

    test('calendar rejects inverted range', () {
      expect(
        () => service.calendar(
          from: DateTime(2026, 12, 1),
          to: DateTime(2026, 11, 1),
        ),
        throwsArgumentError,
      );
    });

    test('grades fetch details for every course', () async {
      final grades = await service.grades();
      expect(grades.map((g) => g.course.id), ['100', '200']);
      expect(grades.first.grades.single.mark, '2+');
      expect(gw.lessonDetailCalls, 2);
    });

    test('courseDetails resolves course by id', () async {
      final d = await service.courseDetails('200');
      expect(d.course.name, 'Englisch');
    });

    test('homework returns current homework only', () async {
      final hw = await service.homework();
      expect(hw.single.courseId, '100');
    });
  });
}
