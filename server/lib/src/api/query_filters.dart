import '../models/models.dart';
import '../storage/settings_store.dart';

/// Filters from URL parameters, the same as on the web UI pages, so a page
/// URL like `/kalender?suche=05eg` works as `/api/calendar?suche=05eg`.
///
/// The search compares case-insensitively and looks for the whole text in
/// any of the fields (like the web UI).
bool textMatches(Iterable<String?> fields, String? query) {
  final q = query?.trim().toLowerCase() ?? '';
  if (q.isEmpty) return true;
  return fields.any((f) => f != null && f.toLowerCase().contains(q));
}

/// Comma-separated list parameter: "Entfall, Fällt aus" → [entfall, fällt aus].
List<String> _list(String? value) => [
  for (final v in (value ?? '').split(','))
    if (v.trim().isNotEmpty) v.trim().toLowerCase(),
];

DateTime? _date(Map<String, String> q, String key) {
  final v = q[key];
  if (v == null || v.isEmpty) return null;
  final d = DateTime.tryParse(v);
  if (d == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v)) {
    throw ArgumentError('$key must be YYYY-MM-DD');
  }
  return DateTime(d.year, d.month, d.day);
}

/// Substitutions: `klasse` (classes, comma-separated, exact), `art` (only
/// these types), `ohne_art` (without these types), `suche` (text),
/// `von` / `bis` (days, YYYY-MM-DD). Null if no parameter is given.
List<SubstitutionDay>? filterSubstitutionsByQuery(
  List<SubstitutionDay> days,
  Map<String, String> q,
) {
  final classes = _list(q['klasse']);
  final types = _list(q['art']);
  final withoutTypes = _list(q['ohne_art']);
  final search = q['suche'];
  final from = _date(q, 'von');
  final to = _date(q, 'bis');
  if (classes.isEmpty &&
      types.isEmpty &&
      withoutTypes.isEmpty &&
      (search?.trim() ?? '').isEmpty &&
      from == null &&
      to == null) {
    return null;
  }

  bool keep(Substitution s) {
    final type = (s.type ?? '').trim().toLowerCase();
    if (types.isNotEmpty && !types.contains(type)) return false;
    if (withoutTypes.contains(type)) return false;
    if (classes.isNotEmpty &&
        !SubstitutionFilter.classesOf(
          s.className,
        ).any((c) => classes.contains(c.toLowerCase()))) {
      return false;
    }
    return textMatches([
      s.period,
      s.type,
      s.subject,
      s.previousSubject,
      s.teacher,
      s.substitute,
      s.room,
      s.previousRoom,
      s.className,
      s.note,
    ], search);
  }

  return [
    for (final d in days)
      if ((from == null || !d.date.isBefore(from)) &&
          (to == null || !d.date.isAfter(to)))
        SubstitutionDay(
          date: d.date,
          entries: d.entries.where(keep).toList(),
          notices: d.notices,
        ),
  ];
}

/// Calendar: `suche` in title, description, place and category;
/// `kategorie` (comma-separated) keeps entries whose category contains one
/// of the names, e.g. `kategorie=Klausuren,Arbeiten`.
List<CalendarEntry>? filterCalendarByQuery(
  List<CalendarEntry> entries,
  Map<String, String> q,
) {
  final search = q['suche'];
  final categories = _list(q['kategorie']);
  if ((search?.trim() ?? '').isEmpty && categories.isEmpty) return null;
  bool inCategory(CalendarEntry e) {
    if (categories.isEmpty) return true;
    final c = (e.category ?? '').toLowerCase();
    return categories.any(c.contains);
  }

  return [
    for (final e in entries)
      if (inCategory(e) &&
          textMatches([e.title, e.description, e.place, e.category], search))
        e,
  ];
}

/// Homework: `suche` in course, topic and description.
List<Homework>? filterHomeworkByQuery(
  List<Homework> items,
  Map<String, String> q,
) {
  final search = q['suche'];
  if ((search?.trim() ?? '').isEmpty) return null;
  return [
    for (final h in items)
      if (textMatches([h.courseName, h.topic, h.description], search)) h,
  ];
}
