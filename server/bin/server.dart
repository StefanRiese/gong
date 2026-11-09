// HTTP server for schulportal-client.
//
// Configuration via environment variables or server/.env (see .env.example).
//
//   server            run the server
//   server check      verify the build (SQLite, embedded files); for CI
//   server version    print the version
//
// The Windows desktop build runs as tray app (see lib/src/desktop/), the
// macOS desktop build is started by the menu bar app (deploy/macos/).

import 'dart:async';
import 'dart:io';

import 'package:schulportal_server/desktop.dart';
import 'package:schulportal_server/schulportal_server.dart';

Future<void> main(List<String> args) async {
  switch (args.firstOrNull) {
    case 'check':
      exit(await runSelfCheck(expectEmbedded: args.contains('--desktop')));
    case 'version' || '--version':
      stdout.writeln(buildVersion ?? 'dev');
      exit(0);
  }

  final desktop = DesktopPlatform.current;
  if (desktop == DesktopPlatform.windows) await runWindowsApp(args);

  final envFile = desktop == DesktopPlatform.macos
      ? desktopConfigPath()
      : Platform.environment['ENV_FILE'] ?? '.env';
  if (desktop == DesktopPlatform.macos && !File(envFile).existsSync()) {
    createDesktopConfig(envFile);
    stderr.writeln('Created $envFile – fill in and start again.');
    exit(exitConfigCreated);
  }

  try {
    if (hashPlainPasswordInFile(envFile)) {
      _log('Replaced APP_PASSWORD with APP_PASSWORD_HASH in $envFile', false);
    }
  } on FileSystemException catch (e) {
    _log('Cannot update $envFile (${e.message}); hashing in memory', true);
  }

  final AppConfig config;
  try {
    config = AppConfig.fromEnv(loadEnv(path: envFile));
  } on ConfigException catch (e) {
    stderr.writeln(e);
    exit(exitConfigInvalid);
  }

  final AppServer server;
  try {
    server = await AppServer.start(config, log: _logRaw);
  } on AppServerException catch (e) {
    stderr.writeln(e);
    exit(e.exitCode);
  } on SocketException catch (e) {
    stderr.writeln('Cannot listen on ${config.host}:${config.port}: $e');
    exit(69); // EX_UNAVAILABLE
  }
  if (desktop != null) _log('Web UI: ${server.localUrl}', false);
  if (config.openBrowser) await openInBrowser(server.localUrl);

  final done = Completer<void>();
  Future<void> shutdown(ProcessSignal signal) async {
    if (done.isCompleted) return;
    _log('Received $signal, shutting down', false);
    await server.stop();
    done.complete();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
  await done.future;
  exit(0);
}

void _log(String message, bool isError) =>
    _logRaw('${DateTime.now().toIso8601String()} $message', isError);

/// shelf's request log lines already start with a timestamp.
void _logRaw(String line, bool isError) =>
    isError ? stderr.writeln(line) : stdout.writeln(line);
