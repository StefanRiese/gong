import '../config/server_settings.dart';

/// Result of changing server settings.
class ApplyResult {
  /// Changed settings that take effect only after a restart.
  final List<String> restartRequired;

  /// Different school or user: cached data and notification state were reset.
  final bool accountChanged;

  const ApplyResult({
    this.restartRequired = const [],
    this.accountChanged = false,
  });
}

/// What the API needs from the running server to show and change its
/// settings (setup page, „Einstellungen → Server“). Implemented by AppServer.
abstract interface class ServerControl {
  /// Schulportal credentials or web UI password missing: only the setup page
  /// works (authorized by the setup token).
  bool get setupRequired;

  bool checkSetupToken(String? token);

  /// Current settings for the web UI (secrets only as "set"/"not set").
  Map<String, Object?> describeSettings();

  /// Tries to log in to Schulportal; throws SphException on failure.
  /// [password] null = the stored password.
  Future<void> testLogin({
    required int schoolId,
    required String username,
    String? password,
  });

  /// Tries to log in to Caseda Schulmenü; throws CasedaException on failure.
  /// [password] / [url] null = the stored values.
  Future<void> testCasedaLogin({
    required String username,
    String? password,
    String? url,
  });

  /// Validates and stores [changes] (config keys → values) and applies them
  /// without restart where possible. Throws ConfigException for invalid
  /// values and SphException if new Schulportal credentials do not work.
  Future<ApplyResult> apply(Map<String, String> changes);

  Future<List<School>> searchSchools(String query);
}
