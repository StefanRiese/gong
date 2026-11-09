import 'dart:convert';

import 'package:liblanis/easy_client.dart' as lanis;
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
    expect(days[1].entries, hasLength(3));
    final s = days[1].entries.first;
    expect(s.period, '3');
    expect(s.className, '05eG');
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

  test('mapHomeworkHistory: entries with homework, newest first', () {
    final lesson = sampleLessons().first;
    final details = sampleDetails(lesson)
      ..history.add(
        lanis.CurrentEntry(
          entryID: 'old',
          files: [],
          uploads: [],
          topicDate: DateTime(2026, 10, 1),
          homework: lanis.Homework(description: 'Alt', homeWorkDone: true),
        ),
      )
      ..history.add(
        lanis.CurrentEntry(entryID: 'nohw', files: [], uploads: []),
      );
    final hw = mapHomeworkHistory(lesson, details);
    expect(hw.map((h) => (h.entryId, h.done)), [('e1', false), ('old', true)]);
    expect(hw.first.courseName, 'Mathematik');
  });

  test('HTML entities are decoded in plain-text fields only', () {
    final cal = mapCalendar([
      lanis.CalendarEvent(
        id: '1',
        title: 'Theater &amp; Musik',
        description: 'Treffpunkt &lt;b&gt;Aula&lt;/b&gt;',
        startTime: DateTime(2026, 11, 20),
        endTime: DateTime(2026, 11, 21),
        allDay: true,
        secret: false,
        isNew: false,
        public: true,
        private: false,
        place: 'Aula &quot;Nord&quot;',
        category: lanis.CalendarEventCategory(
          id: 3,
          colorArgb: 0,
          name: 'schulische Veranstaltungen &amp; Fahrten',
        ),
      ),
    ]).single;
    expect(cal.title, 'Theater & Musik');
    expect(cal.place, 'Aula "Nord"');
    expect(cal.category, 'schulische Veranstaltungen & Fahrten');
    expect(
      cal.description,
      'Treffpunkt &lt;b&gt;Aula&lt;/b&gt;',
      reason: 'HTML fields stay as delivered; the web UI converts them',
    );

    final lesson = sampleLessons().first..name = 'Politik &amp; Wirtschaft';
    expect(mapCourse(lesson).name, 'Politik & Wirtschaft');
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
