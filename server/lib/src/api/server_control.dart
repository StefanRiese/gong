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

/// No account with that id.
class AccountNotFound implements Exception {
  const AccountNotFound();
}

/// What the API needs from the running server to show and change its
/// settings (setup page, „Einstellungen“). Implemented by AppServer.
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

  /// Tries to log in to WebUntis; throws UntisException on failure. Returns
  /// the class of the account. [password] / [school] null = stored / derived.
  Future<String> testUntisLogin({
    required String server,
    required String username,
    String? password,
    String? school,
  });

  /// Validates and stores [changes] (config keys → values) and applies them
  /// without restart where possible. Throws ConfigException for invalid
  /// values and SphException if new Schulportal credentials do not work.
  Future<ApplyResult> apply(Map<String, String> changes);

  Future<List<School>> searchSchools(String query);

  /// The accounts (children), the first one first; no passwords.
  List<Map<String, Object?>> listAccounts();

  /// Adds an account after a test login; returns its description. Throws
  /// ConfigException for invalid values, SphException / CasedaException /
  /// UntisException if a login does not work.
  Future<Map<String, Object?>> addAccount(Map<String, Object?> data);

  /// Changes name or logins of an account (fields not sent are kept; the
  /// first account only takes a `name`). Throws [AccountNotFound] and the
  /// exceptions of [addAccount].
  Future<Map<String, Object?>> updateAccount(
    String id,
    Map<String, Object?> data,
  );

  /// Removes an account with all its cached data. The first account cannot
  /// be removed (ArgumentError); throws [AccountNotFound].
  Future<void> removeAccount(String id);
}
