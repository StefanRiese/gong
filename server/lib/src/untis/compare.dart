import '../models/models.dart';
import 'untis.dart';

/// One difference between the Schulportal timetable and WebUntis.
class TimetableDifference {
  final int weekday;

  /// Period of the Schulportal slot (or null), "HH:MM" start of the lesson.
  final String start;
  final String text;

  const TimetableDifference({
    required this.weekday,
    required this.start,
    required this.text,
  });

  Map<String, Object?> toJson() => {
    'weekday': weekday,
    'start': start,
    'text': text,
  };
}

const _days = ['Mo', 'Di', 'Mi', 'Do', 'Fr'];

int _minutes(String hm) {
  final p = hm.split(':');
  return int.parse(p[0]) * 60 + int.parse(p[1]);
}

String _norm(String? s) =>
    (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');

/// "M" and "Mathematik", "PoWi" and "powi" are the same subject; a missing
/// name is not a difference.
bool _sameSubject(String? a, String? b) {
  final x = _norm(a), y = _norm(b);
  return x.isEmpty || y.isEmpty || x.startsWith(y) || y.startsWith(x);
}

/// [theirs] may list several rooms ("B6, C1").
bool _sameRoom(String? ours, String? theirs) {
  final x = _norm(ours);
  if (x.isEmpty || _norm(theirs).isEmpty) return true;
  return theirs!.split(',').any((r) => _norm(r) == x);
}

bool _overlap(String s1, String e1, String s2, String e2) =>
    _minutes(s1) < _minutes(e2) && _minutes(s2) < _minutes(e1);

/// Compares the regular lessons of WebUntis (current and next week) with the
/// Schulportal [timetable]. Days without any WebUntis lesson (holidays) are
/// skipped. [today] decides which of two alternating weeks is which.
List<TimetableDifference> compareTimetables(
  Timetable timetable,
  UntisSnapshot? untis,
  DateTime today,
) {
  if (untis == null || untis.lessons.isEmpty || timetable.lessons.isEmpty) {
    return const [];
  }
  final monday = DateTime(
    today.year,
    today.month,
    today.day - (today.weekday - 1),
  );
  final hasWeeks = timetable.lessons.any((l) => l.week != null);
  final current = timetable.currentWeek;
  String? weekOf(DateTime date) {
    if (!hasWeeks || current == null) return null;
    final sameWeek =
        date.difference(monday).inDays ~/ 7 % 2 == 0; // 0 = this week
    return sameWeek ? current : (current == 'A' ? 'B' : 'A');
  }

  final found = <String, TimetableDifference>{};
  void add(int weekday, String start, String text) =>
      found.putIfAbsent('$weekday $start $text', () {
        return TimetableDifference(weekday: weekday, start: start, text: text);
      });

  final dates = {for (final l in untis.lessons) l.date};
  for (final date in dates) {
    final weekday = date.weekday;
    if (weekday > 5) continue;
    final week = weekOf(date);
    final theirs = untis.lessons.where((l) => l.date == date).toList();
    final ours = timetable.lessons
        .where(
          (l) => l.weekday == weekday && (l.week == null || l.week == week),
        )
        .toList();
    final dayName = _days[weekday - 1];
    final weekInfo = hasWeeks && week != null ? ' (Woche $week)' : '';

    for (final u in theirs) {
      final match = ours
          .where((p) => _overlap(p.start, p.end, u.start, u.end))
          .toList();
      final label = '$dayName ${u.start}$weekInfo';
      if (match.isEmpty) {
        add(
          weekday,
          u.start,
          '$label: WebUntis hat ${u.subject ?? 'eine Stunde'}, im Schulportal-Stundenplan fehlt sie',
        );
      } else if (theirs.any(
        (o) => o != u && _overlap(o.start, o.end, u.start, u.end),
      )) {
        // Parallel groups (religion / ethics, …): the class account shows all
        // of them, the own group cannot be told apart.
        continue;
      } else if (!match.any((p) => _sameSubject(p.subject, u.subject))) {
        add(
          weekday,
          u.start,
          '$label: Schulportal ${match.first.subject ?? '—'}, WebUntis ${u.subject ?? '—'}',
        );
      } else if (!match.any(
        (p) => _sameSubject(p.subject, u.subject) && _sameRoom(p.room, u.room),
      )) {
        add(
          weekday,
          u.start,
          '$label: Raum im Schulportal ${match.first.room ?? '—'}, in WebUntis ${u.room ?? '—'}',
        );
      }
    }
    for (final p in ours) {
      if (!theirs.any((u) => _overlap(p.start, p.end, u.start, u.end))) {
        add(
          weekday,
          p.start,
          '$dayName ${p.start}$weekInfo: Schulportal hat ${p.subject ?? 'eine Stunde'}, in WebUntis fehlt sie',
        );
      }
    }
  }
  final out = found.values.toList()
    ..sort((a, b) {
      final d = a.weekday.compareTo(b.weekday);
      return d != 0 ? d : a.start.compareTo(b.start);
    });
  return out;
}
