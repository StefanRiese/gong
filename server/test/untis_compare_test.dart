import 'package:lumo_server/lumo_server.dart';
import 'package:test/test.dart';

// 2026-11-09 is a Monday.
final _monday = DateTime(2026, 11, 9);

TimetableLesson _ours(
  int weekday,
  String start,
  String end,
  String subject, {
  String? room,
  String? week,
}) => TimetableLesson(
  weekday: weekday,
  period: null,
  duration: 1,
  start: start,
  end: end,
  subject: subject,
  room: room,
  teacher: null,
  week: week,
);

UntisLesson _theirs(
  int dayOffset,
  String start,
  String end,
  String subject, {
  String? room,
}) => UntisLesson(
  date: _monday.add(Duration(days: dayOffset)),
  start: start,
  end: end,
  subject: subject,
  room: room,
);

Timetable _tt(List<TimetableLesson> l, {String? week}) =>
    Timetable(currentWeek: week, slots: const [], lessons: l);

UntisSnapshot _snap(List<UntisLesson> l) =>
    UntisSnapshot(className: '05eG', changes: const [], lessons: l);

void main() {
  group('compareTimetables', () {
    test('no differences when both agree (abbreviations, room lists)', () {
      final diffs = compareTimetables(
        _tt([_ours(1, '07:50', '08:35', 'Mathematik', room: 'B6')]),
        _snap([_theirs(0, '07:50', '08:35', 'M', room: 'B6, C1')]),
        _monday,
      );
      expect(diffs, isEmpty);
    });

    test('lesson only in one source, different subject, different room', () {
      final diffs = compareTimetables(
        _tt([
          _ours(1, '07:50', '08:35', 'M', room: 'B6'),
          _ours(1, '08:40', '09:25', 'D'),
          _ours(2, '07:50', '08:35', 'E', room: 'B6'),
        ]),
        _snap([
          _theirs(0, '07:50', '08:35', 'M', room: 'A1'),
          _theirs(0, '08:40', '09:25', 'Geo'),
          _theirs(0, '10:00', '10:45', 'LRS'),
          _theirs(1, '12:00', '12:45', 'X'), // Tuesday: only here
        ]),
        _monday,
      );
      final texts = diffs.map((d) => d.text).toList();
      expect(texts, hasLength(5));
      expect(texts.any((t) => t.contains('Raum im Schulportal B6')), isTrue);
      expect(
        texts.any((t) => t.contains('Schulportal D, WebUntis Geo')),
        isTrue,
      );
      expect(texts.any((t) => t.contains('WebUntis hat LRS')), isTrue);
      expect(texts.any((t) => t.contains('WebUntis hat X')), isTrue);
      // Tuesday 07:50 is in the Schulportal timetable, WebUntis has Tuesday
      // lessons, but none then.
      expect(
        texts.any((t) => t.contains('Schulportal hat E, in WebUntis')),
        isTrue,
      );
    });

    test('parallel groups are not reported', () {
      final diffs = compareTimetables(
        _tt([_ours(1, '07:50', '08:35', 'ETHI', room: 'B6')]),
        _snap([
          _theirs(0, '07:50', '08:35', 'REV', room: 'C1'),
          _theirs(0, '07:50', '08:35', 'RKA', room: 'C5'),
        ]),
        _monday,
      );
      expect(diffs, isEmpty);
    });

    test('days without WebUntis lessons (holidays) are skipped', () {
      final diffs = compareTimetables(
        _tt([_ours(1, '07:50', '08:35', 'M'), _ours(3, '07:50', '08:35', 'D')]),
        _snap([_theirs(0, '07:50', '08:35', 'M')]),
        _monday,
      );
      expect(diffs, isEmpty);
    });

    test('alternating weeks: the next week is the other marker', () {
      final tt = _tt([
        _ours(1, '07:50', '08:35', 'M', week: 'A'),
        _ours(1, '07:50', '08:35', 'D', week: 'B'),
      ], week: 'A');
      final diffs = compareTimetables(
        tt,
        _snap([
          _theirs(0, '07:50', '08:35', 'M'),
          _theirs(7, '07:50', '08:35', 'D'),
        ]),
        _monday,
      );
      expect(diffs, isEmpty);
    });

    test('nothing without WebUntis data', () {
      expect(
        compareTimetables(
          _tt([_ours(1, '07:50', '08:35', 'M')]),
          null,
          _monday,
        ),
        isEmpty,
      );
      expect(
        compareTimetables(
          _tt([_ours(1, '07:50', '08:35', 'M')]),
          _snap(const []),
          _monday,
        ),
        isEmpty,
      );
    });
  });

  test('mapUntisLessons shows the regular lesson of changed entries', () {
    Map<String, Object?> pos(
      String type,
      String? now,
      String nowStatus, [
      String? was,
    ]) => {
      'current': now == null
          ? null
          : {'type': type, 'status': nowStatus, 'shortName': now},
      'removed': was == null
          ? null
          : {'type': type, 'status': 'REMOVED', 'shortName': was},
    };
    final lessons = mapUntisLessons({
      'days': [
        {
          'gridEntries': [
            {
              'status': 'CHANGED',
              'duration': {
                'start': '2026-11-09T07:50:00',
                'end': '2026-11-09T08:35:00',
              },
              'position1': [pos('TEACHER', 'VER', 'ADDED', 'ABC')],
              'position2': [pos('SUBJECT', 'M', 'REGULAR')],
              'position3': [pos('ROOM', 'C2', 'ADDED', 'B6')],
            },
            {
              'status': 'ADDITIONAL',
              'duration': {
                'start': '2026-11-09T09:00:00',
                'end': '2026-11-09T09:45:00',
              },
            },
          ],
        },
      ],
    });
    expect(lessons, hasLength(1));
    expect(lessons.single.subject, 'M');
    expect(lessons.single.teacher, 'ABC');
    expect(lessons.single.room, 'B6');
    expect(lessons.single.start, '07:50');
    // JSON round trip
    final back = UntisSnapshot.fromJson(
      UntisSnapshot(
        className: 'x',
        changes: const [],
        lessons: lessons,
      ).toJson(),
    );
    expect(back.lessons.single.room, 'B6');
  });
}
