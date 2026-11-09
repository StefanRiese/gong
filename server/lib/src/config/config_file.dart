import 'dart:io';

import '../auth/password.dart';
import 'env.dart';

/// Replaces a plain-text `APP_PASSWORD=…` in the config file at [path] with
/// `APP_PASSWORD_HASH=…`, so the password is not stored in clear text.
///
/// Returns true if the file was changed. Throws [FileSystemException] if the
/// file cannot be written (the server then hashes the password in memory).
bool hashPlainPasswordInFile(String path, {int? iterations}) {
  final file = File(path);
  if (!file.existsSync()) return false;
  final lines = file.readAsLinesSync();

  int? plainLine, hashLine;
  String? plain;
  for (var i = 0; i < lines.length; i++) {
    final entry = parseEnvLine(lines[i]);
    if (entry == null) continue;
    if (entry.key == 'APP_PASSWORD' && entry.value.isNotEmpty) {
      plainLine = i;
      plain = entry.value;
    } else if (entry.key == 'APP_PASSWORD_HASH') {
      hashLine = i;
    }
  }
  // Too short: leave it, AppConfig reports the problem.
  if (plain == null || plain.length < 8) return false;

  final hash = iterations == null
      ? PasswordHasher.hash(plain)
      : PasswordHasher.hash(plain, iterations: iterations);
  lines[plainLine!] = 'APP_PASSWORD=';
  if (hashLine != null) {
    lines[hashLine] = 'APP_PASSWORD_HASH=$hash';
  } else {
    lines.insert(plainLine + 1, 'APP_PASSWORD_HASH=$hash');
  }

  final tmp = File('$path.tmp');
  tmp.writeAsStringSync('${lines.join(_eol(file))}${_eol(file)}', flush: true);
  tmp.renameSync(path);
  return true;
}

/// Keeps Windows line endings in files edited with Notepad.
String _eol(File file) =>
    file.readAsStringSync().contains('\r\n') ? '\r\n' : '\n';

/// Config file written on the first start of the desktop builds.
/// [dataDir] is where the database and log file go.
String desktopConfigTemplate({required String dataDir, String eol = '\n'}) =>
    '''
# Schulportal-Client – Einstellungen
#
# 1. Zugangsdaten für das Schulportal eintragen.
# 2. Unter APP_PASSWORD ein Passwort für die Web-Oberfläche festlegen
#    (mind. 8 Zeichen). Beim Start wird es durch APP_PASSWORD_HASH ersetzt.
#    Zum Ändern einfach wieder ein neues APP_PASSWORD eintragen.
# 3. Datei speichern und Schulportal-Client erneut starten.

# --- Schulportal Hessen ---------------------------------------------------------
SPH_SCHOOL_ID=6128
SPH_USERNAME=
SPH_PASSWORD=

# --- Web-Oberfläche ---------------------------------------------------------------
APP_PASSWORD=
APP_PASSWORD_HASH=
# 127.0.0.1 = nur dieser Rechner; 0.0.0.0 = auch andere Geräte im Netzwerk
HOST=127.0.0.1
PORT=8080
# Web-Oberfläche beim Start im Browser öffnen
OPEN_BROWSER=true
# Tage, die eine Anmeldung in der Web-Oberfläche gültig bleibt
SESSION_TTL_DAYS=30

# --- Daten ------------------------------------------------------------------------
DATA_DIR=$dataDir

# --- Push-Benachrichtigungen über ntfy (leeres NTFY_TOPIC = aus) -------------------
# Auf ntfy.sh kann jeder mitlesen, der das Topic kennt: langen Zufallsnamen wählen.
NTFY_URL=https://ntfy.sh
NTFY_TOPIC=
NTFY_TOKEN=
# Adresse der Web-Oberfläche für Links in Benachrichtigungen
APP_URL=
# substitutions, homework, grades (durch Komma getrennt)
NOTIFY=substitutions,homework,grades
POLL_INTERVAL_MINUTES=20
GRADES_INTERVAL_MINUTES=120
ACTIVE_HOURS=6-22
NOTIFY_GRADE_VALUES=false
'''
        .replaceAll('\n', eol);
