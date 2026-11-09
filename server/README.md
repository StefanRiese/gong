# server

Dart backend for schulportal-client, built on [liblanis](https://pub.dev/packages/liblanis).

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

## Service layer (milestone 2)

```
lib/
  schulportal_server.dart      public exports
  src/models/models.dart       app models (JSON), independent of liblanis
  src/sph/sph_gateway.dart     interface over liblanis (test seam)
  src/sph/liblanis_gateway.dart  real implementation
  src/sph/mappers.dart         liblanis → app models
  src/sph/sph_service.dart     session policy, retries, error mapping
  src/sph/errors.dart          SphAuth/Unavailable/FeatureDisabled/NotFound/DataException
  src/config/env.dart          .env loader, credentials
```

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

## HTTP server (milestone 3)

```sh
cd server
cp .env.example .env               # fill in SPH_* values
dart run bin/hash_password.dart    # paste the printed APP_PASSWORD_HASH=… into .env
dart run bin/server.dart           # listens on http://127.0.0.1:8080
```

`ENV_FILE=/path/to/config.env` selects another config file.

### API

All responses are JSON. Data endpoints need the session cookie from the login.

| Method | Path | Notes |
|---|---|---|
| GET | `/healthz` | no login |
| POST | `/api/auth/login` | body `{"password": "…"}`, `Content-Type: application/json`; sets cookie `sph_session` |
| POST | `/api/auth/logout` | |
| GET | `/api/auth/me` | `{"authenticated": bool}` |
| GET | `/api/account` | enabled features |
| GET | `/api/timetable` | cached 6 h |
| GET | `/api/substitutions` | cached 10 min |
| GET | `/api/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD` | default today … +60 days, max 400 days; cached 1 h |
| GET | `/api/courses` | cached 1 h |
| GET | `/api/courses/{id}` | history, grades, exams; cached 30 min |
| GET | `/api/homework` | current homework; cached 15 min |
| GET | `/api/grades` | all courses (one portal request per course); cached 1 h |
| POST | `/api/refresh` | clears the cache |

Data responses: `{"data": …, "fetchedAt": "…", "cached": bool, "stale": bool}`.
`?refresh=1` bypasses the cache. If the portal is down, the last cached data is returned with
`"stale": true`.

Errors: `{"error": {"code": "…", "message": "…"}}`

| Status | Code | Meaning |
|---|---|---|
| 400 | `bad_request` | invalid parameters |
| 401 | `unauthorized` / `invalid_password` | not logged in / wrong web UI password |
| 404 | `feature_disabled` / `not_found` | applet not enabled / unknown course or path |
| 415 | `unsupported_media_type` | login without JSON content type |
| 429 | `too_many_attempts` | 5 failed logins in 15 min (`Retry-After` header) |
| 502 | `sph_bad_response` | unexpected portal response |
| 503 | `sph_auth_failed` / `sph_unavailable` | Schulportal login failed / portal down |

If `WEB_DIR` is set, the server also serves the web UI; unknown non-API paths return
`index.html`.

## Notifications (milestone 5)

With `NTFY_TOPIC` set, `Poller` checks substitutions, homework and grades in the background
(see `.env.example` for intervals and active hours) and sends new items to ntfy.

```
lib/src/storage/app_database.dart   SQLite: seen items, poll status, web sessions (hashed)
lib/src/notify/change_detector.dart fingerprints + German notification texts (pure functions)
lib/src/notify/poller.dart          schedule, baseline on first run, retry on send failure
lib/src/notify/notifier.dart        ntfy JSON publisher
```

- first run per kind records a baseline without notifications
- an item is marked as seen only after its notification was sent
- more than 8 new items at once → one summary notification
- loads go through the response cache (keeps the web UI fast)

API: `GET /api/notifications` (settings + status), `POST /api/notifications/test`,
`POST /api/notifications/check` (check now; returns `{"sent": n}`).

## Native build

```sh
dart build cli -t bin/server.dart -o build/server
./build/server/bundle/bin/server
```

The bundle contains the executable and `lib/libsqlite3.so` (SQLite is bundled by the
`sqlite3` package's build hook).

A complete release archive (server, password tool, web UI, install files) is built with
`bash deploy/build-release.sh` from the repository root.
