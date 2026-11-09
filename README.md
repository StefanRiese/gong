<p align="center">
  <img src="deploy/desktop/app-icon-macos.png" alt="" width="128" height="128">
</p>

<h1 align="center">schulportal-client</h1>

<p align="center">
  <a href="https://github.com/StefanRiese/schulportal-client/actions/workflows/ci.yml"><img src="https://github.com/StefanRiese/schulportal-client/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/StefanRiese/schulportal-client/actions/workflows/release.yml"><img src="https://github.com/StefanRiese/schulportal-client/actions/workflows/release.yml/badge.svg?event=push" alt="Release build"></a>
  <a href="https://github.com/StefanRiese/schulportal-client/releases/latest"><img src="https://img.shields.io/github/v/release/StefanRiese/schulportal-client" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/StefanRiese/schulportal-client" alt="License: GPL-3.0"></a>
</p>

A self-hosted client for **Schulportal Hessen**: a Dart server (using
[liblanis](https://pub.dev/packages/liblanis)) plus a web UI for Stundenplan, Vertretungsplan,
Hausaufgaben, Noten, Klausuren and Kalender.

> **Status:** in use. Server with background sync, web UI, push notifications (ntfy), setup in
> the browser, LXC deployment and desktop apps for Windows and macOS. See
> [CHANGELOG.md](CHANGELOG.md) and [docs/PLAN.md](docs/PLAN.md).

## Features

- Logs in to Schulportal Hessen and keeps all data in sync in the background (substitutions and
  homework every 15 min, grades and course pages every 2 h, during active hours)
- Pages open right away from the stored data – also after a restart and while the portal is
  down; open pages update themselves when new data arrives
- Heute, Stundenplan (A/B weeks), Vertretungen, Hausaufgaben (mark as done in the portal),
  Noten, Fächer / course pages, Kalender with filters; consistent subject colors
- Push notifications (ntfy) about new substitutions, homework and grades
- Setup and all settings in the web UI (school search, login test, password, sync,
  notifications, network); responsive, dark mode, installable as an app
- Linux server (systemd service in a Proxmox LXC container) and desktop apps for Windows
  (single exe, tray icon) and macOS (universal app, menu bar icon)

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
WEB_DIR=../web dart run bin/server.dart
```

Without credentials the server starts in setup mode and logs a setup link
(`http://127.0.0.1:8080/einrichtung?token=…`); the settings are stored in the database next to it.
Alternatively, put `SPH_USERNAME`, `SPH_PASSWORD` and `APP_PASSWORD` into `server/.env`
(see `server/.env.example`). Details: [server/README.md](server/README.md) (incl. the API),
[web/README.md](web/README.md).

UI development without Schulportal: `node dev/mock-server.mjs` (password `demo`;
`MOCK_SETUP=1` shows the setup page).

## License

GPL-3.0 (required by the liblanis dependency). See [LICENSE](LICENSE).
