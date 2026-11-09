// Pure functions mapping liblanis models to app models.

import 'package:liblanis/easy_client.dart' as lanis;

import '../models/models.dart';

String? _clean(String? s) {
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

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
        label: row.label.trim(),
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
          subject: _clean(s.name),
          room: _clean(s.raum),
          teacher: _clean(s.lehrer),
          week: _clean(s.badge),
        ),
      );
    }
  }
  lessons.sort((a, b) {
    final d = a.weekday.compareTo(b.weekday);
    return d != 0 ? d : a.start.compareTo(b.start);
  });
  return Timetable(
    currentWeek: _clean(tt.weekBadge),
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
              type: _clean(s.art),
              subject: _clean(s.fach),
              previousSubject: _clean(s.fach_alt),
              teacher: _clean(s.lehrer),
              substitute: _clean(s.vertreter),
              room: _clean(s.raum),
              previousRoom: _clean(s.raum_alt),
              className: _clean(s.klasse),
              note: [_clean(s.hinweis), _clean(s.hinweis2)]
                  .whereType<String>()
                  .join(' – ')
                  .let((n) => n.isEmpty ? null : n),
            ),
        ],
        notices: [
          for (final info in d.infos ?? const <lanis.SubstitutionInfo>[])
            SubstitutionNotice(title: info.header, lines: info.values),
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
        title: e.title.trim(),
        description: e.description.trim(),
        start: e.startTime,
        end: e.endTime,
        allDay: e.allDay,
        place: _clean(e.place),
        category: _clean(e.category?.name),
      ),
  ];
  entries.sort((a, b) => a.start.compareTo(b.start));
  return entries;
}

List<String> _teachers(List<lanis.LessonTeacher> teachers) => [
  for (final t in teachers) ?(_clean(t.teacher) ?? _clean(t.teacherKuerzel)),
];

Course mapCourse(lanis.Lesson l) => Course(
  id: l.courseID,
  name: l.name.trim(),
  teachers: _teachers(l.teachers),
);

/// Current homework (one per course at most) from the lessons overview.
List<Homework> mapCurrentHomework(lanis.Lessons lessons) => [
  for (final l in lessons)
    if (l.currentEntry case final entry?)
      if (entry.homework case final hw?)
        if (_clean(hw.description) case final text?)
          Homework(
            courseId: l.courseID,
            courseName: l.name.trim(),
            entryId: entry.entryID,
            date: entry.topicDate,
            topic: _clean(entry.topicTitle),
            description: text,
            done: hw.homeWorkDone,
          ),
];

LessonEntry _mapEntry(lanis.CurrentEntry e) => LessonEntry(
  id: e.entryID,
  date: e.topicDate,
  periods: _clean(e.schoolHours),
  topic: _clean(e.topicTitle),
  description: _clean(e.description),
  homework: _clean(e.homework?.description),
  homeworkDone: e.homework?.homeWorkDone ?? false,
  attendance: _clean(e.presence),
);

List<Grade> _grades(lanis.DetailedLesson d) => [
  for (final m in d.marks)
    Grade(
      name: m.name.trim(),
      date: m.date.trim(),
      mark: m.mark.trim(),
      comment: _clean(m.comment),
    ),
];

List<Exam> _exams(lanis.DetailedLesson d) => [
  for (final x in d.exams) Exam(name: x.name.trim(), value: _clean(x.value)),
];

CourseDetails mapCourseDetails(lanis.DetailedLesson d) => CourseDetails(
  course: Course(
    id: d.courseID,
    name: d.name.trim(),
    teachers: _teachers(d.teachers),
  ),
  history: [for (final e in d.history) _mapEntry(e)],
  grades: _grades(d),
  exams: _exams(d),
  attendance: d.attendances,
);

CourseGrades mapCourseGrades(Course course, lanis.DetailedLesson d) =>
    CourseGrades(course: course, grades: _grades(d), exams: _exams(d));

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
