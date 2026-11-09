import 'dart:convert';
import 'dart:io';

/// A push notification.
class AppNotification {
  final String title;
  final String message;

  /// ntfy tags (emoji shortcodes), e.g. "warning", "books".
  final List<String> tags;

  /// 1 (min) … 5 (max); 3 = default.
  final int priority;

  /// Path in the web UI to open on click, e.g. "/vertretungen".
  final String? clickPath;

  const AppNotification({
    required this.title,
    required this.message,
    this.tags = const [],
    this.priority = 3,
    this.clickPath,
  });

  @override
  String toString() => '$title: $message';
}

abstract interface class Notifier {
  /// Human-readable target, e.g. "ntfy.sh, Thema sph-a1…" (no secrets).
  String get description;

  /// Sends [notification]; throws [NotifyException] on failure.
  Future<void> send(AppNotification notification);
}

class NotifyException implements Exception {
  final String message;

  const NotifyException(this.message);

  @override
  String toString() => 'NotifyException: $message';
}

/// Publishes to an ntfy server (https://ntfy.sh or self-hosted) using the
/// JSON API, which handles UTF-8 titles correctly.
class NtfyNotifier implements Notifier {
  final Uri server;
  final String topic;
  final String? token;

  /// Public base URL of the web UI, used for click links (optional).
  final Uri? appUrl;
  final HttpClient Function() _clientFactory;

  NtfyNotifier({
    required this.server,
    required this.topic,
    this.token,
    this.appUrl,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  @override
  String get description {
    final shown = topic.length <= 6 ? topic : '${topic.substring(0, 6)}…';
    return '${server.host}, Thema $shown${token != null ? ' (mit Token)' : ''}';
  }

  Map<String, Object?> payload(AppNotification n) => {
    'topic': topic,
    'title': n.title,
    'message': n.message,
    if (n.tags.isNotEmpty) 'tags': n.tags,
    'priority': n.priority.clamp(1, 5),
    if (appUrl != null && n.clickPath != null)
      'click': appUrl!
          .resolve(n.clickPath!.replaceFirst(RegExp('^/'), ''))
          .toString(),
  };

  @override
  Future<void> send(AppNotification notification) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'ranzen';
    try {
      final request = await client
          .postUrl(server)
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      if (token != null && token!.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final bytes = utf8.encode(jsonEncode(payload(notification)));
      request.contentLength = bytes.length; // no chunked encoding
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw NotifyException(
          'ntfy answered ${response.statusCode}: ${_short(body)}',
        );
      }
    } on NotifyException {
      rethrow;
    } on Object catch (e) {
      throw NotifyException('ntfy not reachable: $e');
    } finally {
      client.close(force: true);
    }
  }

  static String _short(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s.trim();
}
