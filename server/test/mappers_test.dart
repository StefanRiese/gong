import 'dart:convert';

import 'package:schulportal_server/src/sph/mappers.dart';
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

void main() {
  group('mapTimetable', () {
    final tt = mapTimetable(sampleTimetable());

    test('builds slots with period numbers and breaks', () {
      expect(tt.currentWeek, 'B');
      expect(tt.slots.map((s) => (s.period, s.start, s.end)).toList(), [
        (1, '08:00', '08:45'),
        (2, '08:50', '09:35'),
        (null, '09:35', '09:55'),
        (3, '09:55', '10:40'),
      ]);
      expect(tt.slots[2].isBreak, isTrue);
    });

    test('derives period from start time, not from raw row index', () {
      final monday = tt.lessons.where((l) => l.weekday == 1).toList();
      expect(monday.map((l) => (l.subject, l.period)).toList(), [
        ('Deutsch', 1),
        ('Mathe', 2),
      ]);
    });

    test('maps weekday, duration, week badge and trims fields', () {
      final sport = tt.lessons.singleWhere((l) => l.subject == 'Sport');
      expect(sport.weekday, 2);
      expect(sport.duration, 2);
      expect(sport.week, 'A');
      expect(sport.room, 'R101');
      expect(sport.end, '09:35');
    });
  });

  test('mapSubstitutions sorts days and joins notes', () {
    final days = mapSubstitutions(sampleSubstitutions());
    expect(days.map((d) => d.date).toList(), [
      DateTime(2026, 11, 10),
      DateTime(2026, 11, 11),
    ]);
    final s = days[1].entries.single;
    expect(s.period, '3');
    expect(s.previousRoom, 'R1');
    expect(s.substitute, 'SCH');
    expect(s.note, 'Buch mitbringen');
    expect(days[1].notices.single.lines, ['Wandertag 7b']);
    expect(days[0].entries, isEmpty);
  });

  test('mapCalendar sorts by start and trims', () {
    final entries = mapCalendar(sampleCalendar());
    expect(entries.map((e) => e.id).toList(), ['1', '2']);
    expect(entries[1].title, 'Elternabend');
    expect(entries[1].category, 'Termine');
    expect(entries[0].allDay, isTrue);
  });

  test('mapCurrentHomework skips blank homework', () {
    final hw = mapCurrentHomework(sampleLessons());
    expect(hw, hasLength(1));
    expect(hw.single.courseName, 'Mathematik');
    expect(hw.single.description, 'S. 12 Nr. 3');
    expect(hw.single.date, DateTime(2026, 11, 9));
  });

  test('mapCourse falls back to teacher abbreviation', () {
    final courses = sampleLessons().map(mapCourse).toList();
    expect(courses[0].teachers, ['Müller']);
    expect(courses[1].teachers, ['SMI']);
  });

  test('mapCourseDetails includes grades, exams and history', () {
    final d = mapCourseDetails(sampleDetails(sampleLessons().first));
    expect(d.grades.single.mark, '2+');
    expect(d.exams.single.value, '15.12.2026');
    expect(d.history.single.homework, 'S. 12 Nr. 3');
    expect(d.attendance, {'fehlende Stunden': '0'});
  });

  test('models serialise to JSON', () {
    final tt = mapTimetable(sampleTimetable());
    final hw = mapCurrentHomework(sampleLessons());
    final json = jsonDecode(jsonEncode({'tt': tt, 'hw': hw}));
    expect(json['tt']['lessons'][0]['subject'], 'Deutsch');
    expect(json['hw'][0]['date'], '2026-11-09');
  });
}
