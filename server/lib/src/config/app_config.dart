import '../auth/password.dart';
import '../notify/poller.dart';
import '../sync/sync_service.dart';
import 'env.dart';

/// ntfy push notification settings; null in [AppConfig.ntfy] = disabled.
/// Caseda Schulmenü login (school meals); null in [AppConfig.caseda] = off.
class CasedaConfig {
  final Uri url;
  final String username;
  final String password;

  const CasedaConfig({
    required this.url,
    required this.username,
    required this.password,
  });
}

/// WebUntis login (second source for substitutions); null in
/// [AppConfig.untis] = off.
class UntisConfig {
  /// Host name, e.g. "ghs-griesheim.webuntis.com".
  final String server;

  /// School name in WebUntis (default: first part of [server]).
  final String school;
  final String username;
  final String password;

  const UntisConfig({
    required this.server,
    required this.school,
    required this.username,
    required this.password,
  });

  /// Host name from a host or a pasted web address
  /// ("https://xyz.webuntis.com/timetable/…"); null if invalid.
  static String? parseServer(String input) {
    var v = input.trim();
    if (v.isEmpty) return null;
    if (!v.contains('://')) v = 'https://$v';
    final host = Uri.tryParse(v)?.host.toLowerCase() ?? '';
    return RegExp(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$').hasMatch(host) &&
            host.contains('.')
        ? host
        : null;
  }
}

class NtfyConfig {
  final Uri server;
  final String topic;
  final String? token;

  const NtfyConfig({required this.server, required this.topic, this.token});
}

/// Server configuration from environment variables / `.env`.
class AppConfig {
  final SphCredentials sph;

  /// PBKDF2 hash of the web UI password (see bin/hash_password.dart).
  final String appPasswordHash;
  final String host;
  final int port;

  /// Directory with the built web UI; null = API only.
  final String? webDir;

  /// Directory for the SQLite database (sessions, notification state).
  final String dataDir;

  /// Set the `Secure` flag on the session cookie (enable behind HTTPS).
  final bool cookieSecure;

  /// Use the first X-Forwarded-For address as client IP (behind a proxy).
  final bool trustProxy;
  final Duration sessionTtl;

  /// Push notifications; null = disabled (no background polling).
  final NtfyConfig? ntfy;

  /// Public URL of the web UI, used for links in notifications.
  final Uri? appUrl;
  final PollerConfig poller;

  /// Background sync with Schulportal (also drives notifications).
  final SyncConfig sync;

  /// Open the web UI in the default browser after start (desktop builds).
  final bool openBrowser;

  /// Look for new releases on GitHub (UPDATE_CHECK, default on).
  final bool updateCheck;

  /// School meals (Caseda Schulmenü): balance and own orders; null = off.
  final CasedaConfig? caseda;

  /// Balance below this is highlighted in the web UI (CASEDA_BALANCE_WARNING).
  final int mealsBalanceWarningCents;

  /// WebUntis as a second source for substitutions; null = off.
  final UntisConfig? untis;

  const AppConfig({
    required this.sph,
    required this.appPasswordHash,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.webDir,
    this.dataDir = '.',
    this.cookieSecure = false,
    this.trustProxy = false,
    this.sessionTtl = const Duration(days: 30),
    this.ntfy,
    this.appUrl,
    this.poller = const PollerConfig(),
    this.sync = const SyncConfig(),
    this.openBrowser = false,
    this.updateCheck = true,
    this.caseda,
    this.mealsBalanceWarningCents = 1000,
    this.untis,
    this.missing = const [],
  });

  /// Required settings that are not set yet (with `allowIncomplete`): the
  /// server then starts in setup mode (web UI setup page).
  final List<String> missing;

  bool get needsSetup => missing.isNotEmpty;

  String get databasePath => '$dataDir/lumo.db';

  static final _topicPattern = RegExp(r'^[-_A-Za-z0-9]{1,64}$');
  static final _hoursPattern = RegExp(r'^\s*(\d{1,2})\s*-\s*(\d{1,2})\s*$');

  /// Parses [env]; throws [ConfigException] listing all problems.
  /// With [allowIncomplete], missing Schulportal credentials or web UI
  /// password are no error but listed in [missing] (setup mode).
  /// [passwordIterations] overrides the PBKDF2 cost for a plain
  /// APP_PASSWORD (tests).
  factory AppConfig.fromEnv(
    Map<String, String> env, {
    int? passwordIterations,
    bool allowIncomplete = false,
  }) {
    final problems = <String>[];
    final missing = <String>[];
    String? get(String key) {
      final v = env[key]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    var sph = SphCredentials.fromEnv(env);
    if (sph == null) {
      const message = 'SPH_USERNAME and SPH_PASSWORD are required';
      (allowIncomplete ? missing : problems).add(message);
      final school = int.tryParse(get('SPH_SCHOOL_ID') ?? '6128') ?? 6128;
      sph = SphCredentials(school, get('SPH_USERNAME') ?? '', '');
    }

    // APP_PASSWORD (plain text) wins over APP_PASSWORD_HASH; the desktop
    // builds replace it with the hash in the config file (see config_file.dart).
    final plain = get('APP_PASSWORD');
    var hash = get('APP_PASSWORD_HASH') ?? '';
    if (plain != null) {
      if (plain.length < 8) {
        problems.add('APP_PASSWORD must have at least 8 characters');
      } else {
        hash = passwordIterations == null
            ? PasswordHasher.hash(plain)
            : PasswordHasher.hash(plain, iterations: passwordIterations);
      }
    } else if (hash.isEmpty) {
      (allowIncomplete ? missing : problems).add(
        'APP_PASSWORD or APP_PASSWORD_HASH is required (create a hash with '
        'bin/hash_password, or run deploy/install.sh --configure)',
      );
    } else if (!PasswordHasher.isValidFormat(hash)) {
      problems.add('APP_PASSWORD_HASH has an invalid format');
    }

    final port = int.tryParse(get('PORT') ?? '8080');
    if (port == null || port < 1 || port > 65535) {
      problems.add('PORT must be a number between 1 and 65535');
    }

    final ttlDays = int.tryParse(get('SESSION_TTL_DAYS') ?? '30');
    if (ttlDays == null || ttlDays < 1) {
      problems.add('SESSION_TTL_DAYS must be a positive number');
    }

    // --- notifications ---
    NtfyConfig? ntfy;
    final topic = get('NTFY_TOPIC');
    if (topic != null) {
      final server = Uri.tryParse(get('NTFY_URL') ?? 'https://ntfy.sh');
      if (server == null ||
          !(server.isScheme('https') || server.isScheme('http')) ||
          server.host.isEmpty) {
        problems.add('NTFY_URL must be an http(s) URL');
      } else if (!_topicPattern.hasMatch(topic)) {
        problems.add(
          'NTFY_TOPIC may only contain letters, digits, "-" and "_" (max. 64)',
        );
      } else {
        ntfy = NtfyConfig(
          server: server,
          topic: topic,
          token: get('NTFY_TOKEN'),
        );
      }
    }

    Uri? appUrl;
    final appUrlRaw = get('APP_URL');
    if (appUrlRaw != null) {
      final u = Uri.tryParse(appUrlRaw);
      if (u == null ||
          !(u.isScheme('https') || u.isScheme('http')) ||
          u.host.isEmpty) {
        problems.add('APP_URL must be an http(s) URL');
      } else {
        // Trailing slash so relative paths resolve below it.
        appUrl = u.path.endsWith('/') ? u : u.replace(path: '${u.path}/');
      }
    }

    final interval = int.tryParse(get('POLL_INTERVAL_MINUTES') ?? '15');
    if (interval == null || interval < 5) {
      problems.add('POLL_INTERVAL_MINUTES must be at least 5');
    }
    final gradesInterval = int.tryParse(
      get('GRADES_INTERVAL_MINUTES') ?? '120',
    );
    if (gradesInterval == null || gradesInterval < 30) {
      problems.add('GRADES_INTERVAL_MINUTES must be at least 30');
    }

    var from = 6, to = 22;
    final hours = get('ACTIVE_HOURS');
    if (hours != null) {
      final m = _hoursPattern.firstMatch(hours);
      final a = m == null ? null : int.parse(m.group(1)!);
      final b = m == null ? null : int.parse(m.group(2)!);
      if (a == null || b == null || a > 23 || b > 24 || a == b) {
        problems.add('ACTIVE_HOURS must look like "6-22" (hours 0–24)');
      } else {
        from = a;
        to = b;
      }
    }

    final kinds = <WatchKind>{};
    for (final part
        in (get('NOTIFY') ?? 'substitutions,homework,grades')
            .split(',')
            .where((p) => p.trim().isNotEmpty)) {
      final k = WatchKind.parse(part);
      if (k == null) {
        problems.add(
          'NOTIFY: unknown "$part" (allowed: substitutions, homework, grades)',
        );
      } else {
        kinds.add(k);
      }
    }

    // --- school meals (Caseda Schulmenü) ---
    // CASEDA_ENABLED=false switches it off but keeps the login.
    CasedaConfig? caseda;
    final casedaUser = get('CASEDA_USERNAME');
    final casedaPassword = get('CASEDA_PASSWORD');
    final casedaEnabled = !const {
      '0',
      'false',
      'no',
      'off',
    }.contains(env['CASEDA_ENABLED']?.trim().toLowerCase());
    if (casedaEnabled && (casedaUser != null || casedaPassword != null)) {
      final url = Uri.tryParse(
        get('CASEDA_URL') ?? 'https://www.caseda-schulmenue.de',
      );
      if (casedaUser == null || casedaPassword == null) {
        problems.add('CASEDA_USERNAME and CASEDA_PASSWORD are both needed');
      } else if (url == null || !url.isScheme('https') || url.host.isEmpty) {
        problems.add('CASEDA_URL must be an https URL');
      } else {
        caseda = CasedaConfig(
          url: url,
          username: casedaUser,
          password: casedaPassword,
        );
      }
    }
    int? warning;
    final warningRaw = get('CASEDA_BALANCE_WARNING');
    if (warningRaw != null) {
      final euros = double.tryParse(warningRaw.replaceAll(',', '.'));
      if (euros == null || euros < 0 || euros > 1000) {
        problems.add(
          'CASEDA_BALANCE_WARNING must be an amount in euros (0–1000)',
        );
      } else {
        warning = (euros * 100).round();
      }
    }

    // --- WebUntis (second source for substitutions) ---
    // UNTIS_ENABLED=false switches it off but keeps the login.
    UntisConfig? untis;
    final untisServerRaw = get('UNTIS_SERVER');
    final untisUser = get('UNTIS_USERNAME');
    final untisPassword = get('UNTIS_PASSWORD');
    final untisEnabled = !const {
      '0',
      'false',
      'no',
      'off',
    }.contains(env['UNTIS_ENABLED']?.trim().toLowerCase());
    if (untisEnabled &&
        (untisServerRaw != null ||
            untisUser != null ||
            untisPassword != null)) {
      final server = untisServerRaw == null
          ? null
          : UntisConfig.parseServer(untisServerRaw);
      if (untisServerRaw == null ||
          untisUser == null ||
          untisPassword == null) {
        problems.add(
          'UNTIS_SERVER, UNTIS_USERNAME and UNTIS_PASSWORD are all needed',
        );
      } else if (server == null) {
        problems.add('UNTIS_SERVER must be a host name like xyz.webuntis.com');
      } else {
        untis = UntisConfig(
          server: server,
          school: get('UNTIS_SCHOOL') ?? server.split('.').first,
          username: untisUser,
          password: untisPassword,
        );
      }
    }

    if (problems.isNotEmpty) throw ConfigException(problems);

    return AppConfig(
      sph: sph,
      appPasswordHash: hash,
      host: get('HOST') ?? '127.0.0.1',
      port: port!,
      webDir: get('WEB_DIR'),
      dataDir: get('DATA_DIR') ?? '.',
      cookieSecure: _bool(env['COOKIE_SECURE']),
      trustProxy: _bool(env['TRUST_PROXY']),
      sessionTtl: Duration(days: ttlDays!),
      ntfy: ntfy,
      appUrl: appUrl,
      poller: PollerConfig(
        kinds: kinds,
        includeGradeValues: _bool(env['NOTIFY_GRADE_VALUES']),
      ),
      sync: SyncConfig(
        enabled: !const {
          '0',
          'false',
          'no',
          'off',
        }.contains(env['SYNC']?.trim().toLowerCase()),
        interval: Duration(minutes: interval!),
        detailsInterval: Duration(minutes: gradesInterval!),
        activeFromHour: from,
        activeToHour: to,
      ),
      openBrowser: _bool(env['OPEN_BROWSER']),
      updateCheck: !const {
        '0',
        'false',
        'no',
        'off',
      }.contains(env['UPDATE_CHECK']?.trim().toLowerCase()),
      caseda: caseda,
      mealsBalanceWarningCents: warning ?? 1000,
      untis: untis,
      missing: missing,
    );
  }

  static bool _bool(String? v) =>
      const {'1', 'true', 'yes', 'on'}.contains(v?.trim().toLowerCase());
}

class ConfigException implements Exception {
  final List<String> problems;

  const ConfigException(this.problems);

  @override
  String toString() =>
      'Invalid configuration:\n${problems.map((p) => '  - $p').join('\n')}';
}
