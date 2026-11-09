/// Errors raised by [SphService]. The API layer maps these to HTTP responses.
sealed class SphException implements Exception {
  final String message;
  final Object? cause;

  const SphException(this.message, [this.cause]);

  @override
  String toString() => '$runtimeType: $message';
}

/// Wrong or incomplete credentials, or the portal temporarily blocks logins.
/// Never retried automatically, to avoid locking the account.
class SphAuthException extends SphException {
  /// Earliest time the service will try to log in again.
  final DateTime? retryAfter;

  const SphAuthException(String message, {this.retryAfter, Object? cause})
    : super(message, cause);
}

/// Portal is down, under maintenance, or not reachable.
class SphUnavailableException extends SphException {
  const SphUnavailableException(super.message, [super.cause]);
}

/// The feature (applet) is not enabled for this account/school.
class SphFeatureDisabledException extends SphException {
  const SphFeatureDisabledException(super.message);
}

/// A requested item (e.g. course ID) does not exist.
class SphNotFoundException extends SphException {
  const SphNotFoundException(super.message);
}

/// Unexpected response; most likely the portal's HTML changed.
class SphDataException extends SphException {
  const SphDataException(super.message, [super.cause]);
}
