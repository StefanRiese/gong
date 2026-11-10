import 'package:gong_server/gong_server.dart';
import 'package:test/test.dart';

Map<String, Object?> _entry(
  String start,
  String end,
  String status, {
  Map<String, Object?>? teacher,
  List<Map<String, Object?>> rooms = const [],
  String substitutionText = '',
  String notesAll = '',
}) => {
  'status': status,
  'duration': {'start': start, 'end': end},
  'substitutionText': substitutionText,
  'notesAll': notesAll,
  'position1': teacher == null ? null : [teacher],
  'position2': [
    {
      'current': {'type': 'SUBJECT', 'status': 'REGULAR', 'shortName': 'M'},
      'removed': null,
    },
  ],
  'position3': rooms,
};

Map<String, Object?> _teacher(String? now, String? was, [String s = 'ADDED']) =>
    {
      'current': now == null
          ? null
          : {'type': 'TEACHER', 'status': s, 'shortName': now},
      'removed': was == null
          ? null
          : {'type': 'TEACHER', 'status': 'REMOVED', 'shortName': was},
    };

Map<String, Object?> _room(String now, {String? was}) => {
  'current': {
    'type': 'ROOM',
    'status': was == null ? 'REGULAR' : 'ADDED',
    'shortName': now,
  },
  'removed': was == null
      ? null
      : {'type': 'ROOM', 'status': 'REMOVED', 'shortName': was},
};

void main() {
  test('maps cancellations, substitutions and room changes', () {
    final json = {
      'days': [
        {
          'gridEntries': [
            _entry('2026-11-16T08:00', '2026-11-16T08:45', 'REGULAR'),
            _entry(
              '2026-11-16T08:50',
              '2026-11-16T10:25',
              'CANCELLED',
              rooms: [_room('A101')],
            ),
            _entry(
              '2026-11-17T09:45',
              '2026-11-17T10:30',
              'CHANGED',
              teacher: _teacher(null, 'MUS'),
              notesAll: '-',
            ),
            _entry(
              '2026-11-17T10:50',
              '2026-11-17T11:35',
              'CHANGED',
              teacher: _teacher('VER', 'MUS'),
              substitutionText: ' Arbeitsauftrag ',
            ),
            _entry(
              '2026-11-18T08:00',
              '2026-11-18T08:45',
              'CHANGED',
              teacher: _teacher(null, null),
              rooms: [_room('B12', was: 'A101')],
            ),
          ],
        },
      ],
    };
    final changes = mapUntisEntries(
      json,
      periodByStart: {'08:00': 1, '08:50': 2, '09:45': 3, '10:50': 4},
      periodByEnd: {'08:45': 1, '10:25': 3, '10:30': 3, '11:35': 4},
    );
    expect(changes.map((c) => c.type), [
      'Entfall',
      'Vertretung',
      'Vertretung',
      'Raumänderung',
    ]);
    expect((changes[0].period, changes[0].subject), ('2 - 3', 'M'));
    expect((changes[1].teacher, changes[1].substitute), ('MUS', null));
    expect(changes[1].note, isNull, reason: '"-" is no note');
    expect((changes[2].substitute, changes[2].note), ('VER', 'Arbeitsauftrag'));
    expect((changes[3].room, changes[3].previousRoom), ('B12', 'A101'));
    expect(changes[3].date, DateTime(2026, 11, 18));
  });

  test('times', () => expect(untisTime(745), '07:45'));

  group('mergeUntis', () {
    Substitution sub(String period, {String? cls = '05eG'}) =>
        Substitution(period: period, type: 'Vertretung', className: cls);
    UntisChange change(DateTime d, String? period, {String type = 'Entfall'}) =>
        UntisChange(
          date: d,
          period: period,
          start: '08:00',
          end: '08:45',
          type: type,
          subject: 'M',
        );
    final plan = [
      SubstitutionDay(
        date: DateTime(2026, 11, 11),
        entries: [
          sub('3'),
          sub('5', cls: '07aG, 07bG'),
        ],
        notices: const [],
      ),
    ];

    test('covered entries are dropped, others added and marked', () {
      final merged = mergeUntis(
        plan,
        UntisSnapshot(
          className: '5eG', // "05eG" and "5eG" are the same class
          changes: [
            change(DateTime(2026, 11, 11), '2 - 3'), // overlaps period 3
            change(DateTime(2026, 11, 11), '5'), // other class has period 5
            change(DateTime(2026, 11, 19), '1', type: 'Vertretung'),
          ],
        ),
      );
      expect(merged.map((d) => d.date.day), [11, 19]);
      final day11 = merged.first.entries;
      expect(day11.map((e) => (e.period, e.source)), [
        ('3', null),
        ('5', null),
        ('5', 'WebUntis'),
      ]);
      final added = merged.last.entries.single;
      expect(
        (added.type, added.className, added.source),
        ('Vertretung', '5eG', 'WebUntis'),
      );
      expect(added.toJson()['source'], 'WebUntis');
      expect(plan.first.entries.first.toJson().containsKey('source'), isFalse);
    });

    test('nothing to add returns the plan itself', () {
      expect(mergeUntis(plan, null), same(plan));
      final covered = UntisSnapshot(
        className: '05eG',
        changes: [change(DateTime(2026, 11, 11), '3')],
      );
      expect(mergeUntis(plan, covered), same(plan));
    });

    test('lessons without a period are never covered', () {
      final merged = mergeUntis(
        plan,
        UntisSnapshot(
          className: '05eG',
          changes: [change(DateTime(2026, 11, 11), null)],
        ),
      );
      expect(merged.first.entries.last.period, '');
    });
  });

  test('snapshot survives JSON', () {
    final snap = UntisSnapshot(
      className: '05eG',
      changes: [
        UntisChange(
          date: DateTime(2026, 11, 13),
          period: '3',
          start: '09:45',
          end: '10:30',
          type: 'Vertretung',
          subject: 'M',
          teacher: 'MUS',
          substitute: 'VER',
          room: 'B12',
          previousRoom: 'A101',
          note: 'Text',
        ),
      ],
    );
    final back = UntisSnapshot.fromJson(snap.toJson());
    expect(back.className, '05eG');
    expect(back.changes.single.toJson(), snap.changes.single.toJson());
  });

  test('server names from hosts and pasted addresses', () {
    expect(UntisConfig.parseServer('ghs.webuntis.com'), 'ghs.webuntis.com');
    expect(
      UntisConfig.parseServer(
        'https://GHS.webuntis.com/timetable/my-class/lessonDetails/1',
      ),
      'ghs.webuntis.com',
    );
    expect(UntisConfig.parseServer(''), isNull);
    expect(UntisConfig.parseServer('keinpunkt'), isNull);
    expect(UntisConfig.parseServer('a b.example'), isNull);
  });
}
