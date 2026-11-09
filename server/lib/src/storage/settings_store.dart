import '../models/models.dart';
import 'app_database.dart';

/// Which entries of the substitution plan are shown and notified. The plan
/// of Schulportal contains all classes of the school.
class SubstitutionFilter {
  /// Own classes as in the plan (e.g. "05eG"); empty = all classes.
  final List<String> classes;

  /// Show entries without class (break supervision, care, …) while
  /// [classes] is set.
  final bool showUnassigned;

  /// Types to hide (e.g. "Pausenaufsicht"), compared case-insensitively.
  final List<String> hiddenTypes;

  const SubstitutionFilter({
    this.classes = const [],
    this.showUnassigned = false,
    this.hiddenTypes = const [],
  });

  static const maxEntries = 30;
  static const maxLength = 40;

  bool get isActive => classes.isNotEmpty || hiddenTypes.isNotEmpty;

  /// Classes of an entry: "05aG, 05bG" → [05aG, 05bG].
  static List<String> classesOf(String? className) => [
    for (final part in (className ?? '').split(RegExp(r'[,;?/]+')))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  bool matches(Substitution s) {
    final type = (s.type ?? '').trim().toLowerCase();
    if (type.isNotEmpty && hiddenTypes.any((t) => t.toLowerCase() == type)) {
      return false;
    }
    if (classes.isEmpty) return true;
    final own = classesOf(s.className);
    if (own.isEmpty) return showUnassigned;
    final wanted = {for (final c in classes) c.toLowerCase()};
    return own.any((c) => wanted.contains(c.toLowerCase()));
  }

  /// [days] with only the matching entries, and how many were left out.
  (List<SubstitutionDay>, int) apply(List<SubstitutionDay> days) {
    if (!isActive) return (days, 0);
    var hidden = 0;
    final result = <SubstitutionDay>[];
    for (final d in days) {
      final entries = d.entries.where(matches).toList();
      hidden += d.entries.length - entries.length;
      result.add(
        SubstitutionDay(date: d.date, entries: entries, notices: d.notices),
      );
    }
    return (result, hidden);
  }

  Map<String, Object?> toJson() => {
    'classes': classes,
    'showUnassigned': showUnassigned,
    'hiddenTypes': hiddenTypes,
  };

  factory SubstitutionFilter.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('substitutionFilter must be an object');
    }
    List<String> list(String key) {
      final raw = json[key] ?? const [];
      if (raw is! List || raw.length > maxEntries) {
        throw FormatException(
          'substitutionFilter.$key: list of max. $maxEntries',
        );
      }
      final result = <String>[];
      for (final v in raw) {
        final t = v is String ? v.trim() : '';
        if (t.isEmpty || t.length > maxLength) {
          throw FormatException(
            'substitutionFilter.$key: entries need 1–$maxLength characters',
          );
        }
        if (!result.contains(t)) result.add(t);
      }
      return result;
    }

    final unassigned = json['showUnassigned'] ?? false;
    if (unassigned is! bool) {
      throw const FormatException('substitutionFilter.showUnassigned: bool');
    }
    return SubstitutionFilter(
      classes: list('classes'),
      showUnassigned: unassigned,
      hiddenTypes: list('hiddenTypes'),
    );
  }
}

/// User settings shared by all browsers (stored in the database).
class AppSettings {
  /// Subject (timetable abbreviation or course name) → color "#rrggbb".
  final Map<String, String> subjectColors;

  /// Course ID → timetable subject it belongs to ("" = none). Courses not
  /// listed are matched automatically by the web UI.
  final Map<String, String> courseSubjects;

  /// Filter of the substitution plan (web UI and notifications).
  final SubstitutionFilter substitutionFilter;

  const AppSettings({
    this.subjectColors = const {},
    this.courseSubjects = const {},
    this.substitutionFilter = const SubstitutionFilter(),
  });

  static const maxSubjects = 100;
  static const maxNameLength = 60;
  static final colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  Map<String, Object?> toJson() => {
    'subjectColors': subjectColors,
    'courseSubjects': courseSubjects,
    'substitutionFilter': substitutionFilter.toJson(),
  };

  /// Parses and validates [json]; throws [FormatException] with a message.
  /// Fields missing in [json] are taken from [base] (partial updates).
  factory AppSettings.fromJson(
    Object? json, {
    AppSettings base = const AppSettings(),
  }) {
    if (json is! Map) throw const FormatException('Expected a JSON object');
    final raw = json['subjectColors'] ?? base.subjectColors;
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

    final rawCourses = json['courseSubjects'] ?? base.courseSubjects;
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
    final filter = json.containsKey('substitutionFilter')
        ? SubstitutionFilter.fromJson(json['substitutionFilter'])
        : base.substitutionFilter;
    return AppSettings(
      subjectColors: colors,
      courseSubjects: courses,
      substitutionFilter: filter,
    );
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
