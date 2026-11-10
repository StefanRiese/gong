# server

Dart backend for Gong, built on [liblanis](https://pub.dev/packages/liblanis).

## Requirements

- Dart SDK 3.10 or newer

## Milestone 1 spike

`bin/spike.dart` checks that liblanis works against our school:

1. Opens a SQLite database file (verifies the native SQLite library works on this OS).
2. Logs in to Schulportal Hessen.
3. Lists the applets enabled for the account and fetches Stundenplan, Vertretungsplan,
   Kalender, Mein Unterricht (Hausaufgaben, Noten, Klausuren) and Nachrichten.

```sh
cd server
cp .env.example .env        # then fill in SPH_USERNAME and SPH_PASSWORD
dart pub get
dart run bin/spike.dart --db-only   # SQLite only, no network
dart run bin/spike.dart             # login + summary (counts only)
dart run bin/spike.dart --details   # also prints homework, grades, messages
```

`.env` is git-ignored. Environment variables take precedence over `.env`.

## Service layer

```
lib/
  gong_server.dart      public exports
  src/models/models.dart       app models (JSON), independent of liblanis
  src/sph/sph_gateway.dart     interface over liblanis (test seam)
  src/sph/liblanis_gateway.dart  real implementation
  src/sph/mappers.dart         liblanis → app models
  src/sph/sph_service.dart     session policy, retries, error mapping
  src/sph/errors.dart          SphAuth/Unavailable/FeatureDisabled/NotFound/DataException
  src/config/env.dart          .env loader, credentials
```

`SphService.lessonsSnapshot()` loads every course page once and returns course details,
grades and the full homework list together (used by the sync).

Session policy of `SphService`:

- logs in on the first request; concurrent requests share one login
- on a failed request: logs in again once and retries (expired sessions)
- wrong credentials / portal lockout: no retry, further logins blocked for 10 minutes
- logs out after 5 minutes without requests (no permanent keep-alive pings)

### CLI

Prints JSON from the service:

```sh
dart run bin/sph.dart account
dart run bin/sph.dart timetable
dart run bin/sph.dart substitutions
dart run bin/sph.dart calendar [YYYY-MM-DD] [YYYY-MM-DD]
dart run bin/sph.dart courses
dart run bin/sph.dart homework
dart run bin/sph.dart course <id>
dart run bin/sph.dart grades
```

Exit codes: 3 auth, 4 portal unavailable, 5 feature disabled / not found, 6 unexpected data.

### Tests

```sh
dart test       # unit tests, no network (fake gateway)
dart analyze
```

## HTTP server

```sh
cd server
WEB_DIR=../web dart run bin/server.dart     # listens on http://127.0.0.1:8080
```

### Configuration

Settings come from three layers (later ones win):

1. `.env` / the file in `ENV_FILE` (see `.env.example`),
2. environment variables,
3. settings made in the web UI (setup page, *Einstellungen → Server*), stored in the database
   (`meta` key `server-config`).

Without Schulportal credentials or web UI password the server starts in **setup mode**: data
endpoints answer `503 setup_required`, the web UI shows the setup page, and the settings
endpoints only accept the one-time setup token (header `X-Setup-Token`). The token is logged as
link `…/einrichtung?token=…` and written to `DATA_DIR/setup-token`; it is discarded when the
setup is done. Settings changes apply at runtime (`AppServer` implements `ServerControl`);
`HOST`, `PORT`, `SESSION_TTL_DAYS`, `COOKIE_SECURE` and `TRUST_PROXY` need a restart. A different
school or user clears cached data and notification state. `DATA_DIR/reset-web-settings` (one
key per line, written by `install.sh --configure`) drops web UI values on the next start so the
config file applies again.

A plain `APP_PASSWORD` in the config file is replaced by `APP_PASSWORD_HASH` on start (if the
file is writable).

### Background sync

`SyncService` (`lib/src/sync/`) keeps the cached data fresh during `ACTIVE_HOURS`, one task at a
time with short pauses:

| Task | Interval | Cache keys |
|---|---|---|
| `substitutions`, `homework` | `POLL_INTERVAL_MINUTES` (15) | `substitutions`, `homework` (merged into `homework:all`) |
| `lessons` | `GRADES_INTERVAL_MINUTES` (120) | `courses`, `course:<id>`, `grades`, `homework:all` – one request per course |
| `calendar` | 60 min | `calendar:<today>:<+60 days>` |
| `account`, `timetable` | 6 h | `account`, `timetable` |

Failures are retried after 5, 10, 20 … min (at most the interval); `SYNC=false` disables the
schedule (data is then loaded on demand). The `ResponseCache` answers from the cache right away
and refreshes expired entries in the background (stale-while-revalidate); entries are persisted
in the `cache` table, so they are there after a restart. Entries count as fresh for their sync
interval + 5 min while the sync covers them, otherwise for the TTLs in `CacheTtl`.

### Updates

`UpdateService` (`lib/src/update/`) checks the latest GitHub release every 12 hours
(`UPDATE_CHECK`) and installs it on request (`POST /api/update/install`). Downloads only come
from `github.com/StefanRiese/gong` releases and are checked against their `.sha256`. How it
installs depends on the installation (`mode`):

| Mode | When | How |
|---|---|---|
| `systemd` | Linux service installed by install.sh (`UPDATER=systemd` in the unit) | writes the version to `DATA_DIR/update-request`; root units `gong-update.path`/`.service` run `install.sh --auto-update` (newer releases only); failures come back via `DATA_DIR/update-result` |
| `windows` | Windows desktop build | downloads the exe, renames itself to `.old`, puts the new one in place, restarts |
| `macos` | macOS desktop build | unpacks the app to `DATA_DIR/update/`, exits with code 80; the menu bar app swaps the bundle |
| `manual` | development builds, other installations | notice only |

### API

Full reference with data models and examples: [docs/API.md](../docs/API.md).

All responses are JSON. Data endpoints need the session cookie from the login.

| Method | Path | Notes |
|---|---|---|
| GET | `/healthz` | `{"status": "ok", "app": "gong"}`, no login |
| POST | `/api/auth/login` | body `{"password": "…"}`, `Content-Type: application/json`; sets cookie `sph_session` |
| POST | `/api/auth/logout` | |
| GET | `/api/auth/me` | `{"authenticated": bool}` |
| GET | `/api/account` | enabled features |
| GET | `/api/timetable` | |
| GET | `/api/substitutions` | filtered by the permanent class filter (`substitutionFilter` in `/api/settings`); `?alle=1` = full plan; URL filters `klasse`, `art`, `ohne_art`, `suche`, `von`, `bis` |
| GET | `/api/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD` | default today … +60 days, max 400 days; `suche`, `kategorie` |
| GET | `/api/courses` | |
| GET | `/api/courses/{id}` | history, grades, exams, attendance |
| GET | `/api/homework` | current homework (portal overview) |
| GET | `/api/homework?alle=1` | all homework incl. done and older entries (course histories); `suche` on both |
| PUT | `/api/courses/{id}/entries/{entry}/homework` | body `{"done": true\|false}`; marks homework as done/undone **in Schulportal**; cached lists are patched, not reloaded |
| GET | `/api/grades` | grades and exams of all courses |
| GET / PUT | `/api/settings` | `subjectColors`, `courseSubjects`, `substitutionFilter`; PUT keeps fields not sent |
| POST | `/api/refresh` | starts a sync of all data in the background → `202 {"refreshing": true}` |
| GET | `/api/sync` | sync status per task (last run/success/error, interval, next run) |
| GET | `/api/events` | Server-Sent Events: `update {key, fetchedAt}`, `sync {running}` |
| GET | `/api/notifications` | notification settings and status |
| POST | `/api/notifications/test` | test message |
| POST | `/api/notifications/check` | sync + check now → `{"sent": n}` |
| GET | `/api/setup` | `{"setupRequired": bool}`, no login |
| GET | `/api/server-settings` | settings (secrets only as set/unset), sources, pending restart |
| PUT | `/api/server-settings` | `{"settings": {KEY: value}, "appPassword"?, "currentPassword"?}`; new Schulportal credentials are tested first; finishing the setup logs in |
| POST | `/api/server-settings/test-login` | `{"schoolId", "username", "password"?}`; max. 5 per 5 min |
| GET | `/api/schools?q=…` | school search in the public school list of Schulportal Hessen |
| GET | `/api/update` | version, latest release, update state |
| POST | `/api/update/check` | look for a new release now |
| POST | `/api/update/install` | install the latest release (202, async; see docs/API.md) |

The settings endpoints need the login – or, in setup mode, the setup token.

Data responses:
`{"data": …, "key": "…", "fetchedAt": "…", "cached": bool, "stale": bool, "refreshing": bool}`.
`stale` = the last refresh failed (portal down), `refreshing` = a refresh runs in the background.
`?refresh=1` waits for fresh data instead.

Errors: `{"error": {"code": "…", "message": "…"}}`

| Status | Code | Meaning |
|---|---|---|
| 400 | `bad_request` | invalid parameters |
| 400 | `invalid_settings` | settings rejected; `problems` lists them |
| 400 | `sph_login_failed` | new Schulportal credentials do not work |
| 401 | `unauthorized` / `invalid_password` | not logged in / wrong web UI password |
| 403 | `setup_token_invalid` / `invalid_password` | setup token missing or wrong / wrong current password |
| 404 | `feature_disabled` / `not_found` | applet not enabled / unknown course or path |
| 415 | `unsupported_media_type` | request without JSON content type |
| 429 | `too_many_attempts` | too many failed logins or test logins (`Retry-After` header) |
| 502 | `sph_bad_response` | unexpected portal response |
| 503 | `sph_auth_failed` / `sph_unavailable` / `setup_required` | Schulportal login failed / portal down / not set up |

If `WEB_DIR` is set, the server also serves the web UI from there (the desktop builds embed
it); unknown non-API paths return `index.html`.

## Notifications

With `NTFY_TOPIC` set, `Poller` checks the data of every sync of substitutions, homework and
grades for new items and sends them to ntfy.

```
lib/src/storage/app_database.dart   SQLite: seen items, status, web sessions (hashed), cache
lib/src/notify/change_detector.dart fingerprints + German notification texts (pure functions)
lib/src/notify/poller.dart          baseline on first run, retry on send failure
lib/src/notify/notifier.dart        ntfy JSON publisher
```

- first run per kind records a baseline without notifications
- an item is marked as seen only after its notification was sent
- more than 8 new items at once → one summary notification

## Native build

```sh
dart build cli -t bin/server.dart -o build/server
./build/server/bundle/bin/server            # run
./build/server/bundle/bin/server check      # verify SQLite (and embedded files: --desktop)
./build/server/bundle/bin/server version
```

The bundle contains the executable and `lib/libsqlite3.so` (SQLite is bundled by the
`sqlite3` package's build hook).

Release builds come from `bash deploy/build-release.sh` (repository root): a Linux archive
with server, password tool, web UI and install files, the Windows tray exe, or the macOS build
for the app bundle (see `deploy/DESKTOP.md`).
