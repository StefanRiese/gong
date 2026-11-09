import 'dart:io';

/// Environment variables, with values from a `.env` file filling gaps.
/// Real environment variables take precedence.
Map<String, String> loadEnv({String path = '.env'}) {
  final env = Map<String, String>.from(Platform.environment);
  final file = File(path);
  if (!file.existsSync()) return env;
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
    final i = line.indexOf('=');
    final key = line.substring(0, i).trim();
    var value = line.substring(i + 1).trim();
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    env.putIfAbsent(key, () => value);
  }
  return env;
}

/// Schulportal credentials from SPH_SCHOOL_ID, SPH_USERNAME, SPH_PASSWORD.
class SphCredentials {
  final int schoolId;
  final String username;
  final String password;

  const SphCredentials(this.schoolId, this.username, this.password);

  /// Returns null if username or password is missing.
  static SphCredentials? fromEnv(Map<String, String> env) {
    final schoolId = int.tryParse(env['SPH_SCHOOL_ID'] ?? '6128');
    final username = env['SPH_USERNAME'];
    final password = env['SPH_PASSWORD'];
    if (schoolId == null ||
        username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      return null;
    }
    return SphCredentials(schoolId, username, password);
  }
}
