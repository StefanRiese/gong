# Desktop apps (Windows, macOS)

The Windows and macOS releases run the same server as the Linux build, packaged as a desktop
app with an icon in the notification area (Windows) or menu bar (macOS). The web UI is built in;
it opens in the default browser.

| | Windows | macOS |
|---|---|---|
| Download | `schulportal-client-windows-x64.exe` (single file) | `schulportal-client-macos-universal.zip` (Apple Silicon + Intel) |
| Requires | Windows 10/11 x64 | macOS 11 or newer |
| Config | `%LOCALAPPDATA%\schulportal-client\config.env` | `~/Library/Application Support/schulportal-client/config.env` |
| Data (database) | same folder | same folder |
| Log | `%LOCALAPPDATA%\schulportal-client\schulportal-client.log` | `~/Library/Logs/Schulportal-Client.log` |

## First start

1. **Windows:** start the exe. SmartScreen warns about an unknown publisher (the exe is not
   code-signed): *Weitere Informationen → Trotzdem ausführen*. You can put the exe anywhere,
   e.g. `C:\Users\<name>\Programme\`.
   **macOS:** unzip, move *Schulportal-Client* to *Programme*, then **right click → Öffnen**
   (the app is signed ad hoc, not notarized; a double click is blocked the first time).
2. The app creates `config.env` and opens it in Notepad / TextEdit. Fill in:
   - `SPH_SCHOOL_ID`, `SPH_USERNAME`, `SPH_PASSWORD` – the Schulportal login
   - `APP_PASSWORD` – a password for the web UI (min. 8 characters). On the next start it is
     replaced by `APP_PASSWORD_HASH`; to change it, enter a new `APP_PASSWORD`.
3. Save and start the app again. The web UI opens in the browser (`OPEN_BROWSER=true`).

## Menu

Right click on the icon (macOS: click):

- **Schulportal-Client öffnen** – web UI in the browser (Windows: also double click on the icon)
- **Einstellungen bearbeiten** – opens `config.env`; afterwards choose *Neu starten*
- **Protokoll anzeigen** – log file
- **Neu starten**, **Beenden**

Starting the app a second time opens the web UI instead of a second server.

## Notes

- By default the web UI is only reachable on this computer (`HOST=127.0.0.1`). With
  `HOST=0.0.0.0` phones in the same network can use it too (Windows asks to allow it in the
  firewall); use `http://<computer-ip>:8080`.
- Push notifications (ntfy) work as on the server, see [README.md](README.md#push-notifications-ntfy).
  They only arrive while the computer and the app are running – for notifications around the
  clock use the LXC installation.
- **Autostart** – Windows: put a shortcut to the exe into `shell:startup` (Win+R).
  macOS: *Systemeinstellungen → Allgemein → Anmeldeobjekte → +*.
- **Uninstall** – delete the exe / app and the config folder from the table above.
- The Windows build uses the SQLite library that ships with Windows (`winsqlite3.dll`); the
  macOS app bundles its own.

## How it is built

- `deploy/build-release.sh` on Windows embeds the web UI and tray icon
  (`server/tool/embed_assets.dart`), builds `server.exe` with `winsqlite3` instead of a bundled
  SQLite (hook user define), runs `server check --desktop` and marks the exe as GUI application
  (`server/tool/set_gui_subsystem.dart`). The tray icon is implemented with Win32 calls via
  `dart:ffi` (`server/lib/src/desktop/`).
- On macOS it builds the server per architecture; `deploy/build-macos-app.sh` merges the arm64
  and x64 builds with `lipo`, compiles the menu bar app (`deploy/macos/main.swift`) for both
  architectures and assembles `Schulportal-Client.app`. The menu bar app starts the server
  (`Contents/Resources/bin/server`) as child process with `ENV_FILE` set.
- The release workflow builds macOS arm64 on `macos-latest` and x64 on `macos-15-intel`, then
  merges them in the `macos-app` job.
