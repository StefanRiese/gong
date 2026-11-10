import '../api/cache.dart';
import '../caseda/caseda.dart';
import '../models/models.dart';
import '../untis/untis.dart';

/// Cache keys of the portal data and how to restore them from JSON.
abstract final class CacheKeys {
  static const account = 'account';
  static const timetable = 'timetable';
  static const substitutions = 'substitutions';
  static const courses = 'courses';
  static const homework = 'homework';
  static const allHomework = 'homework:all';
  static const grades = 'grades';
  static const meals = 'meals';
  static const untis = 'untis';

  static String course(String id) => 'course:$id';

  static String calendar(DateTime from, DateTime to) =>
      'calendar:${ymd(from)}:${ymd(to)}';

  /// Range of `/api/calendar` without parameters: today … +60 days.
  static (DateTime, DateTime) defaultCalendarRange(DateTime now) {
    final start = DateTime(now.year, now.month, now.day);
    return (start, start.add(const Duration(days: 60)));
  }

  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static List<T> _list<T>(
    Object? json,
    T Function(Map<String, Object?>) fromJson,
  ) => [for (final e in json as List) fromJson((e as Map).cast())];

  static Map<String, Object?> _map(Object? json) =>
      (json as Map).cast<String, Object?>();

  /// Codec for persisting [key]; null = not persisted.
  static CacheCodec? codecFor(String key) {
    if (key.startsWith('course:')) {
      return CacheCodec((j) => CourseDetails.fromJson(_map(j)));
    }
    if (key.startsWith('calendar:')) {
      return CacheCodec((j) => _list(j, CalendarEntry.fromJson));
    }
    return switch (key) {
      account => CacheCodec((j) => AccountInfo.fromJson(_map(j))),
      timetable => CacheCodec((j) => Timetable.fromJson(_map(j))),
      substitutions => CacheCodec((j) => _list(j, SubstitutionDay.fromJson)),
      courses => CacheCodec((j) => _list(j, Course.fromJson)),
      homework || allHomework => CacheCodec((j) => _list(j, Homework.fromJson)),
      grades => CacheCodec((j) => _list(j, CourseGrades.fromJson)),
      meals => CacheCodec((j) => MealsSnapshot.fromJson(_map(j))),
      untis => CacheCodec((j) => UntisSnapshot.fromJson(_map(j))),
      _ => null,
    };
  }
}
