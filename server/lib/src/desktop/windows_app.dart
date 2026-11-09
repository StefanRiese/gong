import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  // config.env is optional (advanced settings); the normal way to configure
  // is the setup page / „Einstellungen → Server“ in the web UI.
  try {
    if (hashPlainPasswordInFile(configPath)) {
      info('Replaced APP_PASSWORD with APP_PASSWORD_HASH in $configPath');
    }
  } on FileSystemException catch (e) {
    info('Cannot update $configPath: ${e.message}');
  }
  final env = withDesktopDefaults(loadEnv(path: configPath));
  final urlFile = File('${env['DATA_DIR']}\\last-url');

  // --- one instance per user: a second start opens the browser --------------
  var single = acquireSingleInstanceMutex(r'Local\SchulportalClient');
  // After "Neu starten" the old process may still be shutting down.
  for (var i = 0; !single && args.contains('--restarted') && i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    single = acquireSingleInstanceMutex(r'Local\SchulportalClient');
  }
  if (!single) {
    info('Already running, opening the web UI');
    final last = urlFile.existsSync() ? urlFile.readAsStringSync().trim() : '';
    await openInBrowser(
      Uri.tryParse(last) ?? Uri.parse('http://127.0.0.1:8080/'),
    );
    await quit(0);
  }

  final AppServer server;
  try {
    server = await AppServer.start(env, log: logLine);
  } on AppServerException catch (e) {
    info('$e');
    final answer = messageBox(
      'Der Schulportal-Client konnte nicht starten:\n\n${e.message}\n\n'
      'Konfigurationsdatei öffnen?\n$configPath',
      _title,
      MB_YESNO | MB_ICONERROR,
    );
    if (answer == IDYES) _openConfigFile(configPath);
    await quit(e.exitCode);
  } on SocketException catch (e) {
    info('Cannot listen: $e');
    final answer = messageBox(
      'Der Port der Web-Oberfläche ist bereits belegt (läuft ein anderes '
      'Programm auf Port 8080?).\n\n'
      'In der Konfigurationsdatei einen anderen Port eintragen, z. B. '
      'PORT=8090, und den Schulportal-Client erneut starten.\n\n'
      'Konfigurationsdatei jetzt öffnen?',
      _title,
      MB_YESNO | MB_ICONERROR,
    );
    if (answer == IDYES) _openConfigFile(configPath);
    await quit(1);
  }
  final config = server.config;

  final url = server.localUrl;
  info('Web UI: $url');
  try {
    urlFile.writeAsStringSync('$url\n');
  } on FileSystemException {
    // A second start then opens the default address.
  }

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
      settingsUrl: url.resolve('einstellungen/server').toString(),
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

  final setup = server.setupUrl;
  if (setup != null) {
    await openInBrowser(setup); // first start: setup page
  } else if (config.openBrowser) {
    await openInBrowser(url);
  }

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

/// Opens config.env in Notepad (created with a short header if missing).
void _openConfigFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '# Schulportal-Client – erweiterte Einstellungen (optional).\r\n'
      '# Normalerweise werden alle Einstellungen in der Web-Oberfläche\r\n'
      '# vorgenommen (Einstellungen → Server). Beispiel:\r\n'
      '# PORT=8090\r\n',
    );
  }
  openInNotepad(path);
}
