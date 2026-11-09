# Plan: Schulportal Hessen Client

Goal: a self-hosted client for **Schulportal Hessen** (school ID `6128`, login at
`https://login.schulportal.hessen.de/?i=6128`) that shows Stundenplan, Vertretungsplan,
Hausaufgaben, Noten, Kalender and Nachrichten in a clean, fast web UI.

## Decisions

| Topic | Decision |
|---|---|
| Architecture | **Self-hosted server + web UI** (option A, see below) |
| Language (backend) | **Dart** |
| Portal access | **[liblanis](https://pub.dev/packages/liblanis)** from the lanis-mobile project |
| License | **GPL-3.0** (required because liblanis is GPL-3.0) |
| Deployment | **Proxmox LXC container** (Debian), native binary as systemd service — **no Docker** |

## 1. Background: how Schulportal Hessen works

- There is **no official API**. All clients log in like a browser and parse HTML / internal
  AJAX responses. Portal changes can break parsing.
- A pure browser webapp **cannot** talk to Schulportal directly (no CORS headers, cookies not
  readable cross-origin), so a backend is required.
- Login flow (for reference; handled by liblanis):
  `POST login.schulportal.hessen.de/?i=6128` with `user2=<user>&user=6128.<user>&password=…`
  → redirect via `connect.schulportal.hessen.de` → `start.schulportal.hessen.de` sets cookie `sid`.
- Which modules (applets) exist depends on the school's configuration. Noten are only visible
  if school 6128 has enabled them in "Mein Unterricht".

## 2. Why liblanis

liblanis is the pure-Dart library behind the Lanis-Mobile app (no Flutter dependency,
published on pub.dev, actively maintained).

| Feature we need | liblanis parser |
|---|---|
| Stundenplan | `timetable` |
| Vertretungsplan | `substitutions` |
| Hausaufgaben, Noten, Klausuren | `lessons` (Mein Unterricht: `Homework`, `LessonMark`, `LessonExam`) |
| Kalender | `calendar` |
| Nachrichten (encrypted) | `conversations` (RSA/AES handshake included) |
| Dateispeicher | `data_storage` |
| Login, session keep-alive, offline cache | `EasyLanisClient`, optional SQLite |

Compared alternatives: `SPHclient` (TypeScript, MIT) covers only login, Vertretungsplan and
Kalender; `liblanis-for-python` (MIT) has login/encryption but no module parsers yet.

**Risks:** liblanis is pre-1.0 (`0.1.x`), so its API may change → pin the version and wrap it
behind our own service layer so a change only touches one place. If a parser breaks, fix it
upstream with a PR instead of forking.

## 3. Architecture

```
┌───────────────┐   HTTPS/JSON   ┌───────────────────────────────────────┐   HTTPS   ┌────────────────────┐
│ Web UI (PWA)  │ ─────────────▶ │ Dart backend (shelf)                  │ ────────▶ │ Schulportal Hessen │
│ phone/desktop │ ◀───────────── │  api/      REST endpoints + auth      │ ◀──────── │ login./start.      │
└───────────────┘                │  service/  wraps liblanis             │           └────────────────────┘
                                 │  storage/  SQLite (cache, accounts)   │
                                 │  jobs/     polling + notifications    │
                                 └───────────────────────────────────────┘
```

- **Backend:** Dart with `shelf` + `shelf_router`. One process, compiled to a native binary.
- **Storage:** SQLite (via liblanis' optional database + own tables for app users and
  notification state). Credentials encrypted with a key from an environment variable.
- **Web UI:** separate frontend served as static files by the backend. Framework still open
  (see open decisions).
- **API sketch:**
  - `POST /api/login` / `POST /api/logout` – login to *our* app (not SPH)
  - `GET /api/timetable`, `/api/substitutions?date=`, `/api/homework`, `/api/grades`,
    `/api/exams`, `/api/calendar?from=&to=`, `/api/messages`
  - `POST /api/homework/{id}/done` – mark homework as done (if supported by SPH)
  - `POST /api/refresh` – force refresh from SPH

## 4. Platforms

| Part | Windows | Linux | macOS |
|---|---|---|---|
| Backend (native bundle via `dart build cli`) | ✅ | ✅ | ✅ |
| Web UI | any modern browser, incl. Android/iOS (installable as PWA) | | |

Notes:
- Use `dart build cli` (not `dart compile exe`, which does not support native assets). It builds
  for the OS it runs on; build Windows/macOS bundles on those OSes (GitHub Actions matrix).
- SQLite: the `sqlite3` package's build hook downloads a prebuilt SQLite library for the target
  OS and bundles it (`bundle/lib/`). Verified on Linux in milestone 1; Windows/macOS use the same
  mechanism and get checked in CI.
- Main deployment target: Linux binary in a Proxmox LXC container (see section 6).

## 5. Project structure (target)

```
schulportal-client/
├── server/                 # Dart backend (own pubspec.yaml)
│   ├── bin/server.dart     # entry point
│   ├── lib/
│   │   ├── api/            # shelf routes, auth middleware
│   │   ├── service/        # SphService: wraps liblanis, maps to our models
│   │   ├── storage/        # SQLite, credential encryption
│   │   └── jobs/           # polling, change detection, notifications
│   └── test/
├── web/                    # Frontend (framework TBD)
├── docs/
├── deploy/                 # systemd unit, install/update script, example config
└── .github/workflows/      # CI: analyze, test, build binaries for win/linux/mac
```

## 6. Deployment on Proxmox (LXC)

No Docker: the backend is a single native binary, so it runs directly in an unprivileged
LXC container.

- **Container:** Debian 12/13 template, unprivileged, ~1 vCPU, 512 MB RAM, 2–4 GB disk.
  No Dart SDK needed in the container — only the build bundle + static web files.
- **Build:** `dart build cli -t bin/server.dart` on a Linux x64 machine or in CI (GitHub Actions
  release artifact). The bundle (`bin/` + `lib/libsqlite3.so`) only needs glibc; SQLite is
  included.
- **Layout in the container:**
  - `/opt/schulportal-client/` – binary + `web/` static files
  - `/etc/schulportal-client/config.env` – port, secret key, polling interval (mode 600)
  - `/var/lib/schulportal-client/` – SQLite database
  - runs as dedicated user `schulportal` via systemd unit `schulportal-client.service`
- **Install/update:** `deploy/install.sh` downloads the latest release (or copies a local
  build), installs the unit, restarts the service. Proxmox snapshots/backups (vzdump) cover
  the database.
- **Access:** expose the port only in the LAN; from outside via VPN/Tailscale (can run in the
  same or a separate LXC) or an existing reverse proxy with TLS.

## 7. Milestones

1. **Spike** – Dart project in `server/`, add liblanis, CLI script that logs into school 6128
   and dumps which applets exist and what timetable/substitutions/lessons return.
   Answers: does school 6128 provide Noten? Does SQLite work on all three OSes?
   *Status:* `server/bin/spike.dart` done; SQLite + native build verified on Linux;
   login against school 6128 pending (needs credentials).
2. **Service layer** – `SphService` wrapping `EasyLanisClient`: login, re-login on session
   expiry, typed results for all needed modules; unit tests with mocked liblanis.
3. **REST API** – shelf server with the endpoints above, app login, response caching.
4. **Web UI** – views: Heute (Stundenplan + Vertretungen), Hausaufgaben, Noten, Klausuren,
   Kalender, Nachrichten. Installable PWA.
5. **Background jobs & notifications** – poll every 15–30 min, detect new homework, grades,
   substitutions; send via ntfy/Pushover/Home Assistant.
6. **Deployment** – systemd unit + install/update script for the LXC container, CI builds
   for Windows/Linux/macOS, docs.
7. **Extras** – multiple accounts (siblings), Dateispeicher, dark mode, offline view.

## 8. Security & privacy

- Student data is personal data (DSGVO). Self-host for your own family only; no public service.
- SPH credentials stored encrypted; secret key only in env / `.env` (git-ignored).
- Web UI has its own login; backend never exposed to the internet without authentication
  (prefer VPN/Tailscale, otherwise reverse proxy with TLS).
- Gentle on the portal: caching, polling no more often than every 15 minutes, clear User-Agent.
- Unofficial access may conflict with the portal's terms of use; keep it personal.

## 9. Open decisions

- [ ] Frontend framework: Flutter Web (all Dart, shares models) vs. Svelte/TypeScript (lighter,
      faster to load) vs. Jaspr (Dart, HTML-based)
- [ ] Notification channel: ntfy / Pushover / Home Assistant / none
- [ ] Remote access: VPN/Tailscale vs. reverse proxy
- [ ] Single account or several (siblings) from the start

## References

- [liblanis](https://github.com/lanis-mobile/liblanis) (Dart, GPL-3.0) – portal access library
- [lanis](https://github.com/lanis-mobile/lanis) (Flutter app, GPL-3.0) – real-world usage of liblanis
- [SPHclient](https://github.com/lanis-mobile/SPHclient) (TypeScript, MIT) – minimal reference for the login flow
