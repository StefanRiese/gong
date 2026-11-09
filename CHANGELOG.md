# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning: [SemVer](https://semver.org/).
Pushing a tag `vX.Y.Z` builds and publishes the release (see `deploy/README.md`).

## [Unreleased]

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

[Unreleased]: https://github.com/StefanRiese/schulportal-client/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/StefanRiese/schulportal-client/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/StefanRiese/schulportal-client/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/StefanRiese/schulportal-client/releases/tag/v0.1.0
