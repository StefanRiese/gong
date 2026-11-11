import '../config/server_settings.dart';

/// Result of changing server settings.
class ApplyResult {
  /// Changed settings that take effect only after a restart.
  final List<String> restartRequired;

  const ApplyResult({this.restartRequired = const []});
}

/// No account with that id.
class AccountNotFound implements Exception {
  const AccountNotFound();
}

/// What the API needs from the running server to show and change its
/// settings (setup page, „Einstellungen“). Implemented by AppServer.
abstract interface class ServerControl {
  /// No account or no web UI password yet: only the setup page works
  /// (authorized by the setup token).
  bool get setupRequired;

  bool checkSetupToken(String? token);

  /// Whether the server can restart itself here (Windows / macOS app, systemd
  /// service); otherwise [restart] is not offered.
  bool get canRestart;

  /// Restarts the server shortly after the call returns (the response of the
  /// request that asked for it still goes out). Throws [StateError] if
  /// [canRestart] is false.
  void restart();

  /// Current settings for the web UI (secrets only as "set"/"not set").
  Map<String, Object?> describeSettings();

  /// Validates and stores [changes] (config keys → values) and applies them
  /// without restart where possible. Throws ConfigException for invalid
  /// values.
  Future<ApplyResult> apply(Map<String, String> changes);

  Future<List<School>> searchSchools(String query);

  /// The accounts (children), the first one first; no passwords.
  List<Map<String, Object?>> listAccounts();

  /// Adds an account after a test login; returns its description. Throws
  /// ConfigException for invalid values, SphException / CasedaException /
  /// UntisException if a login does not work.
  Future<Map<String, Object?>> addAccount(Map<String, Object?> data);

  /// Tries all logins in [data] (the body of an account, plus an optional
  /// `id`: missing fields and empty passwords then come from that account)
  /// without storing anything. Returns what was tried (`schulportal`,
  /// `caseda`, `untis`). Throws like [addAccount] and [AccountNotFound].
  Future<List<String>> testAccount(Map<String, Object?> data);

  /// Changes name or logins of an account (fields not sent are kept). Throws
  /// [AccountNotFound] and the exceptions of [addAccount].
  Future<Map<String, Object?>> updateAccount(
    String id,
    Map<String, Object?> data,
  );

  /// Removes an account with all its cached data. The last account cannot be
  /// removed (ArgumentError); throws [AccountNotFound].
  Future<void> removeAccount(String id);
}
