// App-level data models.
//
// These are independent of liblanis so the REST API and frontend do not break
// when liblanis changes. All models are immutable and JSON-serialisable.

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime? _parseDate(Object? v) => v is String ? DateTime.parse(v) : null;

List<T> _list<T>(Object? v, T Function(Map<String, Object?>) f) => [
  for (final e in (v as List? ?? const []))
    f((e as Map).cast<String, Object?>()),
];

List<String> _strings(Object? v) => [
  for (final e in (v as List? ?? const [])) e as String,
];

/// Features (SPH applets) the app knows about.
enum SphFeature {
  timetable('stundenplan.php'),
  substitutions('vertretungsplan.php'),
  calendar('kalender.php'),
  lessons('meinunterricht.php'),
  messages('nachrichten.php');

  const SphFeature(this.applet);

  /// PHP page name of the applet in Schulportal Hessen.
  final String applet;
}

class AccountInfo {
  final int schoolId;
  final String username;
  final String? accountType;
  final Set<SphFeature> features;

  const AccountInfo({
    required this.schoolId,
    required this.username,
    required this.accountType,
    required this.features,
  });

  factory AccountInfo.fromJson(Map<String, Object?> j) => AccountInfo(
    schoolId: j['schoolId'] as int,
    username: j['username'] as String,
    accountType: j['accountType'] as String?,
    features: {
      for (final f in _strings(j['features']))
        ...SphFeature.values.where((v) => v.name == f),
    },
  );

  Map<String, Object?> toJson() => {
    'schoolId': schoolId,
    'username': username,
    'accountType': accountType,
    'features': [for (final f in features) f.name],
  };
}

class TimetableLesson {
  /// 1 = Monday … 5 = Friday.
  final int weekday;

  /// Period number of the first lesson period (1, 2, …), if known.
  final int? period;

  /// Number of consecutive periods.
  final int duration;

  /// "HH:MM"
  final String start;
  final String end;
  final String? subject;
  final String? room;
  final String? teacher;

  /// Week marker such as "A" or "B" for alternating timetables.
  final String? week;

  const TimetableLesson({
    required this.weekday,
    required this.period,
    required this.duration,
    required this.start,
    required this.end,
    required this.subject,
    required this.room,
    required this.teacher,
    required this.week,
  });

  factory TimetableLesson.fromJson(Map<String, Object?> j) => TimetableLesson(
    weekday: j['weekday'] as int,
    period: j['period'] as int?,
    duration: j['duration'] as int,
    start: j['start'] as String,
    end: j['end'] as String,
    subject: j['subject'] as String?,
    room: j['room'] as String?,
    teacher: j['teacher'] as String?,
    week: j['week'] as String?,
  );

  Map<String, Object?> toJson() => {
    'weekday': weekday,
    'period': period,
    'duration': duration,
    'start': start,
    'end': end,
    'subject': subject,
    'room': room,
    'teacher': teacher,
    'week': week,
  };
}

/// A row of the timetable grid: a lesson period or a break.
class TimeSlot {
  /// Period number for lessons (1, 2, …); null for breaks.
  final int? period;
  final String label;

  /// "HH:MM"
  final String start;
  final String end;

  const TimeSlot({
    required this.period,
    required this.label,
    required this.start,
    required this.end,
  });

  bool get isBreak => period == null;

  factory TimeSlot.fromJson(Map<String, Object?> j) => TimeSlot(
    period: j['period'] as int?,
    label: j['label'] as String,
    start: j['start'] as String,
    end: j['end'] as String,
  );

  Map<String, Object?> toJson() => {
    'period': period,
    'label': label,
    'start': start,
    'end': end,
  };
}

class Timetable {
  /// Current week marker ("A"/"B"), if the school uses alternating weeks.
  final String? currentWeek;
  final List<TimeSlot> slots;
  final List<TimetableLesson> lessons;

  const Timetable({
    required this.currentWeek,
    required this.slots,
    required this.lessons,
  });

  factory Timetable.fromJson(Map<String, Object?> j) => Timetable(
    currentWeek: j['currentWeek'] as String?,
    slots: _list(j['slots'], TimeSlot.fromJson),
    lessons: _list(j['lessons'], TimetableLesson.fromJson),
  );

  Map<String, Object?> toJson() => {
    'currentWeek': currentWeek,
    'slots': [for (final s in slots) s.toJson()],
    'lessons': [for (final l in lessons) l.toJson()],
  };
}

class Substitution {
  final String period;
  final String? type;
  final String? subject;
  final String? previousSubject;
  final String? teacher;
  final String? substitute;
  final String? room;
  final String? previousRoom;
  final String? className;
  final String? note;

  /// Where the entry comes from when not the Schulportal ("WebUntis").
  final String? source;

  const Substitution({
    required this.period,
    this.type,
    this.subject,
    this.previousSubject,
    this.teacher,
    this.substitute,
    this.room,
    this.previousRoom,
    this.className,
    this.note,
    this.source,
  });

  factory Substitution.fromJson(Map<String, Object?> j) => Substitution(
    period: j['period'] as String,
    type: j['type'] as String?,
    subject: j['subject'] as String?,
    previousSubject: j['previousSubject'] as String?,
    teacher: j['teacher'] as String?,
    substitute: j['substitute'] as String?,
    room: j['room'] as String?,
    previousRoom: j['previousRoom'] as String?,
    className: j['className'] as String?,
    note: j['note'] as String?,
    source: j['source'] as String?,
  );

  Map<String, Object?> toJson() => {
    'period': period,
    'type': type,
    'subject': subject,
    'previousSubject': previousSubject,
    'teacher': teacher,
    'substitute': substitute,
    'room': room,
    'previousRoom': previousRoom,
    'className': className,
    'note': note,
    if (source != null) 'source': source,
  };
}

class SubstitutionNotice {
  final String title;

  /// Lines as delivered by SPH (may contain simple HTML).
  final List<String> lines;

  const SubstitutionNotice({required this.title, required this.lines});

  factory SubstitutionNotice.fromJson(Map<String, Object?> j) =>
      SubstitutionNotice(
        title: j['title'] as String,
        lines: _strings(j['lines']),
      );

  Map<String, Object?> toJson() => {'title': title, 'lines': lines};
}

class SubstitutionDay {
  final DateTime date;
  final List<Substitution> entries;
  final List<SubstitutionNotice> notices;

  const SubstitutionDay({
    required this.date,
    required this.entries,
    required this.notices,
  });

  factory SubstitutionDay.fromJson(Map<String, Object?> j) => SubstitutionDay(
    date: _parseDate(j['date'])!,
    entries: _list(j['entries'], Substitution.fromJson),
    notices: _list(j['notices'], SubstitutionNotice.fromJson),
  );

  Map<String, Object?> toJson() => {
    'date': _date(date),
    'entries': [for (final e in entries) e.toJson()],
    'notices': [for (final n in notices) n.toJson()],
  };
}

class CalendarEntry {
  final String id;
  final String title;
  final String description;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? place;
  final String? category;

  const CalendarEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.start,
    required this.end,
    required this.allDay,
    this.place,
    this.category,
  });

  factory CalendarEntry.fromJson(Map<String, Object?> j) => CalendarEntry(
    id: j['id'] as String,
    title: j['title'] as String,
    description: j['description'] as String,
    start: _parseDate(j['start'])!,
    end: _parseDate(j['end'])!,
    allDay: j['allDay'] as bool,
    place: j['place'] as String?,
    category: j['category'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'allDay': allDay,
    'place': place,
    'category': category,
  };
}

class Course {
  final String id;
  final String name;
  final List<String> teachers;

  const Course({required this.id, required this.name, required this.teachers});

  factory Course.fromJson(Map<String, Object?> j) => Course(
    id: j['id'] as String,
    name: j['name'] as String,
    teachers: _strings(j['teachers']),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'teachers': teachers,
  };
}

class Homework {
  final String courseId;
  final String courseName;
  final String entryId;
  final DateTime? date;
  final String? topic;
  final String description;
  final bool done;

  const Homework({
    required this.courseId,
    required this.courseName,
    required this.entryId,
    required this.date,
    required this.topic,
    required this.description,
    required this.done,
  });

  Homework withDone(bool value) => Homework(
    courseId: courseId,
    courseName: courseName,
    entryId: entryId,
    date: date,
    topic: topic,
    description: description,
    done: value,
  );

  factory Homework.fromJson(Map<String, Object?> j) => Homework(
    courseId: j['courseId'] as String,
    courseName: j['courseName'] as String,
    entryId: j['entryId'] as String,
    date: _parseDate(j['date']),
    topic: j['topic'] as String?,
    description: j['description'] as String,
    done: j['done'] as bool,
  );

  Map<String, Object?> toJson() => {
    'courseId': courseId,
    'courseName': courseName,
    'entryId': entryId,
    'date': date == null ? null : _date(date!),
    'topic': topic,
    'description': description,
    'done': done,
  };
}

class LessonEntry {
  final String id;
  final DateTime? date;
  final String? periods;
  final String? topic;
  final String? description;
  final String? homework;
  final bool homeworkDone;
  final String? attendance;

  const LessonEntry({
    required this.id,
    this.date,
    this.periods,
    this.topic,
    this.description,
    this.homework,
    this.homeworkDone = false,
    this.attendance,
  });

  LessonEntry withHomeworkDone(bool value) => LessonEntry(
    id: id,
    date: date,
    periods: periods,
    topic: topic,
    description: description,
    homework: homework,
    homeworkDone: value,
    attendance: attendance,
  );

  factory LessonEntry.fromJson(Map<String, Object?> j) => LessonEntry(
    id: j['id'] as String,
    date: _parseDate(j['date']),
    periods: j['periods'] as String?,
    topic: j['topic'] as String?,
    description: j['description'] as String?,
    homework: j['homework'] as String?,
    homeworkDone: j['homeworkDone'] as bool? ?? false,
    attendance: j['attendance'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'date': date == null ? null : _date(date!),
    'periods': periods,
    'topic': topic,
    'description': description,
    'homework': homework,
    'homeworkDone': homeworkDone,
    'attendance': attendance,
  };
}

class Grade {
  final String name;

  /// Date as delivered by SPH (format varies by school, e.g. "12.09.2026").
  final String date;
  final String mark;
  final String? comment;

  const Grade({
    required this.name,
    required this.date,
    required this.mark,
    this.comment,
  });

  factory Grade.fromJson(Map<String, Object?> j) => Grade(
    name: j['name'] as String,
    date: j['date'] as String,
    mark: j['mark'] as String,
    comment: j['comment'] as String?,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'date': date,
    'mark': mark,
    'comment': comment,
  };
}

class Exam {
  final String name;
  final String? value;

  const Exam({required this.name, this.value});

  factory Exam.fromJson(Map<String, Object?> j) =>
      Exam(name: j['name'] as String, value: j['value'] as String?);

  Map<String, Object?> toJson() => {'name': name, 'value': value};
}

class CourseDetails {
  final Course course;
  final List<LessonEntry> history;
  final List<Grade> grades;
  final List<Exam> exams;
  final Map<String, String> attendance;

  const CourseDetails({
    required this.course,
    required this.history,
    required this.grades,
    required this.exams,
    required this.attendance,
  });

  CourseDetails withHistory(List<LessonEntry> value) => CourseDetails(
    course: course,
    history: value,
    grades: grades,
    exams: exams,
    attendance: attendance,
  );

  factory CourseDetails.fromJson(Map<String, Object?> j) => CourseDetails(
    course: Course.fromJson((j['course'] as Map).cast()),
    history: _list(j['history'], LessonEntry.fromJson),
    grades: _list(j['grades'], Grade.fromJson),
    exams: _list(j['exams'], Exam.fromJson),
    attendance: (j['attendance'] as Map? ?? const {}).cast<String, String>(),
  );

  Map<String, Object?> toJson() => {
    'course': course.toJson(),
    'history': [for (final h in history) h.toJson()],
    'grades': [for (final g in grades) g.toJson()],
    'exams': [for (final e in exams) e.toJson()],
    'attendance': attendance,
  };
}

/// Grades and exams of one course (used for the grades overview).
class CourseGrades {
  final Course course;
  final List<Grade> grades;
  final List<Exam> exams;

  const CourseGrades({
    required this.course,
    required this.grades,
    required this.exams,
  });

  factory CourseGrades.fromJson(Map<String, Object?> j) => CourseGrades(
    course: Course.fromJson((j['course'] as Map).cast()),
    grades: _list(j['grades'], Grade.fromJson),
    exams: _list(j['exams'], Exam.fromJson),
  );

  Map<String, Object?> toJson() => {
    'course': course.toJson(),
    'grades': [for (final g in grades) g.toJson()],
    'exams': [for (final e in exams) e.toJson()],
  };
}
