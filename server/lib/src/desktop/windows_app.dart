import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_config.dart';
import '../config/config_file.dart';
import '../config/env.dart';
import '../server/app_server.dart';
import 'build_info.g.dart';
import 'desktop.dart';
import 'win32.dart';
import 'windows_tray.dart';

const _title = 'Schulportal-Client';

/// Windows desktop build: GUI subsystem (no console), tray icon, log file and
/// config in %LOCALAPPDATA%\schulportal-client. Never returns.
Future<Never> runWindowsApp(List<String> args) async {
  final dir = desktopDataDir();
  Directory(dir).createSync(recursive: true);
  final configPath = desktopConfigPath();
  final logPath = '$dir\\schulportal-client.log';
  final log = _openLog(logPath);

  // Without a console, writes to stdout/stderr fail: route print() and
  // uncaught errors to the log file.
  // Uncaught errors end the process, as in the console build.
  return await runZonedGuarded(
    () => _run(args, configPath, logPath, log),
    (e, s) async {
      log.write('${DateTime.now().toIso8601String()} Uncaught error: $e\n$s\n');
      await log.flush();
      exit(70); // EX_SOFTWARE
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => log.write('$line\n'),
    ),
  )!;
}

Future<Never> _run(
  List<String> args,
  String configPath,
  String logPath,
  IOSink log,
) async {
  void logLine(String line, bool isError) => log.write('$line\n');
  void info(String m) =>
      logLine('${DateTime.now().toIso8601String()} $m', false);

  Future<Never> quit(int code) async {
    await log.flush();
    await log.close();
    exit(code);
  }

  // --- first start: create the config and open it in Notepad ---------------
  if (!File(configPath).existsSync()) {
    createDesktopConfig(configPath);
    info('Created $configPath');
    messageBox(
      'Willkommen beim Schulportal-Client!\n\n'
      'Die Einstellungen werden jetzt im Editor geöffnet. Bitte die '
      'Zugangsdaten für das Schulportal und ein Passwort für die '
      'Web-Oberfläche eintragen, speichern und den Schulportal-Client '
      'erneut starten.\n\n$configPath',
      _title,
      MB_OK | MB_ICONINFORMATION,
    );
    openInNotepad(configPath);
    await quit(exitConfigCreated);
  }

  try {
    if (hashPlainPasswordInFile(configPath)) {
      info('Replaced APP_PASSWORD with APP_PASSWORD_HASH in $configPath');
    }
  } on FileSystemException catch (e) {
    info('Cannot update $configPath: ${e.message}');
  }

  final AppConfig config;
  try {
    config = AppConfig.fromEnv(loadEnv(path: configPath));
  } on ConfigException catch (e) {
    info('$e');
    final answer = messageBox(
      'Die Einstellungen sind unvollständig oder fehlerhaft:\n\n'
      '${e.problems.map((p) => '•  $p').join('\n')}\n\n'
      'Einstellungen jetzt öffnen? Nach dem Speichern den '
      'Schulportal-Client erneut starten.',
      _title,
      MB_YESNO | MB_ICONWARNING,
    );
    if (answer == IDYES) openInNotepad(configPath);
    await quit(exitConfigInvalid);
  }

  // --- one instance per user: a second start opens the browser --------------
  var single = acquireSingleInstanceMutex(r'Local\SchulportalClient');
  // After "Neu starten" the old process may still be shutting down.
  for (var i = 0; !single && args.contains('--restarted') && i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    single = acquireSingleInstanceMutex(r'Local\SchulportalClient');
  }

  final AppServer server;
  try {
    if (!single) throw const _AlreadyRunning();
    server = await AppServer.start(config, log: logLine);
  } on _AlreadyRunning {
    info('Already running, opening the web UI');
    await openInBrowser(AppServer.localUrlFor(config.host, config.port));
    await quit(0);
  } on AppServerException catch (e) {
    info('$e');
    messageBox(
      'Der Schulportal-Client konnte nicht starten:\n\n${e.message}',
      _title,
      MB_OK | MB_ICONERROR,
    );
    await quit(e.exitCode);
  } on SocketException catch (e) {
    info('Cannot listen on ${config.host}:${config.port}: $e');
    messageBox(
      'Port ${config.port} ist bereits belegt.\n\n'
      'In den Einstellungen unter PORT einen anderen Port eintragen '
      '(z. B. 8090) und den Schulportal-Client erneut starten.',
      _title,
      MB_OK | MB_ICONERROR,
    );
    openInNotepad(configPath);
    await quit(1);
  }

  final url = server.localUrl;
  info('Web UI: $url');

  // Startup hint once, so the tray icon is not overlooked.
  final hintMarker = File('${config.dataDir}\\.tray-hint-shown');
  final showHint = !hintMarker.existsSync();
  if (showHint) {
    try {
      hintMarker.writeAsStringSync('');
    } on FileSystemException {
      // Hint shows again next time; not worth an error.
    }
  }

  final stopped = Completer<TrayCommand>();
  WindowsTray? tray;
  try {
    tray = await WindowsTray.start(
      url: url.toString(),
      configPath: configPath,
      logPath: logPath,
      iconPng: base64.decode(trayIconPng),
      startupHint: showHint
          ? 'Läuft im Infobereich. Rechtsklick auf das Symbol für das Menü.'
          : null,
      onCommand: (c) {
        if (!stopped.isCompleted) stopped.complete(c);
      },
      onError: info,
    );
  } on Object catch (e) {
    info('Tray icon failed: $e');
    messageBox(
      'Das Symbol im Infobereich konnte nicht angezeigt werden. Der '
      'Schulportal-Client läuft trotzdem unter $url (Beenden über den '
      'Task-Manager).',
      _title,
      MB_OK | MB_ICONWARNING,
    );
  }

  if (config.openBrowser) await openInBrowser(url);

  final command = await stopped.future;
  info('${command == TrayCommand.restart ? 'Restarting' : 'Quitting'} …');
  await tray?.close();
  await server.stop();
  if (command == TrayCommand.restart) {
    await Process.start(Platform.resolvedExecutable, [
      '--restarted',
    ], mode: ProcessStartMode.detached);
  }
  await quit(0);
}

class _AlreadyRunning implements Exception {
  const _AlreadyRunning();
}

/// Appends to the log file; keeps one old file when it grows above 2 MB.
IOSink _openLog(String path) {
  final file = File(path);
  try {
    if (file.existsSync() && file.lengthSync() > 2 * 1024 * 1024) {
      file.renameSync('$path.old');
    }
  } on FileSystemException {
    // Keep appending.
  }
  final sink = file.openWrite(mode: FileMode.append);
  sink.write(
    '${DateTime.now().toIso8601String()} Schulportal-Client '
    '${buildVersion ?? 'dev'} starting\n',
  );
  return sink;
}
