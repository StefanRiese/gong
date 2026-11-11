import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../storage/app_database.dart';

/// Server settings that can be changed in the web UI (setup page and
/// „Einstellungen“). Names are the config.env keys.
abstract final class ServerSettingKeys {
  static const editable = {
    'ACCOUNT_NAME',
    'SPH_SCHOOL_ID',
    'SPH_USERNAME',
    'SPH_PASSWORD',
    'APP_PASSWORD_HASH',
    'SYNC',
    'POLL_INTERVAL_MINUTES',
    'GRADES_INTERVAL_MINUTES',
    'ACTIVE_HOURS',
    'NTFY_URL',
    'NTFY_TOPIC',
    'NTFY_TOKEN',
    'NOTIFY',
    'NOTIFY_GRADE_VALUES',
    'APP_URL',
    'HOST',
    'PORT',
    'SESSION_TTL_DAYS',
    'COOKIE_SECURE',
    'TRUST_PROXY',
    'OPEN_BROWSER',
    'UPDATE_CHECK',
    'CASEDA_ENABLED',
    'CASEDA_URL',
    'CASEDA_USERNAME',
    'CASEDA_PASSWORD',
    'CASEDA_BALANCE_WARNING',
    'UNTIS_ENABLED',
    'UNTIS_SERVER',
    'UNTIS_SCHOOL',
    'UNTIS_USERNAME',
    'UNTIS_PASSWORD',
  };

  /// Never sent to the browser (only whether they are set).
  static const secret = {
    'SPH_PASSWORD',
    'NTFY_TOKEN',
    'APP_PASSWORD_HASH',
    'CASEDA_PASSWORD',
    'UNTIS_PASSWORD',
  };

  /// Take effect only after a restart of the server.
  static const restart = {
    'HOST',
    'PORT',
    'SESSION_TTL_DAYS',
    'COOKIE_SECURE',
    'TRUST_PROXY',
  };
}

/// Settings made in the web UI, stored in the database. They take
/// precedence over environment variables and config.env, so they also work
/// where the config file is read-only for the server (LXC: root-owned).
class WebSettingsStore {
  final AppDatabase db;

  WebSettingsStore(this.db);

  static const _key = 'server-config';

  Map<String, String> load() => {
    for (final MapEntry(:key, :value)
        in (db.getJson(_key) ?? const <String, Object?>{}).entries)
      if (value is String && ServerSettingKeys.editable.contains(key))
        key: value,
  };

  void save(Map<String, String> values) => db.setJson(_key, {
    for (final MapEntry(:key, :value) in values.entries)
      if (ServerSettingKeys.editable.contains(key)) key: value,
  });
}

/// One-time token that authorizes the setup page while the server is not
/// configured (nobody else in the network can take it over). Also written to
/// `DATA_DIR/setup-token`, so install.sh can show the setup link.
class SetupToken {
  final String value;
  final File? _file;

  SetupToken._(this.value, this._file);

  factory SetupToken.create({String? dataDir}) {
    final random = Random.secure();
    final value = base64Url
        .encode(List<int>.generate(18, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    File? file;
    if (dataDir != null) {
      file = File('$dataDir${Platform.pathSeparator}setup-token');
      try {
        file.writeAsStringSync('$value\n', flush: true);
        if (!Platform.isWindows) {
          Process.runSync('chmod', ['600', file.path]);
        }
      } on Object {
        file = null; // only in the log then
      }
    }
    return SetupToken._(value, file);
  }

  /// Constant-time comparison.
  bool matches(String? candidate) {
    if (candidate == null || candidate.length != value.length) return false;
    var diff = 0;
    for (var i = 0; i < value.length; i++) {
      diff |= value.codeUnitAt(i) ^ candidate.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Deletes the token file (setup done).
  void discard() {
    try {
      _file?.deleteSync();
    } on Object {
      // Gone already.
    }
  }
}

/// A school of Schulportal Hessen.
class School {
  final int id;
  final String name;
  final String city;

  const School(this.id, this.name, this.city);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'city': city};
}

/// Public school list of Schulportal Hessen (for choosing the school by name
/// on the setup page), loaded on first use and kept for a day.
class SchoolDirectory {
  final Future<String> Function() _fetch;
  final DateTime Function() _now;
  List<School>? _schools;
  DateTime? _loadedAt;
  Future<List<School>>? _loading;

  static final listUrl = Uri.parse(
    'https://startcache.schulportal.hessen.de/exporteur.php?a=schoollist',
  );

  SchoolDirectory({Future<String> Function()? fetch, DateTime Function()? now})
    : _fetch = fetch ?? _download,
      _now = now ?? DateTime.now;

  static Future<String> _download() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'lumo';
    try {
      final req = await client.getUrl(listUrl);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: listUrl);
      }
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }

  /// Up to [limit] schools whose number, name or town contains all words
  /// of [query].
  Future<List<School>> search(String query, {int limit = 20}) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final all = await _all();
    final result = <School>[];
    for (final s in all) {
      final text = '${s.id} ${s.name} ${s.city}'.toLowerCase();
      if (words.every(text.contains)) {
        result.add(s);
        if (result.length >= limit) break;
      }
    }
    return result;
  }

  /// The school with [id], or null.
  Future<School?> byId(int id) async {
    for (final s in await _all()) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<List<School>> _all() {
    final loaded = _schools;
    final at = _loadedAt;
    if (loaded != null &&
        at != null &&
        _now().difference(at) < const Duration(days: 1)) {
      return Future.value(loaded);
    }
    return _loading ??= () async {
      try {
        final schools = parse(await _fetch());
        _schools = schools;
        _loadedAt = _now();
        return schools;
      } finally {
        _loading = null;
      }
    }();
  }

  /// Parses the JSON of the school list (regions with "Schulen").
  static List<School> parse(String json) {
    final result = <School>[];
    for (final region in jsonDecode(json) as List) {
      for (final s in ((region as Map)['Schulen'] as List? ?? const [])) {
        final m = s as Map;
        final id = int.tryParse('${m['Id']}');
        if (id == null) continue;
        result.add(
          School(id, '${m['Name'] ?? ''}'.trim(), '${m['Ort'] ?? ''}'.trim()),
        );
      }
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }
}
