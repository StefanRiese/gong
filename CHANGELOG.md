# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning: [SemVer](https://semver.org/).
Pushing a tag `vX.Y.Z` builds and publishes the release (see `deploy/README.md`).

## [Unreleased]

## [0.8.0] – 2026-11-09

### Changed
- New name: **Gong – dein Schulportal-Begleiter für Hessen** (was: schulportal-client). The
  repository is now `StefanRiese/gong`; everything was renamed: release files
  (`gong-linux-x64.tar.gz`, `gong-windows-x64.exe`, `gong-macos-universal.zip`), the
  macOS app (`Gong.app`), web UI, paths (`/opt/gong`, `/etc/gong`, `/var/lib/gong`),
  systemd units (`gong.service`, `gong-update.*`), system user `gong`, desktop data
  folders (`%LOCALAPPDATA%\gong`, `~/Library/Application Support/gong`) and the database
  (`gong.db`). Installations of earlier versions are not migrated – install anew.

## [0.7.0] – 2026-11-09

### Added
- App updates from the web UI: the server checks GitHub for new releases (every 12 hours,
  `UPDATE_CHECK`), shows a notice with the release notes and installs the update with
  „Jetzt aktualisieren“ in *Einstellungen → Server → Update*. Downloads come only from the
  GitHub releases and are checked against their SHA-256; the page reloads when the new version
  runs.
  - LXC/Linux: through the new root units `schulportal-client-update.path`/`.service`
    (installed by `install.sh`), which run `install.sh --auto-update` – only newer releases,
    previous version kept for `--rollback`. Existing installations get them with the next
    `install.sh` run.
  - Windows: the exe replaces itself and restarts. macOS: the menu bar app swaps the app bundle.
- `GET /api/update`, `POST /api/update/check`, `POST /api/update/install`.

### Changed
- One icon everywhere: the mortarboard over the open book is now also used for the favicon,
  the logo in the web UI, the tray and menu bar icons and the small Windows icon sizes (before,
  small sizes showed only the mortarboard).
- *Einstellungen → Vertretungsplan*: notices of the substitution plan (e.g. „Allgemein“) can be
  hidden by their heading; they then disappear from Vertretungen and Heute
  (`substitutionFilter.hiddenNotices`; „Alle Klassen anzeigen“ still shows them).

## [0.6.0] – 2026-11-09

### Added
- Substitution plan filter in *Einstellungen → Vertretungsplan*: choose the own classes (from the
  classes in the current plan, or entered by hand), whether entries without class (break
  supervision, care) are shown, and which types to hide. Stored on the server: Vertretungen,
  Heute and notifications only show / report these entries, on all devices
  (`substitutionFilter` in `/api/settings`; `/api/substitutions?alle=1` for the full plan).
- Vertretungen: additional filters on the page – all classes, a single class, search
  (subject, teacher, room, note, …) and type chips; the page shows how many entries the
  permanent filter hides.

### Changed
- Heute only shows substitutions in the lessons for entries that name one of the own classes
  exactly and match period and subject. Before, any entry of the school's plan in the same
  period changed the lesson. Without own classes, Heute only lists the substitutions.
- `PUT /api/settings` keeps fields that are not sent (was: replace everything).

## [0.5.0] – 2026-11-09

### Added
- Background sync: the server keeps all data (Stundenplan, Vertretungen, Hausaufgaben, Noten,
  Kalender, course pages) up to date on its own during `ACTIVE_HOURS`, also without ntfy.
  Pages open right away from the cached data; expired data is refreshed in the background.
  `SYNC=false` switches it off (data is then loaded on demand).
- Cached data is stored in the database: available immediately after a restart and while the
  portal is down.
- Live updates: open pages update themselves when the server has new data (`/api/events`).
- „Neu laden“ starts a sync in the background; the button spins while the server syncs and
  the page updates when it is done. The status shows „· wird aktualisiert“ during a background
  refresh.
- `GET /api/sync` shows the sync status per data kind.
- Setup page in the web UI: without Schulportal login or web UI password the server starts in
  setup mode instead of failing. The setup page (school search by name, login test, web UI
  password) is protected by a one-time token from the setup link: the desktop apps open it in
  the browser on first start, `install.sh` and the log show it on the LXC server.
- *Einstellungen → Server* in the web UI: Schulportal login (with school search and login
  test), web UI password (needs the current one, logs out other devices), sync intervals and
  active hours, ntfy notifications (random topic), network. Changes apply without restart,
  except network settings. Stored in the database; they take precedence over `config.env`.
  Another school or user discards the cached data and notification state of the old account.

### Changed
- Course pages are loaded once per sync for grades, the full homework list and the course
  pages (previously separately), which halves the requests to the portal.
- New homework appears in the full homework list right after the 15-minute sync, not only
  after the next course page sync.
- `POLL_INTERVAL_MINUTES` defaults to 15 (was 20) and now also applies without notifications.
- `POST /api/refresh` answers `202` and syncs asynchronously (was: clear cache, `204`).
- Desktop apps: first start opens the setup page in the browser instead of `config.env` in
  Notepad / TextEdit; the tray / menu bar item „Einstellungen“ opens *Einstellungen → Server*.
  `config.env` is optional.
- `install.sh` starts the service also without credentials and prints the setup link; asking
  for the credentials in the terminal is optional.

## [0.4.0] – 2026-11-09

### Added
- Windows desktop app: a single `schulportal-client-windows-x64.exe` with the web UI built in.
  It runs without a console window as an icon in the notification area; right click opens a
  menu with „Schulportal-Client öffnen“, „Einstellungen bearbeiten“, „Protokoll anzeigen“,
  „Neu starten“ and „Beenden“ (double click opens the web UI). Uses the SQLite that ships
  with Windows.
- macOS desktop app: universal `Schulportal-Client.app` (Apple Silicon + Intel) as a menu bar
  app with the same menu, released as `schulportal-client-macos-universal.zip`.
- First start of the desktop apps creates `config.env` in the user profile and opens it in
  Notepad / TextEdit; a second start opens the web UI. See `deploy/DESKTOP.md`.
- `APP_PASSWORD` (plain text) as alternative to `APP_PASSWORD_HASH`; the server replaces it
  with the hash in the config file on start.
- App icon for the desktop apps (mortarboard over an open book): Windows exe icon (Explorer,
  taskbar), tray icon, macOS app and menu bar icon; generated by `deploy/desktop/make-icons.py`.
- `OPEN_BROWSER=true` opens the web UI in the default browser after start.
- `server check` verifies a build (SQLite, embedded files) and `server version` prints the
  version.

### Changed
- The web UI uses the new app icon (mortarboard over an open book) as favicon, PWA and
  home screen icon, like the desktop apps.
- `/healthz` also returns `"app": "schulportal-client"`.
- The release no longer contains per-architecture macOS archives or a Windows `.tar.gz`.

## [0.3.1] – 2026-11-09

### Fixed
- Portal outages (HTTP 5xx, e.g. `login.schulportal.hessen.de` answering 502) and connection
  problems are reported as „Das Schulportal ist gerade nicht erreichbar …“ instead of
  „unerwartete Daten“; cached data is served where available.
- The web UI starts even if the portal cannot be reached: it uses the sections of the last
  successful start and shows a notice with „Erneut versuchen“.

## [0.3.0] – 2026-11-09

### Changed
- One subject color assignment for the whole app: courses ("Mathematik 05eg") are matched
  automatically to timetable abbreviations ("M"), so Fächer, Hausaufgaben, Noten, course pages,
  Heute and Vertretungen use the same colors as the Stundenplan.
- Einstellungen → „Fächer & Farben“ lists courses by full name with color picker and a
  dropdown to correct the timetable abbreviation; abbreviations without a course get their
  own rows. Stored on the server (`courseSubjects` in `/api/settings`).
- Subject colors are now also shown on Noten cards, the course page, homework cards on Heute
  and as a dot on substitution cards.

### Fixed
- HTML entities from the portal (e.g. `schulische Veranstaltung &amp; Fahrten`) are decoded in
  plain-text fields: calendar titles/places/categories, subjects, rooms, teachers, course
  names, topics, grades.
- Push notifications show homework text without HTML tags and entities.

## [0.2.0] – 2026-11-09

### Added
- Subject colors in Stundenplan and Heute: automatic, distinct colors for up to 16 subjects,
  changeable on the new Einstellungen page (gear icon); stored on the server for all devices.
- Mark homework as „erledigt“ on Hausaufgaben, Heute and the course page; the change is saved
  in Schulportal (`PUT /api/courses/{id}/entries/{entry}/homework`).
- Full homework list from all course histories (`/api/homework?alle=1`); the poller keeps it
  fresh.
- Hausaufgaben grouped by course, open homework by default, „Erledigte anzeigen“ toggle.
- In open-only lists, homework marked as done disappears right away with a „Rückgängig“ toast.
- Fächer page: all courses as cards with open-homework badges, links to the course pages.
- Short labels in the phone tab bar (7 items).

### Changed
- Heute shows open homework of the last 14 days (older ones are linked) and loads it after
  the rest of the page.
- Course pages link back to Fächer.
- Marking homework as done patches cached data instead of reloading from the portal.

### Fixed
- Open homework from earlier lessons was missing (the portal overview only lists the latest
  lesson per course).

## [0.1.0] – 2026-11-09

First release.

### Added
- Dart server using liblanis: login to Schulportal Hessen with re-login on session expiry,
  idle logout, login block after wrong credentials.
- HTTP API with app login (PBKDF2 password hash, HttpOnly session cookie, rate limit),
  per-endpoint cache with stale fallback when the portal is down, strict CSP.
- Web UI (plain HTML/CSS/JS, no build step): Heute, Stundenplan, Vertretungen, Hausaufgaben,
  Noten, course pages, Kalender with filters; responsive, dark mode, installable.
- Push notifications via ntfy for new substitutions, homework and grades; background polling
  with baseline, retry and summary; persistent web sessions in SQLite.
- LXC deployment: systemd unit with sandboxing, `install.sh` (install, update, rollback,
  configure, uninstall), release builds for Linux/Windows/macOS via GitHub Actions.

[Unreleased]: https://github.com/StefanRiese/gong/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/StefanRiese/gong/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/StefanRiese/gong/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/StefanRiese/gong/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/StefanRiese/gong/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/StefanRiese/gong/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/StefanRiese/gong/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/StefanRiese/gong/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/StefanRiese/gong/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/StefanRiese/gong/releases/tag/v0.1.0
