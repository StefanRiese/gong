# schulportal-client

A self-hosted client for **Schulportal Hessen**: a Dart server (using
[liblanis](https://pub.dev/packages/liblanis)) plus a web UI for Stundenplan, Vertretungsplan,
Hausaufgaben, Noten, Kalender and Nachrichten.

> **Status:** planning. See [docs/PLAN.md](docs/PLAN.md).

## Goals

- Log in to Schulportal Hessen and keep the session alive
- Show Stundenplan, Vertretungsplan, Hausaufgaben, Noten, Klausuren, Kalender and Nachrichten
- Notify about new homework, grades and substitutions
- Native binary for Windows, Linux and macOS; deployed as a systemd service in a Proxmox LXC container

## Project structure

```
schulportal-client/
├── server/     # Dart backend (uses liblanis)
├── web/        # Web UI
├── deploy/     # systemd unit and install script for the LXC container
└── docs/       # Plan and design notes
```

## Getting started

Build and usage instructions will follow with the first implementation milestone.

## License

GPL-3.0 (required by the liblanis dependency). See [LICENSE](LICENSE).
