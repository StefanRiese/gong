import 'app_database.dart';

/// User settings shared by all browsers (stored in the database).
class AppSettings {
  /// Subject (timetable abbreviation or course name) → color "#rrggbb".
  final Map<String, String> subjectColors;

  /// Course ID → timetable subject it belongs to ("" = none). Courses not
  /// listed are matched automatically by the web UI.
  final Map<String, String> courseSubjects;

  const AppSettings({
    this.subjectColors = const {},
    this.courseSubjects = const {},
  });

  static const maxSubjects = 100;
  static const maxNameLength = 60;
  static final colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  Map<String, Object?> toJson() => {
    'subjectColors': subjectColors,
    'courseSubjects': courseSubjects,
  };

  /// Parses and validates [json]; throws [FormatException] with a message.
  factory AppSettings.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Expected a JSON object');
    final raw = json['subjectColors'] ?? const {};
    if (raw is! Map) {
      throw const FormatException('subjectColors must be an object');
    }
    if (raw.length > maxSubjects) {
      throw const FormatException('Too many subjects (max. $maxSubjects)');
    }
    final colors = <String, String>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final name = key is String ? key.trim() : '';
      if (name.isEmpty || name.length > maxNameLength) {
        throw const FormatException(
          'Subject names must have 1–$maxNameLength characters',
        );
      }
      if (value is! String || !colorPattern.hasMatch(value)) {
        throw FormatException('Invalid color for "$name" (use #rrggbb)');
      }
      colors[name] = value.toLowerCase();
    }

    final rawCourses = json['courseSubjects'] ?? const {};
    if (rawCourses is! Map) {
      throw const FormatException('courseSubjects must be an object');
    }
    if (rawCourses.length > maxSubjects) {
      throw const FormatException('Too many courses (max. $maxSubjects)');
    }
    final courses = <String, String>{};
    for (final MapEntry(:key, :value) in rawCourses.entries) {
      if (key is! String || !_idPattern.hasMatch(key)) {
        throw const FormatException('Invalid course id in courseSubjects');
      }
      if (value is! String || value.trim().length > maxNameLength) {
        throw FormatException('Invalid subject for course "$key"');
      }
      courses[key] = value.trim();
    }
    return AppSettings(subjectColors: colors, courseSubjects: courses);
  }
}

/// Loads/saves [AppSettings]; in memory when no database is given (tests).
class SettingsStore {
  static const _key = 'settings';
  final AppDatabase? _db;
  AppSettings _memory = const AppSettings();

  SettingsStore([this._db]);

  AppSettings load() {
    final db = _db;
    if (db == null) return _memory;
    final json = db.getJson(_key);
    if (json == null) return const AppSettings();
    try {
      return AppSettings.fromJson(json);
    } on FormatException {
      return const AppSettings();
    }
  }

  void save(AppSettings settings) {
    final db = _db;
    if (db == null) {
      _memory = settings;
    } else {
      db.setJson(_key, settings.toJson());
    }
  }
}
