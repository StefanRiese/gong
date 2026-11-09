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

## Native build

```sh
dart build cli -t bin/spike.dart -o build/spike
./build/spike/bundle/bin/spike --db-only
```

The bundle contains the executable and `lib/libsqlite3.so` (SQLite is bundled by the
`sqlite3` package's build hook).
