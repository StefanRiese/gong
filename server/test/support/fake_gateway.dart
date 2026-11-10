import 'dart:async';

import 'package:liblanis/easy_client.dart' as lanis;
import 'package:lumo_server/lumo_server.dart';

/// In-memory [SphGateway] with scriptable failures.
class FakeGateway implements SphGateway {
  @override
  final int schoolId = 6128;
  @override
  final String username = 'test.user';

  Set<String> applets = {
    'stundenplan.php',
    'vertretungsplan.php',
    'kalender.php',
    'meinunterricht.php',
  };

  bool _loggedIn = false;
  int loginCalls = 0;
  int logoutCalls = 0;
  int lessonDetailCalls = 0;
  bool disposed = false;

  /// Errors thrown by the next login calls (consumed in order).
  final List<Object> loginErrors = [];

  /// Errors thrown by the next data calls (consumed in order).
  final List<Object> dataErrors = [];

  /// Completes login only when set and completed (to test concurrency).
  Completer<void>? loginGate;

  lanis.TimeTable timetableData = sampleTimetable();
  lanis.SubstitutionPlan substitutionData = sampleSubstitutions();
  List<lanis.CalendarEvent> calendarData = sampleCalendar();
  lanis.Lessons lessonsData = sampleLessons();
  DateTime? lastCalendarFrom;
  DateTime? lastCalendarTo;

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  Future<void> login() async {
    loginCalls++;
    _loggedIn = false;
    if (loginGate != null) await loginGate!.future;
    if (loginErrors.isNotEmpty) throw loginErrors.removeAt(0);
    _loggedIn = true;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    _loggedIn = false;
  }

  /// Simulates the portal session expiring server-side.
  void expireSession() => dataErrors.add(lanis.UnauthorizedException());

  @override
  Set<String> get enabledApplets => _loggedIn ? applets : const {};

  @override
  String? get accountType => _loggedIn ? 'student' : null;

  Future<T> _data<T>(T value) async {
    if (!_loggedIn) throw lanis.UnauthorizedException('not logged in');
    if (dataErrors.isNotEmpty) throw dataErrors.removeAt(0);
    return value;
  }

  @override
  Future<lanis.TimeTable> timetable() => _data(timetableData);

  @override
  Future<lanis.SubstitutionPlan> substitutions() => _data(substitutionData);

  @override
  Future<List<lanis.CalendarEvent>> calendar(DateTime from, DateTime to) {
    lastCalendarFrom = from;
    lastCalendarTo = to;
    return _data(calendarData);
  }

  @override
  Future<lanis.Lessons> lessons() => _data(lessonsData);

  @override
  Future<lanis.DetailedLesson> lessonDetails(Uri courseUrl) {
    lessonDetailCalls++;
    final id = courseUrl.queryParameters['id']!;
    final lesson = lessonsData.firstWhere((l) => l.courseID == id);
    return _data(sampleDetails(lesson));
  }

  /// Calls to setHomeworkDone as (courseId, entryId, done).
  final homeworkCalls = <(String, String, bool)>[];

  /// Answer of the portal for setHomeworkDone.
  String homeworkAnswer = '1';

  @override
  Future<String> setHomeworkDone(
    String courseId,
    String entryId,
    bool done,
  ) async {
    await _data(null);
    homeworkCalls.add((courseId, entryId, done));
    for (final l in lessonsData) {
      final e = l.currentEntry;
      if (l.courseID == courseId &&
          e?.entryID == entryId &&
          e?.homework != null) {
        e!.homework!.homeWorkDone = done;
      }
    }
    return homeworkAnswer;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

lanis.SphTimeOfDay t(int h, int m) => lanis.SphTimeOfDay(hour: h, minute: m);

lanis.TimeTable sampleTimetable() {
  lanis.TimetableSubject subject(
    String name,
    lanis.SphTimeOfDay start,
    lanis.SphTimeOfDay end, {
    int duration = 1,
    String? badge,
  }) => lanis.TimetableSubject(
    id: name,
    name: name,
    raum: ' R101 ',
    lehrer: 'MÜL',
    badge: badge,
    duration: duration,
    startTime: start,
    endTime: end,
    stunde: 7, // raw table row index, must not be used as period
  );

  return lanis.TimeTable(
    weekBadge: 'B',
    hours: [
      lanis.TimeTableRow(
        lanis.TimeTableRowType.lesson,
        t(8, 0),
        t(8, 45),
        '1. Stunde',
        1,
      ),
      lanis.TimeTableRow(
        lanis.TimeTableRowType.lesson,
        t(8, 50),
        t(9, 35),
        '2. Stunde',
        2,
      ),
      lanis.TimeTableRow(
        lanis.TimeTableRowType.pause,
        t(9, 35),
        t(9, 55),
        'Pause',
        3,
      ),
      lanis.TimeTableRow(
        lanis.TimeTableRowType.lesson,
        t(9, 55),
        t(10, 40),
        '3. Stunde',
        4,
      ),
    ],
    planForOwn: [
      [
        subject('Mathe', t(8, 50), t(9, 35)),
        subject('Deutsch', t(8, 0), t(8, 45)),
      ],
      [subject('Sport', t(8, 0), t(9, 35), duration: 2, badge: 'A')],
    ],
  );
}

lanis.SubstitutionPlan sampleSubstitutions() => lanis.SubstitutionPlan(
  days: [
    lanis.SubstitutionDay(
      parsedDate: '11.11.2026',
      substitutions: [
        lanis.Substitution(
          tag: 'Mittwoch',
          tag_en: 'Wednesday',
          stunde: ' 3 ',
          fach: 'M',
          art: 'Vertretung',
          vertreter: 'SCH',
          raum: 'R2',
          raum_alt: 'R1',
          hinweis: 'Buch mitbringen',
          hinweis2: '',
          klasse: '05eG',
        ),
        lanis.Substitution(
          tag: 'Mittwoch',
          tag_en: 'Wednesday',
          stunde: '5',
          fach: 'D',
          art: 'Fällt aus',
          klasse: '07aG, 07bG',
        ),
        lanis.Substitution(
          tag: 'Mittwoch',
          tag_en: 'Wednesday',
          stunde: '2',
          art: 'Pausenaufsicht',
        ),
      ],
      infos: [
        lanis.SubstitutionInfo(header: 'Allgemein', values: ['Wandertag 7b']),
      ],
    ),
    lanis.SubstitutionDay(parsedDate: '10.11.2026'),
  ],
);

List<lanis.CalendarEvent> sampleCalendar() => [
  lanis.CalendarEvent(
    id: '2',
    title: ' Elternabend ',
    description: '',
    startTime: DateTime(2026, 11, 20, 19),
    endTime: DateTime(2026, 11, 20, 21),
    allDay: false,
    secret: false,
    isNew: false,
    public: true,
    private: false,
    place: 'Aula',
    category: lanis.CalendarEventCategory(id: 1, colorArgb: 0, name: 'Termine'),
  ),
  lanis.CalendarEvent(
    id: '1',
    title: 'Ferien',
    description: 'Herbstferien',
    startTime: DateTime(2026, 11, 12),
    endTime: DateTime(2026, 11, 13),
    allDay: true,
    secret: false,
    isNew: false,
    public: true,
    private: false,
  ),
];

lanis.Lessons sampleLessons() => [
  lanis.Lesson(
    courseID: '100',
    name: 'Mathematik ',
    courseURL: Uri.parse(
      'https://start.schulportal.hessen.de/meinunterricht.php?a=sus_view&id=100',
    ),
    teachers: [lanis.LessonTeacher(teacher: 'Müller', teacherKuerzel: 'MÜL')],
    currentEntry: lanis.CurrentEntry(
      entryID: 'e1',
      files: [],
      uploads: [],
      topicTitle: 'Brüche',
      topicDate: DateTime(2026, 11, 9),
      homework: lanis.Homework(
        description: ' S. 12 Nr. 3 ',
        homeWorkDone: false,
      ),
    ),
  ),
  lanis.Lesson(
    courseID: '200',
    name: 'Englisch',
    courseURL: Uri.parse(
      'https://start.schulportal.hessen.de/meinunterricht.php?a=sus_view&id=200',
    ),
    teachers: [lanis.LessonTeacher(teacherKuerzel: 'SMI')],
    currentEntry: lanis.CurrentEntry(
      entryID: 'e2',
      files: [],
      uploads: [],
      homework: lanis.Homework(description: '   ', homeWorkDone: false),
    ),
  ),
];

lanis.DetailedLesson sampleDetails(lanis.Lesson l) => lanis.DetailedLesson(
  courseID: l.courseID,
  name: l.name,
  teachers: l.teachers,
  history: [if (l.currentEntry != null) l.currentEntry!],
  marks: [lanis.LessonMark(name: 'Test 1', date: '01.10.2026', mark: ' 2+ ')],
  exams: [lanis.LessonExam(name: 'Klassenarbeit 1', value: '15.12.2026')],
  attendances: {'fehlende Stunden': '0'},
);
