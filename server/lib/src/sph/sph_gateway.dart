import 'package:liblanis/easy_client.dart' as lanis;

/// Thin seam over liblanis so [SphService] can be tested without network.
///
/// Implementations only forward calls; retry, session and error policy live
/// in [SphService].
abstract interface class SphGateway {
  int get schoolId;
  String get username;

  bool get isLoggedIn;

  /// Logs in (replacing any existing session).
  Future<void> login();

  Future<void> logout();

  /// PHP applet names enabled for the logged-in account.
  Set<String> get enabledApplets;

  /// "student", "parent" or "teacher" once logged in.
  String? get accountType;

  Future<lanis.TimeTable> timetable();
  Future<lanis.SubstitutionPlan> substitutions();
  Future<List<lanis.CalendarEvent>> calendar(DateTime from, DateTime to);
  Future<lanis.Lessons> lessons();
  Future<lanis.DetailedLesson> lessonDetails(Uri courseUrl);

  /// Marks homework of a lesson entry as done/undone. Returns the portal's
  /// raw answer ("1" = success).
  Future<String> setHomeworkDone(String courseId, String entryId, bool done);

  Future<void> dispose();
}
