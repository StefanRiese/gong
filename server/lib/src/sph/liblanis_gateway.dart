import 'package:liblanis/easy_client.dart' as lanis;

import 'sph_gateway.dart';

/// [SphGateway] backed by liblanis' [lanis.EasyLanisClient].
class LiblanisGateway implements SphGateway {
  @override
  final int schoolId;
  @override
  final String username;

  /// Keep liblanis' 10-second keep-alive ping running. Off by default: the
  /// service logs out when idle and re-logs in on demand instead of pinging
  /// the portal around the clock.
  final bool keepAlive;

  final lanis.EasyLanisClient _client;

  LiblanisGateway({
    required this.schoolId,
    required this.username,
    required String password,
    String userAgent = 'schulportal-client/0.1',
    this.keepAlive = false,
  }) : _client = lanis.EasyLanisClient.ephemeral(
         schoolId: schoolId,
         username: username,
         password: password,
         userAgent: userAgent,
       );

  @override
  bool get isLoggedIn => _client.isAuthenticated;

  @override
  Future<void> login() async {
    await _client.login();
    if (!keepAlive) _client.session?.preventLogoutTimer?.cancel();
  }

  @override
  Future<void> logout() => _client.logout();

  @override
  Set<String> get enabledApplets => _client.supportedApplets;

  @override
  String? get accountType => _client.session?.accountTypeOrNull?.name;

  @override
  Future<lanis.TimeTable> timetable() => _client.parsers.timetable.getHome();

  @override
  Future<lanis.SubstitutionPlan> substitutions() =>
      _client.parsers.substitutions.getHome();

  @override
  Future<List<lanis.CalendarEvent>> calendar(DateTime from, DateTime to) =>
      _client.parsers.calendar.getCalendar(startDate: from, endDate: to);

  @override
  Future<lanis.Lessons> lessons() => _client.parsers.lessonsStudent.getHome();

  @override
  Future<lanis.DetailedLesson> lessonDetails(Uri courseUrl) => _client
      .parsers
      .lessonsStudent
      .getDetailedCourseView(courseUrl.toString());

  @override
  Future<void> dispose() => _client.dispose();
}
