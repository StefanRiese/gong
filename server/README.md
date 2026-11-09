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

## Native build

```sh
dart build cli -t bin/spike.dart -o build/spike
./build/spike/bundle/bin/spike --db-only
```

The bundle contains the executable and `lib/libsqlite3.so` (SQLite is bundled by the
`sqlite3` package's build hook).
