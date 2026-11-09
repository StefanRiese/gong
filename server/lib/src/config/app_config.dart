import '../auth/password.dart';
import 'env.dart';

/// Server configuration from environment variables / `.env`.
class AppConfig {
  final SphCredentials sph;

  /// PBKDF2 hash of the web UI password (see bin/hash_password.dart).
  final String appPasswordHash;
  final String host;
  final int port;

  /// Directory with the built web UI; null = API only.
  final String? webDir;

  /// Set the `Secure` flag on the session cookie (enable behind HTTPS).
  final bool cookieSecure;

  /// Use the first X-Forwarded-For address as client IP (behind a proxy).
  final bool trustProxy;
  final Duration sessionTtl;

  const AppConfig({
    required this.sph,
    required this.appPasswordHash,
    this.host = '127.0.0.1',
    this.port = 8080,
    this.webDir,
    this.cookieSecure = false,
    this.trustProxy = false,
    this.sessionTtl = const Duration(days: 30),
  });

  /// Parses [env]; throws [ConfigException] listing all problems.
  factory AppConfig.fromEnv(Map<String, String> env) {
    final problems = <String>[];

    final sph = SphCredentials.fromEnv(env);
    if (sph == null) problems.add('SPH_USERNAME and SPH_PASSWORD are required');

    final hash = env['APP_PASSWORD_HASH']?.trim() ?? '';
    if (hash.isEmpty) {
      problems.add(
        'APP_PASSWORD_HASH is required (create one with bin/hash_password, '
        'or run deploy/install.sh --configure)',
      );
    } else if (!PasswordHasher.isValidFormat(hash)) {
      problems.add('APP_PASSWORD_HASH has an invalid format');
    }

    final port = int.tryParse(env['PORT'] ?? '8080');
    if (port == null || port < 1 || port > 65535) {
      problems.add('PORT must be a number between 1 and 65535');
    }

    final ttlDays = int.tryParse(env['SESSION_TTL_DAYS'] ?? '30');
    if (ttlDays == null || ttlDays < 1) {
      problems.add('SESSION_TTL_DAYS must be a positive number');
    }

    if (problems.isNotEmpty) throw ConfigException(problems);

    final webDir = env['WEB_DIR']?.trim();
    return AppConfig(
      sph: sph!,
      appPasswordHash: hash,
      host: env['HOST']?.trim().isNotEmpty == true
          ? env['HOST']!.trim()
          : '127.0.0.1',
      port: port!,
      webDir: (webDir == null || webDir.isEmpty) ? null : webDir,
      cookieSecure: _bool(env['COOKIE_SECURE']),
      trustProxy: _bool(env['TRUST_PROXY']),
      sessionTtl: Duration(days: ttlDays!),
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
