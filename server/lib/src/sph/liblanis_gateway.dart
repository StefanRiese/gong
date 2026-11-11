import 'package:dio/dio.dart';
import 'package:liblanis/easy_client.dart' as lanis;

import 'portal_fixes.dart';
import 'sph_gateway.dart';

/// Applets Lumo offers for an account. liblanis only counts the timetable
/// (`stundenplan.php`) for students, but the portal also shows it to parent
/// accounts, and liblanis' timetable parser reads that page: it is added for
/// a parent account whose portal menu has it.
Set<String> appletsOfAccount({
  required Set<String> supported,
  required Iterable<String?> menuLinks,
  required String? accountType,
}) => {
  ...supported,
  if (accountType == 'parent' && menuLinks.contains('stundenplan.php'))
    'stundenplan.php',
};

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
    String userAgent = 'lumo/0.1',
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
    final session = _client.session;
    if (!keepAlive) session?.preventLogoutTimer?.cancel();
    final interceptors = session?.dio.interceptors;
    if (interceptors != null &&
        !interceptors.any((i) => i is PortalFixInterceptor)) {
      interceptors.add(PortalFixInterceptor());
    }
  }

  @override
  Future<void> logout() => _client.logout();

  @override
  Set<String> get enabledApplets => appletsOfAccount(
    supported: _client.supportedApplets,
    menuLinks: [
      for (final e in _client.session?.travelMenu ?? const <Map>[])
        e['link']?.toString(),
    ],
    accountType: accountType,
  );

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

  /// Same request as liblanis' `LessonsStudentParser.setHomework`, but with a
  /// plain-text response: liblanis passes dio's parsed body through as String,
  /// which fails if the portal answers "1" with a JSON content type.
  @override
  Future<String> setHomeworkDone(
    String courseId,
    String entryId,
    bool done,
  ) async {
    final session = _client.session;
    if (session == null) {
      throw lanis.UnauthorizedException('Not logged in');
    }
    final response = await session.dio.post<String>(
      'https://start.schulportal.hessen.de/meinunterricht.php',
      data: {
        'a': 'sus_homeworkDone',
        'entry': entryId,
        'id': courseId,
        'b': done ? 'done' : 'undone',
      },
      options: Options(
        responseType: ResponseType.plain,
        contentType: Headers.formUrlEncodedContentType,
        headers: {'X-Requested-With': 'XMLHttpRequest'},
      ),
    );
    return (response.data ?? '').trim();
  }

  @override
  Future<void> dispose() => _client.dispose();
}
