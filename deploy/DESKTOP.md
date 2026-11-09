# Desktop apps (Windows, macOS)

The Windows and macOS releases run the same server as the Linux build, packaged as a desktop
app with an icon in the notification area (Windows) or menu bar (macOS). The web UI is built in;
it opens in the default browser.

| | Windows | macOS |
|---|---|---|
| Download | `ranzen-windows-x64.exe` (single file) | `ranzen-macos-universal.zip` (Apple Silicon + Intel) |
| Requires | Windows 10/11 x64 | macOS 11 or newer |
| Data (database, settings) | `%LOCALAPPDATA%\ranzen` | `~/Library/Application Support/ranzen` |
| Optional config file | `config.env` in that folder | `config.env` in that folder |
| Log | `%LOCALAPPDATA%\ranzen\ranzen.log` | `~/Library/Logs/Ranzen.log` |

## First start

1. **Windows:** start the exe. SmartScreen warns about an unknown publisher (the exe is not
   code-signed): *Weitere Informationen → Trotzdem ausführen*. You can put the exe anywhere,
   e.g. `C:\Users\<name>\Programme\`.
   **macOS:** unzip, move *Ranzen* to *Programme*, then **right click → Öffnen**
   (the app is signed ad hoc, not notarized; a double click is blocked the first time).
2. The browser opens the **setup page** („Ranzen einrichten“):
   - choose the school (search by name, town or school number),
   - enter the Schulportal username and password („Anmeldung prüfen“ tests them),
   - choose a password for the web UI (min. 8 characters).
3. „Einrichtung abschließen“ – the web UI opens, already logged in.

Everything can be changed later in the web UI under *Einstellungen → Server* (also reachable
from the tray / menu bar menu). Settings are stored in the database; a text editor is not needed.

## Menu

Right click on the icon (macOS: click):

- **Ranzen öffnen** – web UI in the browser (Windows: also double click on the icon)
- **Einstellungen** – server settings in the web UI (Schulportal login, password, sync,
  notifications, network)
- **Protokoll anzeigen** – log file
- **Neu starten**, **Beenden**

Starting the app a second time opens the web UI instead of a second server.

## Notes

- By default the web UI is only reachable on this computer. *Einstellungen → Server →
  Netzwerk → „Auch von anderen Geräten im Netzwerk“* (then *Neu starten*) lets phones in the
  same network use it too (Windows asks to allow it in the firewall): `http://<computer-ip>:8080`.
- If port 8080 is taken by another program, the app offers to open `config.env`: enter e.g.
  `PORT=8090` and start again. `config.env` is optional and only needed for such cases; values
  set in the web UI take precedence over it.
- Push notifications (ntfy) work as on the server, see [README.md](README.md#push-notifications-ntfy).
  They only arrive while the computer and the app are running – for notifications around the
  clock use the LXC installation.
- **Updates** – the app checks GitHub for new versions and shows a notice in the web UI.
  *Einstellungen → Server → Update → „Jetzt aktualisieren“* downloads the new version, checks
  its SHA-256 and restarts the app (Windows: the exe replaces itself; macOS: the menu bar app
  swaps the app bundle – if that is not allowed, e.g. without write access to *Programme*, it
  opens the download page instead).
- **Autostart** – Windows: put a shortcut to the exe into `shell:startup` (Win+R).
  macOS: *Systemeinstellungen → Allgemein → Anmeldeobjekte → +*.
- **Uninstall** – delete the exe / app and the data folder from the table above.
- The Windows build uses the SQLite library that ships with Windows (`winsqlite3.dll`); the
  macOS app bundles its own.

## How it is built

- `deploy/build-release.sh` on Windows embeds the web UI and tray icon
  (`server/tool/embed_assets.dart`), builds `server.exe` with `winsqlite3` instead of a bundled
  SQLite (hook user define), writes `deploy/desktop/app-icon.ico` into the exe
  (`server/tool/set_exe_icon.dart`), runs `server check --desktop` and marks the exe as GUI application
  (`server/tool/set_gui_subsystem.dart`). The tray icon is implemented with Win32 calls via
  `dart:ffi` (`server/lib/src/desktop/`).
- On macOS it builds the server per architecture; `deploy/build-macos-app.sh` compiles the
  menu bar app (`deploy/macos/main.swift`) as universal binary, merges SQLite with `lipo` and
  puts both servers into the bundle as `Contents/Resources/bin/server-arm64` / `server-x86_64`
  (Dart AOT executables cannot be merged with `lipo`: the Dart program is appended to the
  runtime and would be lost). The menu bar app starts the server of its own architecture as
  child process with `ENV_FILE` set.
- The release workflow builds macOS arm64 on `macos-latest` and x64 on `macos-15-intel`, then
  merges them in the `macos-app` job.
- Icons: `python3 deploy/desktop/make-icons.py` (Pillow) regenerates all icon files in
  `deploy/desktop/` (exe `.ico`, tray PNG, macOS app icon source, menu bar template images);
  the generated files are committed.
