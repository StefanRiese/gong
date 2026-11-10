import '../models/models.dart';
import 'untis.dart';

/// Source marker of an entry that exists in both sources.
const combinedSource = 'Schulportal + WebUntis';

/// "05eG" and "5eg" are the same class.
String _normClass(String s) =>
    s.trim().toLowerCase().replaceFirst(RegExp(r'^0+'), '');

bool _sameClass(String? portalClasses, String untisClass) {
  if (portalClasses == null) return false;
  final want = _normClass(untisClass);
  return portalClasses
      .split(RegExp(r'[,\s/]+'))
      .where((c) => c.isNotEmpty)
      .any((c) => _normClass(c) == want);
}

(int, int)? _range(String period) {
  final n = RegExp(
    r'\d+',
  ).allMatches(period).map((m) => int.parse(m[0]!)).toList();
  return n.isEmpty
      ? null
      : (n.reduce((a, b) => a < b ? a : b), n.reduce((a, b) => a > b ? a : b));
}

bool _overlap(String a, String b) {
  final ra = _range(a), rb = _range(b);
  return ra != null && rb != null && ra.$1 <= rb.$2 && rb.$1 <= ra.$2;
}

bool _blank(String? s) => s == null || s.trim().isEmpty;

/// [entry] of the Schulportal completed with what WebUntis knows about the
/// same lesson (the original teacher, the substitute, a room change, the
/// subject, a text) – only where the Schulportal has nothing. Null if
/// WebUntis adds nothing.
Substitution? _enrich(Substitution entry, UntisChange c) {
  final teacher = _blank(entry.teacher) ? c.teacher : null;
  final substitute = _blank(entry.substitute) ? c.substitute : null;
  final subject = _blank(entry.subject) ? c.subject : null;
  final note = _blank(entry.note) ? c.note : null;
  // Only a real room change: otherwise WebUntis' room is just the regular one.
  final roomChange =
      c.previousRoom != null &&
      _blank(entry.room) &&
      _blank(entry.previousRoom);
  if (teacher == null &&
      substitute == null &&
      subject == null &&
      note == null &&
      !roomChange) {
    return null;
  }
  return Substitution(
    period: entry.period,
    type: entry.type,
    subject: subject ?? entry.subject,
    previousSubject: entry.previousSubject,
    teacher: teacher ?? entry.teacher,
    substitute: substitute ?? entry.substitute,
    room: roomChange ? c.room : entry.room,
    previousRoom: roomChange ? c.previousRoom : entry.previousRoom,
    className: entry.className,
    note: note ?? entry.note,
    source: combinedSource,
  );
}

/// Combines the Schulportal plan with the WebUntis changes of the class.
///
/// An entry counts as the same lesson if the plan lists the same class on
/// the same day with overlapping periods. Then, with [enrich], the plan's
/// entry is completed with what only WebUntis knows (marked as
/// [combinedSource]). Changes the plan does not have are added, marked
/// `source: WebUntis`; days only WebUntis knows (after the end of the plan)
/// are added as new days.
///
/// Notifications use `enrich: false`: completing an entry would change its
/// fingerprint and notify the same lesson twice.
///
/// Returns [portal] itself if nothing changes.
List<SubstitutionDay> mergeUntis(
  List<SubstitutionDay> portal,
  UntisSnapshot? untis, {
  bool enrich = true,
}) {
  if (untis == null || untis.changes.isEmpty) return portal;
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  final entries = [
    for (final d in portal) [...d.entries],
  ];
  var changed = false;
  final extra = <DateTime, List<Substitution>>{};
  for (final c in untis.changes) {
    final period = c.period ?? '';
    var covered = false;
    for (final (i, d) in portal.indexed) {
      if (!sameDay(d.date, c.date)) continue;
      final at = entries[i].indexWhere(
        (e) =>
            _sameClass(e.className, untis.className) &&
            _overlap(e.period, period),
      );
      if (at < 0) continue;
      covered = true;
      if (enrich) {
        final better = _enrich(entries[i][at], c);
        if (better != null) {
          entries[i][at] = better;
          changed = true;
        }
      }
      break;
    }
    if (covered) continue;
    (extra[c.date] ??= []).add(
      Substitution(
        period: period,
        type: c.type,
        subject: c.subject,
        teacher: c.teacher,
        substitute: c.substitute,
        room: c.room,
        previousRoom: c.previousRoom,
        className: untis.className,
        note: c.note,
        source: 'WebUntis',
      ),
    );
  }
  if (extra.isEmpty && !changed) return portal;

  final days = [
    for (final (i, d) in portal.indexed)
      SubstitutionDay(
        date: d.date,
        entries: [
          ...entries[i],
          ...?extra.entries
              .where((e) => sameDay(e.key, d.date))
              .map((e) => e.value)
              .firstOrNull,
        ],
        notices: d.notices,
      ),
  ];
  for (final e in extra.entries) {
    if (!portal.any((d) => sameDay(d.date, e.key))) {
      days.add(
        SubstitutionDay(date: e.key, entries: e.value, notices: const []),
      );
    }
  }
  days.sort((a, b) => a.date.compareTo(b.date));
  return days;
}
