// Pure functions mapping liblanis models to app models.

import 'package:html_unescape/html_unescape.dart';
import 'package:liblanis/easy_client.dart' as lanis;

import '../models/models.dart';

final _unescape = HtmlUnescape();

/// Trimmed text, null if empty. For fields that may contain HTML markup
/// (descriptions, homework); the web UI converts those to text itself.
String? _clean(String? s) {
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Plain-text field: trimmed, HTML entities decoded ("&amp;" → "&"), null if
/// empty. The portal delivers some names and categories HTML-escaped.
String? _text(String? s) => _clean(s == null ? null : _unescape.convert(s));

/// Like [_text] for required fields.
String _name(String s) => _unescape.convert(s).trim();

final _leadingNumber = RegExp(r'^\s*(\d+)');

Timetable mapTimetable(lanis.TimeTable tt) {
  final slots = <TimeSlot>[];
  var counter = 0;
  for (final row in tt.hours ?? const <lanis.TimeTableRow>[]) {
    final isLesson = row.type == lanis.TimeTableRowType.lesson;
    int? period;
    if (isLesson) {
      counter++;
      final m = _leadingNumber.firstMatch(row.label);
      period = m != null ? int.parse(m.group(1)!) : counter;
    }
    slots.add(
      TimeSlot(
        period: period,
        label: _name(row.label),
        start: row.startTime.toString(),
        end: row.endTime.toString(),
      ),
    );
  }
  final periodByStart = {
    for (final s in slots)
      if (s.period != null) s.start: s.period,
  };

  final days = tt.planForOwn ?? tt.planForAll ?? const [];
  final lessons = <TimetableLesson>[];
  for (var i = 0; i < days.length; i++) {
    for (final s in days[i]) {
      lessons.add(
        TimetableLesson(
          weekday: i + 1,
          period: periodByStart[s.startTime.toString()],
          duration: s.duration,
          start: s.startTime.toString(),
          end: s.endTime.toString(),
          subject: _text(s.name),
          room: _text(s.raum),
          teacher: _text(s.lehrer),
          week: _text(s.badge),
        ),
      );
    }
  }
  lessons.sort((a, b) {
    final d = a.weekday.compareTo(b.weekday);
    return d != 0 ? d : a.start.compareTo(b.start);
  });
  return Timetable(
    currentWeek: _text(tt.weekBadge),
    slots: slots,
    lessons: lessons,
  );
}

List<SubstitutionDay> mapSubstitutions(lanis.SubstitutionPlan plan) {
  final days = [
    for (final d in plan.days)
      SubstitutionDay(
        date: d.dateTime,
        entries: [
          for (final s in d.substitutions)
            Substitution(
              period: s.stunde.trim(),
              type: _text(s.art),
              subject: _text(s.fach),
              previousSubject: _text(s.fach_alt),
              teacher: _text(s.lehrer),
              substitute: _text(s.vertreter),
              room: _text(s.raum),
              previousRoom: _text(s.raum_alt),
              className: _text(s.klasse),
              note: [_text(s.hinweis), _text(s.hinweis2)]
                  .whereType<String>()
                  .join(' – ')
                  .let((n) => n.isEmpty ? null : n),
            ),
        ],
        notices: [
          for (final info in d.infos ?? const <lanis.SubstitutionInfo>[])
            SubstitutionNotice(title: _name(info.header), lines: info.values),
        ],
      ),
  ];
  days.sort((a, b) => a.date.compareTo(b.date));
  return days;
}

List<CalendarEntry> mapCalendar(List<lanis.CalendarEvent> events) {
  final entries = [
    for (final e in events)
      CalendarEntry(
        id: e.id,
        title: _name(e.title),
        description: e.description.trim(),
        start: e.startTime,
        end: e.endTime,
        allDay: e.allDay,
        place: _text(e.place),
        category: _text(e.category?.name),
      ),
  ];
  entries.sort((a, b) => a.start.compareTo(b.start));
  return entries;
}

List<String> _teachers(List<lanis.LessonTeacher> teachers) => [
  for (final t in teachers) ?(_text(t.teacher) ?? _text(t.teacherKuerzel)),
];

/// Id of a course as Lumo uses it (paths, cache keys, settings): letters,
/// digits, `_` and `-`. Student accounts have plain numbers; the course links
/// of a parent account also carry the pupil (`123&p=456`), which becomes
/// `123-p-456`.
String courseKey(String portalId) =>
    portalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');

Course mapCourse(lanis.Lesson l) => Course(
  id: courseKey(l.courseID),
  name: _name(l.name),
  teachers: _teachers(l.teachers),
);

/// Current homework (one per course at most) from the lessons overview.
List<Homework> mapCurrentHomework(lanis.Lessons lessons) => [
  for (final l in lessons)
    if (l.currentEntry case final entry?)
      if (entry.homework case final hw?)
        if (_clean(hw.description) case final text?)
          Homework(
            courseId: courseKey(l.courseID),
            courseName: _name(l.name),
            entryId: entry.entryID,
            date: entry.topicDate,
            topic: _text(entry.topicTitle),
            description: text,
            done: hw.homeWorkDone,
          ),
];

/// All homework of one course from its lesson history (newest first).
List<Homework> mapHomeworkHistory(lanis.Lesson l, lanis.DetailedLesson d) {
  final items = <Homework>[
    for (final e in d.history)
      if (e.homework case final hw?)
        if (_clean(hw.description) case final text?)
          Homework(
            courseId: courseKey(l.courseID),
            courseName: _name(l.name),
            entryId: e.entryID,
            date: e.topicDate,
            topic: _text(e.topicTitle),
            description: text,
            done: hw.homeWorkDone,
          ),
  ];
  items.sort(
    (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
  );
  return items;
}

LessonEntry _mapEntry(lanis.CurrentEntry e) => LessonEntry(
  id: e.entryID,
  date: e.topicDate,
  periods: _text(e.schoolHours),
  topic: _text(e.topicTitle),
  description: _clean(e.description),
  homework: _clean(e.homework?.description),
  homeworkDone: e.homework?.homeWorkDone ?? false,
  attendance: _text(e.presence),
);

List<Grade> _grades(lanis.DetailedLesson d) => [
  for (final m in d.marks)
    Grade(
      name: _name(m.name),
      date: _name(m.date),
      mark: _name(m.mark),
      comment: _text(m.comment),
    ),
];

List<Exam> _exams(lanis.DetailedLesson d) => [
  for (final x in d.exams) Exam(name: _name(x.name), value: _text(x.value)),
];

CourseDetails mapCourseDetails(lanis.DetailedLesson d) => CourseDetails(
  course: Course(
    id: courseKey(d.courseID),
    name: _name(d.name),
    teachers: _teachers(d.teachers),
  ),
  history: [for (final e in d.history) _mapEntry(e)],
  grades: _grades(d),
  exams: _exams(d),
  attendance: {
    for (final MapEntry(:key, :value) in d.attendances.entries)
      _name(key): _name(value),
  },
);

CourseGrades mapCourseGrades(Course course, lanis.DetailedLesson d) =>
    CourseGrades(course: course, grades: _grades(d), exams: _exams(d));

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
