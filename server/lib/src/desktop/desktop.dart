import 'dart:convert';
import 'dart:io';

import '../api/embedded_web.dart';
import '../storage/app_database.dart';
import 'build_info.g.dart';
import 'win32.dart' as win32;

/// Packaged desktop build (Windows exe with tray icon, macOS app bundle).
/// These builds embed the web UI and keep their config in the user profile.
enum DesktopPlatform {
  windows,
  macos;

  /// Null for development and the Linux (server) build.
  static DesktopPlatform? get current {
    if (embeddedWebFiles.isEmpty) return null;
    if (Platform.isWindows) return windows;
    if (Platform.isMacOS) return macos;
    return null;
  }
}

/// Exit code: invalid configuration (EX_CONFIG).
const exitConfigInvalid = 78;

/// Per-user directory for config, database and log:
/// `%LOCALAPPDATA%\schulportal-client` or
/// `~/Library/Application Support/schulportal-client`.
String desktopDataDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final base = env['LOCALAPPDATA'] ?? env['APPDATA'] ?? '.';
    return '$base\\schulportal-client';
  }
  return '${env['HOME'] ?? '.'}/Library/Application Support/schulportal-client';
}

/// Optional config file of the desktop builds (ENV_FILE overrides it).
String desktopConfigPath() =>
    Platform.environment['ENV_FILE'] ??
    '${desktopDataDir()}${Platform.pathSeparator}config.env';

/// Defaults of the desktop builds: data in the user profile, open the
/// browser on start. Values from the environment / config.env win.
Map<String, String> withDesktopDefaults(Map<String, String> env) => {
  'DATA_DIR': desktopDataDir(),
  'OPEN_BROWSER': 'true',
  ...env,
};

/// Opens [url] in the default browser.
Future<void> openInBrowser(Uri url) async {
  if (Platform.isWindows) {
    win32.shellOpen(url.toString());
  } else if (Platform.isMacOS) {
    await Process.run('open', [url.toString()]);
  } else {
    await Process.run('xdg-open', [url.toString()]);
  }
}

/// `server check`: verifies that the build works on this machine (SQLite
/// library, embedded files, Win32 functions). Used by the release workflow.
Future<int> runSelfCheck({bool expectEmbedded = false}) async {
  final out = <String>[];
  var ok = true;

  final dir = Directory.systemTemp.createTempSync('sph_check_');
  try {
    final db = AppDatabase.open('${dir.path}/check.db');
    db.close();
    out.add('sqlite: ${AppDatabase.sqliteVersion}');
  } on Object catch (e) {
    ok = false;
    out.add('sqlite: FAILED $e');
  } finally {
    dir.deleteSync(recursive: true);
  }

  final web = EmbeddedWeb.fromBase64(embeddedWebFiles);
  out.add('embedded web files: ${web.length}');
  if (expectEmbedded && (web.isEmpty || buildVersion == null)) {
    ok = false;
    out.add('embedded web UI / build version missing');
  }
  out.add('version: ${buildVersion ?? 'dev'}');

  if (Platform.isWindows) {
    try {
      out.add('win32 functions: ${win32.resolveAll().length}');
      if (expectEmbedded && base64.decode(trayIconPng).isEmpty) {
        throw StateError('tray icon missing');
      }
    } on Object catch (e) {
      ok = false;
      out.add('win32: FAILED $e');
    }
  }

  out.add(ok ? 'ok' : 'FAILED');
  stdout.writeln(out.join('\n'));
  return ok ? 0 : 1;
}
