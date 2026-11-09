# schulportal-client

A self-hosted client for **Schulportal Hessen**: a Dart server (using
[liblanis](https://pub.dev/packages/liblanis)) plus a web UI for Stundenplan, Vertretungsplan,
Hausaufgaben, Noten, Kalender and Nachrichten.

> **Status:** working server, web UI, push notifications (ntfy) and LXC deployment. See [docs/PLAN.md](docs/PLAN.md).

## Goals

- Log in to Schulportal Hessen and keep the session alive
- Show Stundenplan, Vertretungsplan, Hausaufgaben, Noten, Klausuren, Kalender and Nachrichten
- Push notifications (ntfy) about new substitutions, homework and grades
- Native binary for Linux, deployed as a systemd service in a Proxmox LXC container
- Desktop apps for Windows (single exe, tray icon) and macOS (universal app, menu bar icon)

## Project structure

```
schulportal-client/
├── server/     # Dart backend (uses liblanis)
├── web/        # Web UI (plain HTML/CSS/JS, no build step)
├── dev/        # Mock API server for UI development
├── deploy/     # systemd unit, install script, release build (see deploy/README.md)
└── docs/       # Plan and design notes
```

## Installation (Proxmox LXC / Debian)

```sh
curl -fsSLO https://raw.githubusercontent.com/StefanRiese/schulportal-client/main/deploy/install.sh
bash install.sh
```

Then open the setup link that `install.sh` prints and set up school, Schulportal login and the
web UI password in the browser. Full guide: [deploy/README.md](deploy/README.md).

## Windows / macOS

Download `schulportal-client-windows-x64.exe` or `schulportal-client-macos-universal.zip` from the
[releases](https://github.com/StefanRiese/schulportal-client/releases). The app runs in the
notification area / menu bar; right click on the icon to open the web UI. See
[deploy/DESKTOP.md](deploy/DESKTOP.md).

## Development

```sh
cd server
cp .env.example .env               # fill in SPH_USERNAME / SPH_PASSWORD
dart run bin/hash_password.dart    # paste APP_PASSWORD_HASH=… into .env
WEB_DIR=../web dart run bin/server.dart
```

Then open http://127.0.0.1:8080. Details: [server/README.md](server/README.md),
[web/README.md](web/README.md).

UI development without Schulportal: `node dev/mock-server.mjs` (password `demo`).

## License

GPL-3.0 (required by the liblanis dependency). See [LICENSE](LICENSE).
