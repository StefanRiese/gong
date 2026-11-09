import '../auth/password.dart';
import '../notify/poller.dart';
import 'env.dart';

/// ntfy push notification settings; null in [AppConfig.ntfy] = disabled.
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
  });

  String get databasePath => '$dataDir/schulportal.db';

  static final _topicPattern = RegExp(r'^[-_A-Za-z0-9]{1,64}$');
  static final _hoursPattern = RegExp(r'^\s*(\d{1,2})\s*-\s*(\d{1,2})\s*$');

  /// Parses [env]; throws [ConfigException] listing all problems.
  factory AppConfig.fromEnv(Map<String, String> env) {
    final problems = <String>[];
    String? get(String key) {
      final v = env[key]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    final sph = SphCredentials.fromEnv(env);
    if (sph == null) problems.add('SPH_USERNAME and SPH_PASSWORD are required');

    final hash = get('APP_PASSWORD_HASH') ?? '';
    if (hash.isEmpty) {
      problems.add(
        'APP_PASSWORD_HASH is required (create one with bin/hash_password, '
        'or run deploy/install.sh --configure)',
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

    final interval = int.tryParse(get('POLL_INTERVAL_MINUTES') ?? '20');
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

    if (problems.isNotEmpty) throw ConfigException(problems);

    return AppConfig(
      sph: sph!,
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
        interval: Duration(minutes: interval!),
        gradesInterval: Duration(minutes: gradesInterval!),
        activeFromHour: from,
        activeToHour: to,
        includeGradeValues: _bool(env['NOTIFY_GRADE_VALUES']),
      ),
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
