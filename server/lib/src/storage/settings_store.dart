import 'app_database.dart';

/// User settings shared by all browsers (stored in the database).
class AppSettings {
  /// Subject name → color "#rrggbb".
  final Map<String, String> subjectColors;

  const AppSettings({this.subjectColors = const {}});

  static const maxSubjects = 100;
  static const maxNameLength = 60;
  static final colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

  Map<String, Object?> toJson() => {'subjectColors': subjectColors};

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
    return AppSettings(subjectColors: colors);
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
