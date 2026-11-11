// HTTP server for lumo.
//
// Configuration via environment variables or server/.env (see .env.example);
// settings made in the web UI (setup page, Einstellungen) are stored
// in the database and take precedence.
//
//   server            run the server
//   server check      verify the build (SQLite, embedded files); for CI
//   server version    print the version
//
// The Windows desktop build runs as tray app (see lib/src/desktop/), the
// macOS desktop build is started by the menu bar app (deploy/macos/).

import 'dart:async';
import 'dart:io';

import 'package:lumo_server/desktop.dart';
import 'package:lumo_server/lumo_server.dart';

Future<void> main(List<String> args) async {
  // An error nobody caught would end the process with a bare stack trace;
  // this puts it into the log (journalctl) first.
  await runZonedGuarded(() => _run(args), (error, stack) {
    _log('Unhandled error: $error\n$stack', true);
    exit(70); // EX_SOFTWARE
  });
}

Future<void> _run(List<String> args) async {
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
  try {
    if (hashPlainPasswordInFile(envFile)) {
      _log('Replaced APP_PASSWORD with APP_PASSWORD_HASH in $envFile', false);
    }
  } on FileSystemException catch (e) {
    _log('Cannot update $envFile (${e.message}); hashing in memory', true);
  }
  var env = loadEnv(path: envFile);
  if (desktop != null) env = withDesktopDefaults(env);

  final done = Completer<void>();
  late final AppServer server;
  try {
    server = await AppServer.start(
      env,
      log: _logRaw,
      // macOS app: the menu bar app swaps the bundle after this exit code.
      onUpdateReady: desktop == DesktopPlatform.macos
          ? () async {
              _log('Update ready, exiting for the menu bar app', false);
              await server.stop();
              exit(exitUpdateReady);
            }
          : null,
      // The macOS menu bar app starts it again, systemd restarts the service
      // (INVOCATION_ID is set for services); elsewhere it is not offered.
      onRestart:
          desktop == DesktopPlatform.macos ||
              (desktop == null && Platform.environment['INVOCATION_ID'] != null)
          ? () async {
              _log('Restarting', false);
              await server.stop();
              exit(exitRestart);
            }
          : null,
    );
  } on AppServerException catch (e) {
    stderr.writeln(e);
    exit(e.exitCode);
  } on SocketException catch (e) {
    stderr.writeln('Cannot listen: $e');
    exit(69); // EX_UNAVAILABLE
  }
  // The macOS menu bar app reads this line.
  if (desktop != null) _log('Web UI: ${server.localUrl}', false);
  final setup = server.setupUrl;
  if (setup != null && desktop != null) {
    await openInBrowser(setup);
  } else if (setup == null && server.config.openBrowser) {
    await openInBrowser(server.localUrl);
  }

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
