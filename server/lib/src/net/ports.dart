import 'dart:io';

/// Why the server could not listen on [port], or null when it can.
///
/// Only ports below 1024 are probed: they are refused for normal users on
/// Linux (the systemd service has no `CAP_NET_BIND_SERVICE`), and a refused
/// port after a restart would leave the server unreachable.
Future<String?> portProblem(int port) async {
  if (port >= 1024) return null;
  try {
    final s = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await s.close();
    return null;
  } on SocketException catch (e) {
    final reason = e.osError?.message.trim();
    return 'PORT $port cannot be used: ports below 1024 are not allowed for '
        'this server (${reason == null || reason.isEmpty ? e.message : reason}). '
        'Use a port from 1024';
  }
}
