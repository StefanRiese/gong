# schulportal-client

A self-hosted client for **Schulportal Hessen**: a Dart server (using
[liblanis](https://pub.dev/packages/liblanis)) plus a web UI for Stundenplan, Vertretungsplan,
Hausaufgaben, Noten, Kalender and Nachrichten.

> **Status:** working server and web UI; deployment (LXC) and notifications next. See [docs/PLAN.md](docs/PLAN.md).

## Goals

- Log in to Schulportal Hessen and keep the session alive
- Show Stundenplan, Vertretungsplan, Hausaufgaben, Noten, Klausuren, Kalender and Nachrichten
- Notify about new homework, grades and substitutions
- Native binary for Windows, Linux and macOS; deployed as a systemd service in a Proxmox LXC container

## Project structure

```
schulportal-client/
├── server/     # Dart backend (uses liblanis)
├── web/        # Web UI (plain HTML/CSS/JS, no build step)
├── dev/        # Mock API server for UI development
├── deploy/     # systemd unit and install script for the LXC container
└── docs/       # Plan and design notes
```

## Getting started

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
