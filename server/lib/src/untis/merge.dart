import '../models/models.dart';
import 'untis.dart';

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

/// Adds the WebUntis changes that the Schulportal plan does not have: an
/// entry counts as covered if the plan lists the same class on the same day
/// with overlapping periods. Added entries are marked `source: WebUntis`;
/// days only WebUntis knows (after the end of the plan) are added.
/// Returns [portal] itself if nothing is added.
List<SubstitutionDay> mergeUntis(
  List<SubstitutionDay> portal,
  UntisSnapshot? untis,
) {
  if (untis == null || untis.changes.isEmpty) return portal;
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  final extra = <DateTime, List<Substitution>>{};
  for (final c in untis.changes) {
    final period = c.period ?? '';
    final covered = portal.any(
      (d) =>
          sameDay(d.date, c.date) &&
          d.entries.any(
            (e) =>
                _sameClass(e.className, untis.className) &&
                _overlap(e.period, period),
          ),
    );
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
  if (extra.isEmpty) return portal;

  final days = [
    for (final d in portal)
      SubstitutionDay(
        date: d.date,
        entries: [
          ...d.entries,
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
