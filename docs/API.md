# REST API

The server of Gong offers a JSON API over HTTP. The web UI uses it exclusively, so
everything the web UI shows is available to other programs too: scripts, Home Assistant,
Node-RED, Grafana and similar.

This document describes version **0.5** of the API. There is no version prefix in the paths;
changes are listed in [CHANGELOG.md](../CHANGELOG.md).

- [Basics](#basics)
- [Authentication](#authentication)
- [Data endpoints](#data-endpoints)
- [Sync and live updates](#sync-and-live-updates)
- [Notifications](#notifications)
- [Setup and server settings](#setup-and-server-settings)
- [App updates](#app-updates)
- [School meals](#school-meals)
- [WebUntis (second source)](#webuntis-second-source)
- [Data models](#data-models)
- [Errors](#errors)
- [Examples](#examples)

## Basics

| | |
|---|---|
| Base URL | `http://<host>:8080` (`HOST` / `PORT` in the server settings) |
| Format | JSON, UTF-8; request bodies need `Content-Type: application/json` |
| Authentication | session cookie `sph_session` (see below) |
| Caching | `Cache-Control: no-store` on all `/api/` responses |
| CORS | none: only same-origin pages (the web UI) can call the API from a browser |
| Time stamps | ISO 8601; `fetchedAt` and status times in UTC (`…Z`), dates as `YYYY-MM-DD` |

Every response also carries `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
`Referrer-Policy: no-referrer` and a strict `Content-Security-Policy`.

### How data is loaded

The server keeps all portal data in sync in the background (see
[Sync and live updates](#sync-and-live-updates)) and stores it in its database. Data endpoints
therefore answer **from the cache right away**:

- If the cached entry is older than its sync interval (plus 5 minutes), the server answers with
  it anyway and refreshes it in the background (`"refreshing": true`).
- Only if there is no cached entry at all, the request waits for the portal.
- `?refresh=1` waits for fresh data from the portal.
- If the portal is down, the last data is served with `"stale": true`.

Clients that want to follow changes listen to [`GET /api/events`](#get-apievents) instead of
polling.

## Authentication

### `POST /api/auth/login`

Logs in with the password of the web UI and sets the session cookie.

```http
POST /api/auth/login
Content-Type: application/json

{"password": "web-passwort"}
```

```http
200 OK
Set-Cookie: sph_session=…; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000

{"authenticated": true}
```

- The session is valid for `SESSION_TTL_DAYS` (default 30) **after the last use** and survives
  restarts of the server.
- 5 wrong passwords within 15 minutes from one client → `429 too_many_attempts` with a
  `Retry-After` header (seconds). Behind a reverse proxy the client is identified by
  `X-Forwarded-For` if `TRUST_PROXY` is on.
- With `COOKIE_SECURE` on, the cookie is only sent over HTTPS.
- While the server is not set up: `503 setup_required`.

### `POST /api/auth/logout`

Ends the session and deletes the cookie. → `200 {"authenticated": false}`

### `GET /api/auth/me`

`200 {"authenticated": true|false}`. Needs no login.

### `GET /healthz`

`200 {"status": "ok", "app": "gong"}`. Needs no login; for monitoring and to
detect a running instance.

## Data endpoints

All data endpoints need the session cookie (`401 unauthorized` otherwise) and answer with the
same envelope:

```json
{
  "data": { … },
  "key": "timetable",
  "fetchedAt": "2026-11-09T10:15:02.123Z",
  "cached": true,
  "stale": false,
  "refreshing": false
}
```

| Field | Meaning |
|---|---|
| `data` | the content (see [Data models](#data-models)) |
| `key` | cache key; [live updates](#get-apievents) refer to it |
| `fetchedAt` | when the data was loaded from the portal |
| `cached` | answered from the cache (without waiting for the portal) |
| `stale` | the last refresh failed – the portal is not reachable, the data may be old |
| `refreshing` | a refresh of this entry runs in the background right now |

Query parameter for all of them: `?refresh=1` – wait for fresh data from the portal.

| Endpoint | `data` | Cache key | Refreshed every |
|---|---|---|---|
| `GET /api/account` | [AccountInfo](#accountinfo) | `account` | 6 h |
| `GET /api/timetable` | [Timetable](#timetable) | `timetable` | 6 h |
| `GET /api/substitutions` | [SubstitutionDay](#substitutionday)`[]`, filtered | `substitutions` | 15 min |
| `GET /api/calendar` | [CalendarEntry](#calendarentry)`[]` | `calendar:<from>:<to>` | 1 h (default range) |
| `GET /api/courses` | [Course](#course)`[]` | `courses` | 2 h |
| `GET /api/courses/{id}` | [CourseDetails](#coursedetails) | `course:<id>` | 2 h |
| `GET /api/homework` | [Homework](#homework)`[]` | `homework` | 15 min |
| `GET /api/homework?alle=1` | [Homework](#homework)`[]` | `homework:all` | 2 h, new entries every 15 min |
| `GET /api/grades` | [CourseGrades](#coursegrades)`[]` | `grades` | 2 h |

The intervals are the defaults (`POLL_INTERVAL_MINUTES`, `GRADES_INTERVAL_MINUTES`); the sync only
runs during `ACTIVE_HOURS` (default 6–22). Outside of them, an expired entry is refreshed in the
background when it is requested.

Endpoints of portal areas that are not enabled for the account answer
`404 feature_disabled`. Which areas are enabled: `features` in `/api/account`.

### `GET /api/substitutions`

The portal's plan contains **all classes** of the school. The server applies the permanent
filter from the [settings](#get-apisettings-put-apisettings) (`substitutionFilter`: own classes,
hidden types) and adds a `filter` field to the envelope:

```json
{
  "data": [ … ],
  "filter": {"active": true, "hidden": 41, "classes": ["05eG"]},
  "key": "substitutions", …
}
```

| Parameter | |
|---|---|
| `alle=1` | the full plan without the permanent filter (`"filter": {"active": false, "hidden": 0}`) |

With [WebUntis](#webuntis-second-source) switched on, the plan is combined with WebUntis before
the filters are applied: entries that exist in both are completed (`"source": "Schulportal + WebUntis"`),
entries only WebUntis has are added (`"source": "WebUntis"`).

An entry matches if one of its classes (`className`, several separated by `,` `;` `?` `/`) is one
of the own classes, compared case-insensitively; entries without class only if
`showUnassigned` is set. Notices of a day are kept unless their heading is in `hiddenNotices`;
`filter.hidden` only counts entries.

### Filters in the URL

The list endpoints accept the same filters as the web UI pages, so a page URL can be turned
into an API call by replacing the path:

| Web UI | API |
|---|---|
| `/kalender?suche=05eg` | `/api/calendar?suche=05eg` |
| `/kalender?kategorie=Klausuren` | `/api/calendar?kategorie=Klausuren` |
| `/vertretungen?suche=Becker` | `/api/substitutions?suche=Becker` |
| `/vertretungen?klasse=05eG` | `/api/substitutions?klasse=05eG` |
| `/vertretungen?alle=1` | `/api/substitutions?alle=1` |

| Endpoint | Parameter | Effect |
|---|---|---|
| `/api/substitutions` | `suche` | text in period, type, subject, teachers, rooms, class, note |
| | `klasse` | only entries of these classes (comma-separated, exact class, case-insensitive) |
| | `art` / `ohne_art` | only / without these types (comma-separated, e.g. `art=Fällt aus,Entfall`) |
| | `von` / `bis` | only these days (`YYYY-MM-DD`; invalid → `400 bad_request`) |
| | `alle=1` | without the permanent filter of the settings (the URL filters still apply) |
| `/api/calendar` | `suche` | text in title, description, place, category |
| | `kategorie` | only these categories (comma-separated; part of the name is enough, e.g. `kategorie=Klausuren,Arbeiten` or `kategorie=arbeit`) |
| `/api/homework` | `suche` | text in course, topic, description (also with `alle=1`) |

The search ignores case and looks for the whole text in any of the fields, like the pages.
URL filters are applied after the permanent filter of the settings and do not change it; the
cached data stays complete, so different filters cost no extra portal requests.

```sh
# cancellations of class 07bG from the whole plan, tomorrow only
curl -s -b jar "$BASE/api/substitutions?alle=1&klasse=07bG&art=F%C3%A4llt%20aus&von=2026-11-10&bis=2026-11-10"
```

### `GET /api/calendar`

| Parameter | Default | |
|---|---|---|
| `from` | today | `YYYY-MM-DD` |
| `to` | `from` + 60 days | `YYYY-MM-DD`, not before `from`, range at most 400 days |
| `suche`, `kategorie` | – | see [Filters in the URL](#filters-in-the-url) |

Only the default range (no parameters) is kept fresh by the sync; other ranges are loaded on
demand and cached as well.

### `GET /api/homework`

Without parameters: the homework of the portal's overview – it only contains the **latest
lesson per course**. With `?alle=1`: all homework from the lesson histories of all courses
(open and done), newest first. New homework from the overview is merged into this list at
every 15-minute sync.

### `PUT /api/courses/{id}/entries/{entry}/homework`

Marks the homework of a lesson as done or not done – **this changes the data in the
Schulportal**.

```http
PUT /api/courses/104/entries/2219/homework
Content-Type: application/json

{"done": true}
```

→ `200 {"done": true}`. The cached lists (`homework`, `homework:all`, `course:<id>`) are
updated right away. If the portal does not confirm the change: `502 sph_bad_response`.
`{id}` and `{entry}` come from [Homework](#homework) (`courseId`, `entryId`).

### `GET /api/settings`, `PUT /api/settings`

Settings of the web UI, shared by all devices.

```json
{
  "subjectColors": {"M": "#3b6fd8", "BIO": "#2e9e5b"},
  "courseSubjects": {"104": "M"},
  "substitutionFilter": {"classes": ["05eG"], "showUnassigned": false, "hiddenTypes": ["Pausenaufsicht"], "hiddenNotices": ["Allgemein"]}
}
```

| Field | |
|---|---|
| `subjectColors` | subject (timetable abbreviation) → color `#rrggbb`; at most 100, names up to 60 characters |
| `courseSubjects` | course id → timetable abbreviation (manual assignment) |
| `substitutionFilter.classes` | own classes as in the plan (e.g. `05eG`); empty = all classes; at most 30 |
| `substitutionFilter.showUnassigned` | also show entries without class (break supervision, care) while `classes` is set |
| `substitutionFilter.hiddenTypes` | types to hide (e.g. `Pausenaufsicht`), case-insensitive; at most 30 |
| `substitutionFilter.hiddenNotices` | notices to hide by their heading (e.g. `Allgemein`), case-insensitive; at most 30 |

The `substitutionFilter` is applied by the server to
[`/api/substitutions`](#get-apisubstitutions) and to the substitution notifications; the web
UI's Heute page only shows entries of the own classes in the lessons.

`PUT` changes the fields that are sent – fields not sent keep their value – and answers with the
stored version. Invalid values → `400 bad_request`.

## Sync and live updates

### `POST /api/refresh`

Starts a sync of **all** data in the background (like „Neu laden“ in the web UI) and answers
right away:

```http
202 Accepted

{"refreshing": true}
```

A sync that is already running is finished first. Progress: [`GET /api/events`](#get-apievents)
(`sync` events) or [`GET /api/sync`](#get-apisync) (`running`).

### `GET /api/sync`

Status of the background sync.

```json
{
  "enabled": true,
  "running": false,
  "activeHours": [6, 22],
  "tasks": {
    "account":       {"lastRun": "…Z", "lastSuccess": "…Z", "lastError": null, "failures": 0, "intervalMinutes": 360, "nextRun": "…Z"},
    "timetable":     { … },
    "substitutions": { … },
    "homework":      { … },
    "calendar":      { … },
    "lessons":       { … }
  }
}
```

| Task | Loads | Cache keys |
|---|---|---|
| `account` | account and enabled areas | `account` |
| `timetable` | timetable | `timetable` |
| `substitutions` | substitution plan | `substitutions` |
| `homework` | homework overview | `homework` (merged into `homework:all`) |
| `calendar` | calendar, today … +60 days | `calendar:<today>:<+60 days>` |
| `lessons` | all course pages (one portal request per course) | `courses`, `course:<id>`, `grades`, `homework:all` |

`lastError` is a short German description („Schulportal nicht erreichbar“, „Anmeldung beim
Schulportal fehlgeschlagen“, …). After a failure the task is retried after 5, 10, 20 …
minutes (at most its interval); `failures` counts the failed runs in a row. `nextRun` is `null`
if the background sync is switched off (`enabled: false`).

### `GET /api/events`

[Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html): the server
pushes changes, the connection stays open.

```http
GET /api/events

200 OK
Content-Type: text/event-stream; charset=utf-8

retry: 5000

event: sync
data: {"running":false}

event: sync
data: {"running":true}

event: update
data: {"key":"substitutions","fetchedAt":"2026-11-09T10:30:01.512Z"}

event: sync
data: {"running":false}

: ping
```

| Event | Data | When |
|---|---|---|
| `sync` | `{"running": bool}` | right after connecting, and when a sync starts or ends |
| `update` | `{"key": "…", "fetchedAt": "…"}` | a cache entry was loaded or changed (also after marking homework as done) |

- A comment `: ping` is sent every 25 seconds. If the session has expired in the meantime, the
  server closes the stream.
- After a disconnect, browsers reconnect after 5 seconds (`retry`).
- A client reloads the endpoints whose `key` it shows; a sync of the course pages produces
  many `update` events in a row, so it is worth waiting briefly (the web UI waits 600 ms).
- At most 20 streams at the same time (`503 too_many_streams`).
- Reverse proxies must not buffer this path (e.g. Nginx: `proxy_buffering off;`).

## Notifications

Push notifications via [ntfy](https://ntfy.sh) about new substitutions, homework and grades.
They are configured in the [server settings](#setup-and-server-settings).

### `GET /api/notifications`

Without ntfy: `200 {"enabled": false}`. Otherwise:

```json
{
  "enabled": true,
  "target": "ntfy.sh, Thema sph-x7…",
  "kinds": ["substitutions", "homework", "grades"],
  "sync": true,
  "intervalMinutes": 15,
  "gradesIntervalMinutes": 120,
  "activeHours": [6, 22],
  "includeGradeValues": false,
  "status": {
    "homework": {"lastRun": "…Z", "lastSuccess": "…Z", "lastError": null, "sent": 5, "baseline": true, "nextRun": "…Z"}
  }
}
```

`baseline: true` means the first check is done (it only records the current state, without
notifications). `sent` counts the notifications sent so far. Substitution notifications only
cover entries that match the permanent `substitutionFilter`.


### `POST /api/notifications/test`

Sends a test message. → `204`, or `502 notify_failed` (ntfy not reachable / rejected),
`409 notifications_disabled`.

### `POST /api/notifications/check`

Syncs substitutions, homework and grades now and sends new items. Waits until done
(course pages: one portal request per course). → `200 {"sent": 2}`

## Setup and server settings

The server's settings (Schulportal login, web UI password, sync, notifications, network) can be
read and changed over the API; the web UI uses it for the setup page and *Einstellungen →
Server*. They are stored in the database and take precedence over `config.env`.

**Authorization:** with the session cookie. While the server is **not set up** (no Schulportal
login or no web UI password) only the one-time setup token is accepted instead, as header
`X-Setup-Token: <token>`. The server logs the token as link `…/einrichtung?token=<token>` and
writes it to `DATA_DIR/setup-token`.

### `GET /api/setup`

`200 {"setupRequired": true|false}`. Needs no login. While `true`, all data endpoints and the
login answer `503 setup_required`.

### `GET /api/server-settings`

```json
{
  "setupRequired": false,
  "values": {
    "SPH_SCHOOL_ID": 6128,
    "SPH_USERNAME": "max.muster",
    "SYNC": true,
    "POLL_INTERVAL_MINUTES": 15,
    "GRADES_INTERVAL_MINUTES": 120,
    "ACTIVE_HOURS": "6-22",
    "NTFY_URL": "https://ntfy.sh",
    "NTFY_TOPIC": "sph-k3x…",
    "NOTIFY": "substitutions,homework,grades",
    "NOTIFY_GRADE_VALUES": false,
    "APP_URL": "",
    "HOST": "0.0.0.0",
    "PORT": 8080,
    "SESSION_TTL_DAYS": 30,
    "COOKIE_SECURE": false,
    "TRUST_PROXY": false,
    "OPEN_BROWSER": false,
    "UPDATE_CHECK": true
  },
  "secrets": {"SPH_PASSWORD": true, "NTFY_TOKEN": false, "APP_PASSWORD": true},
  "sources": {"SPH_USERNAME": "web", "PORT": "config", "SYNC": "default", …},
  "restartRequired": [],
  "desktop": false
}
```

| Field | |
|---|---|
| `values` | current values (secrets are never sent) |
| `secrets` | whether the Schulportal password, ntfy token and web UI password are set |
| `sources` | where a value comes from: `web` (set in the web UI), `config` (config.env / environment), `default` |
| `restartRequired` | changed settings that only apply after a restart of the server |
| `desktop` | the server runs as Windows / macOS desktop app |

The meaning of the keys is described in
[`server/.env.example`](../server/.env.example).

### `PUT /api/server-settings`

Changes settings. Only the given keys are changed; values are strings (numbers and booleans are
accepted too).

```http
PUT /api/server-settings
Content-Type: application/json

{
  "settings": {"NTFY_TOPIC": "sph-k3x9q2", "NOTIFY": "homework,grades"},
  "appPassword": "neues-passwort",
  "currentPassword": "altes-passwort"
}
```

```json
{"saved": true, "setupRequired": false, "restartRequired": [], "accountChanged": false}
```

| Field | |
|---|---|
| `settings` | config keys → values: `SPH_SCHOOL_ID`, `SPH_USERNAME`, `SPH_PASSWORD`, `SYNC`, `POLL_INTERVAL_MINUTES`, `GRADES_INTERVAL_MINUTES`, `ACTIVE_HOURS`, `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`, `NOTIFY`, `NOTIFY_GRADE_VALUES`, `APP_URL`, `HOST`, `PORT`, `SESSION_TTL_DAYS`, `COOKIE_SECURE`, `TRUST_PROXY`, `OPEN_BROWSER`, `UPDATE_CHECK`, `CASEDA_ENABLED`, `CASEDA_URL`, `CASEDA_USERNAME`, `CASEDA_PASSWORD`, `CASEDA_BALANCE_WARNING`, `UNTIS_ENABLED`, `UNTIS_SERVER`, `UNTIS_SCHOOL`, `UNTIS_USERNAME`, `UNTIS_PASSWORD` |
| `appPassword` | new web UI password (at least 8 characters); stored as hash |
| `currentPassword` | required with `appPassword`, except during the setup |

Behaviour:

- All values are validated together; on errors nothing is stored:
  `400 invalid_settings` with `problems` (list of messages).
- New Schulportal credentials (school, user or password) are tested with a login first:
  `400 sph_login_failed` if they do not work.
- Changes apply right away, except `HOST`, `PORT`, `SESSION_TTL_DAYS`, `COOKIE_SECURE` and
  `TRUST_PROXY` (listed in `restartRequired`).
- Another school or user (`accountChanged: true`) discards the cached data and notification
  state of the previous account.
- A new web UI password logs out all other sessions.
- Completing the setup (Schulportal login and web UI password set) ends setup mode, invalidates
  the token and logs in: the response sets the session cookie.

### `POST /api/server-settings/test-login`

Tests Schulportal credentials without storing them.

```json
{"schoolId": 6128, "username": "max.muster", "password": "…"}
```

Without `password` the stored password is used. → `200 {"ok": true}`, `400 sph_login_failed`,
`503 sph_unavailable`. At most 5 tests per 5 minutes (`429 too_many_attempts`), so the
Schulportal account is not locked by repeated tries.

### `GET /api/schools?q=…`

Searches the public school list of Schulportal Hessen by number, name and town (all words must
match), at most 20 results:

```json
[{"id": 6128, "name": "Musterschule", "city": "Musterstadt"}]
```

The list is loaded from the portal on first use and kept for a day; `503 sph_unavailable` if it
cannot be loaded.

## App updates

The server looks for new releases of Gong on GitHub (every 12 hours with
`UPDATE_CHECK`, and on request) and can install them. All endpoints need the login.

### `GET /api/update`

```json
{
  "current": "v0.6.0",
  "latest": "v0.7.0",
  "available": true,
  "notes": "### Added\n- …",
  "url": "https://github.com/StefanRiese/gong/releases/tag/v0.7.0",
  "publishedAt": "2026-11-10T08:00:00Z",
  "checkedAt": "2026-11-10T09:12:44Z",
  "checkError": null,
  "checkEnabled": true,
  "mode": "systemd",
  "canInstall": true,
  "phase": "idle",
  "error": null
}
```

| Field | |
|---|---|
| `current` | running version; `null` for development builds |
| `latest`, `notes`, `url`, `publishedAt` | latest release (release notes in Markdown) |
| `checkError` | last check failed (German text) |
| `mode` | how this installation is updated: `systemd` (Linux service installed by install.sh), `windows`, `macos` (desktop apps), `manual` (only a notice) |
| `canInstall` | an update is available and can be installed from the web UI |
| `phase` | `idle`, `downloading`, `installing`, `restarting`, `failed` (`error` says why) |

### `POST /api/update/check`

Looks for a new release now and answers with the status as above.

### `POST /api/update/install`

Installs the latest release and answers right away (`202`, status); `409 no_update` if there is
nothing to install. Downloads come only from the GitHub releases of this project (https) and are
checked against the published `.sha256` file.

- `systemd`: the server writes the version to `DATA_DIR/update-request`; the root unit
  `gong-update.path` runs `install.sh --auto-update`, which installs only newer
  releases and restarts the service. A failure is reported in `error`.
- `windows`: the exe downloads the new exe, swaps itself and restarts.
- `macos`: the server unpacks the new app and exits; the menu bar app swaps the bundle and
  starts it.

During the restart the server is not reachable for a moment; clients poll `GET /api/update`
until `current` changes (the web UI then reloads itself).

## School meals

Read-only view of the school meal ordering system **Caseda Schulmenü** (schulmenueplaner.de):
balance and own orders. Set up in the server settings (`CASEDA_*`); ordering stays on the
Caseda website.

### `GET /api/meals`

```json
{
  "data": {
    "balanceCents": 845,
    "orders": [
      {"date": "2026-11-10", "line": "Menü 1", "name": "Gemüsemaultaschen", "allergens": ["a", "g"],
       "priceCents": 390, "ordered": 1, "deadlinePassed": true}
    ]
  },
  "balanceWarningCents": 1000,
  "orderUrl": "https://www.caseda-schulmenue.de/kunden/essen/",
  "key": "meals", …
}
```

| Field | |
|---|---|
| `balanceCents` | account balance in cents (`null` if not shown) |
| `orders` | ordered dishes of the current and the next two weeks, by date; `ordered` = quantity, `deadlinePassed` = can no longer be changed |
| `balanceWarningCents` | `CASEDA_BALANCE_WARNING`; the web UI highlights a lower balance |
| `orderUrl` | ordering page of the caterer |

The background sync refreshes it every 2 hours (task `meals`). Errors: `404 meals_disabled`
(not set up or switched off), `503 meals_auth_failed` (login rejected),
`503 meals_unavailable`; cached data is served as `stale` when Caseda is down.

### `POST /api/server-settings/test-caseda`

`{"username": "…", "password"?: "…", "url"?: "…"}` – tests a Caseda login without storing it
(without `password` the stored one is used). → `200 {"ok": true}`, `400 meals_login_failed`,
`503 meals_unavailable`; shares the limit of 5 test logins per 5 minutes.

## WebUntis (second source)

Optional second source for the substitutions: changed lessons of the account's class from
**WebUntis**, read-only. Set up in the server settings (`UNTIS_*`). The server logs in like the
WebUntis web app (a class account such as „klasse5e“ is enough) and reads the changed lessons of
the next 21 days (cancelled lessons, substitute teachers, room changes, texts).

There is no endpoint of its own: [`GET /api/substitutions`](#get-apisubstitutions) combines the
Schulportal plan with the WebUntis changes. A WebUntis change is the same lesson if the plan has
the same class on the same day with overlapping periods. Then the Schulportal entry is completed
with what only WebUntis knows – the original teacher, the substitute, a room change, the subject,
a text – but only where the Schulportal has nothing (the Schulportal's values win); it gets
`"source": "Schulportal + WebUntis"`. Changes without a counterpart are added with
`"source": "WebUntis"` and the class of the WebUntis account as `className` (matched with the own
classes like any other entry). Days after the end of the Schulportal plan are added as new days.

The background sync (task `untis`, same interval as the substitutions) keeps it up to date;
notifications cover the added entries as well (not the completions, so a lesson is not
notified twice).

### `POST /api/server-settings/test-untis`

`{"server": "…", "username": "…", "password"?: "…", "school"?: "…"}` – tests a WebUntis login
without storing it (without `password` the stored one is used; `server` may be a pasted web
address, `school` defaults to the first part of the host name). →
`200 {"ok": true, "className": "05eG"}`, `400 untis_login_failed`, `503 untis_unavailable`;
shares the limit of 5 test logins per 5 minutes.

## Data models

`null` marks fields that can be empty. Fields marked **HTML** may contain simple HTML from the
portal (`<br>`, `<b>`, links); clients should convert it to text – never insert it as HTML.

### AccountInfo

```json
{
  "schoolId": 6128,
  "username": "max.muster",
  "accountType": "student",
  "features": ["timetable", "substitutions", "calendar", "lessons"]
}
```

`features`: portal areas enabled for the account – `timetable` (Stundenplan), `substitutions`
(Vertretungsplan), `calendar` (Kalender), `lessons` (Mein Unterricht: courses, homework,
grades), `messages` (Nachrichten, not used yet).

### Timetable

```json
{
  "currentWeek": "A",
  "slots": [
    {"period": 1, "label": "1.", "start": "07:50", "end": "08:35"},
    {"period": null, "label": "Pause", "start": "09:25", "end": "09:45"}
  ],
  "lessons": [
    {"weekday": 1, "period": 1, "duration": 2, "start": "07:50", "end": "09:25",
     "subject": "M", "room": "A104", "teacher": "Becker", "week": null}
  ]
}
```

| Field | |
|---|---|
| `currentWeek` | current week (`A`/`B`) for alternating timetables, else `null` |
| `slots` | rows of the timetable; `period: null` = break |
| `lessons[].weekday` | 1 = Monday … 5 = Friday |
| `lessons[].duration` | number of consecutive periods |
| `lessons[].week` | `A`/`B` if the lesson only takes place in one week, else `null` |

The envelope of `GET /api/timetable` has an optional `differences` (only with WebUntis and only
if there are any): `[{weekday, start, text}]` – differences between the Schulportal timetable and the
regular lessons of WebUntis (current and next week), `text` is German.

### SubstitutionDay

```json
{
  "date": "2026-11-10",
  "entries": [
    {"period": "3 - 4", "type": "Vertretung", "subject": "D", "previousSubject": null,
     "teacher": "Yilmaz", "substitute": "Wolf", "room": "A108", "previousRoom": "A104",
     "className": "08b", "note": null}
  ],
  "notices": [{"title": "Hinweise", "lines": ["Wandertag der 6. Klassen"]}]
}
```

`source` (only present when WebUntis is involved): `"WebUntis"` (only in WebUntis) or
`"Schulportal + WebUntis"` (Schulportal entry completed from WebUntis).

`notices[].lines` are **HTML**. `type` is the portal's wording (e.g. „Vertretung“, „Entfall“,
„Raumänderung“).

### CalendarEntry

```json
{
  "id": "4711", "title": "Elternsprechtag", "description": "…",
  "start": "2026-11-20T16:00:00.000", "end": "2026-11-20T19:00:00.000",
  "allDay": false, "place": "Aula", "category": "Termine"
}
```

`start` and `end` are local time without time zone. `description` is **HTML**.

### Course

```json
{"id": "104", "name": "Mathematik 08b", "teachers": ["Becker"]}
```

### Homework

```json
{
  "courseId": "104", "courseName": "Mathematik 08b", "entryId": "2219",
  "date": "2026-11-09", "topic": "Brüche", "description": "S. 45 Nr. 3–5", "done": false
}
```

`date` is the date of the lesson. `description` is **HTML**.

### CourseDetails

```json
{
  "course": {"id": "104", "name": "Mathematik 08b", "teachers": ["Becker"]},
  "history": [
    {"id": "2219", "date": "2026-11-09", "periods": "3", "topic": "Brüche",
     "description": "…", "homework": "S. 45 Nr. 3–5", "homeworkDone": false, "attendance": "anwesend"}
  ],
  "grades": [{"name": "1. Klassenarbeit", "date": "12.09.2026", "mark": "2", "comment": null}],
  "exams": [{"name": "2. Klassenarbeit", "value": "03.12.2026"}],
  "attendance": {"Fehlstunden": "2", "davon entschuldigt": "2"}
}
```

`history` is the lesson history, newest first; `description` and `homework` are **HTML**.
`grades[].date` and `exams[].value` are text as delivered by the portal (format differs between
schools). `attendance` contains the portal's labels and values.

### CourseGrades

```json
{"course": {"id": "104", "name": "Mathematik 08b", "teachers": ["Becker"]},
 "grades": [ … ], "exams": [ … ]}
```

Same `grades` and `exams` as in [CourseDetails](#coursedetails).

## Errors

Errors have a status code and a JSON body:

```json
{"error": {"code": "sph_unavailable", "message": "Schulportal is not reachable"}}
```

`message` is meant for logs (English); clients should decide by `code`. Some errors add fields
(`retryAfter`, `problems`).

| Status | `code` | Meaning |
|---|---|---|
| 400 | `bad_request` | invalid parameters or body |
| 400 | `invalid_settings` | settings rejected; `problems`: list of messages |
| 400 | `sph_login_failed` | new or tested Schulportal credentials do not work |
| 401 | `unauthorized` | not logged in / session expired |
| 401 | `invalid_password` | wrong web UI password at login |
| 403 | `invalid_password` | wrong current password when changing it |
| 403 | `setup_token_invalid` | setup token missing or wrong (setup mode) |
| 404 | `not_found` | unknown path or course |
| 404 | `feature_disabled` | portal area not enabled for the account |
| 409 | `notifications_disabled` | ntfy is not set up |
| 409 | `no_update` | no update can be installed |
| 400 | `meals_login_failed` | new or tested Caseda login does not work |
| 400 | `untis_login_failed` | new or tested WebUntis login does not work |
| 503 | `untis_unavailable` | WebUntis not reachable |
| 404 | `meals_disabled` | school meals not set up or switched off |
| 503 | `meals_auth_failed` / `meals_unavailable` | Caseda login rejected / Caseda not reachable |
| 415 | `unsupported_media_type` | body without `Content-Type: application/json` |
| 429 | `too_many_attempts` | too many failed logins / test logins; `Retry-After` header |
| 502 | `sph_bad_response` | unexpected answer from the portal |
| 502 | `notify_failed` | ntfy rejected or not reachable |
| 503 | `sph_unavailable` | portal not reachable (no cached data available) |
| 503 | `sph_auth_failed` | the server's Schulportal login failed; `retryAfter`: earliest new try (the server waits 10 minutes, so the account is not locked) |
| 503 | `setup_required` | the server is not set up yet |
| 503 | `too_many_streams` | too many open event streams |

## Examples

### curl

```sh
BASE=http://192.168.1.50:8080

# log in (stores the cookie in ./jar)
curl -s -c jar -H 'Content-Type: application/json' \
     -d '{"password":"web-passwort"}' $BASE/api/auth/login

# substitutions
curl -s -b jar $BASE/api/substitutions | jq '.data[] | {date, n: (.entries | length)}'

# open homework of the last lessons
curl -s -b jar "$BASE/api/homework?alle=1" | jq '[.data[] | select(.done | not)] | length'

# start a sync and follow it live
curl -s -b jar -X POST $BASE/api/refresh
curl -s -N -b jar $BASE/api/events
```

### Python

```python
import json
import requests

base = "http://192.168.1.50:8080"
s = requests.Session()
s.post(f"{base}/api/auth/login", json={"password": "web-passwort"}).raise_for_status()

r = s.get(f"{base}/api/grades").json()
print("Stand:", r["fetchedAt"], "(offline)" if r["stale"] else "")
for c in r["data"]:
    print(c["course"]["name"], len(c["grades"]), "Noten")

# live updates
with s.get(f"{base}/api/events", stream=True) as events:
    event = None
    for line in events.iter_lines(decode_unicode=True):
        if line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: ") and event == "update":
            print("neu:", json.loads(line[6:])["key"])
```

### Home Assistant

A REST sensor with the number of substitution entries. The integration cannot log in itself:
log in once with curl (see above) and store the cookie value as secret. Sessions are extended
with every use, so the cookie stays valid as long as the sensor queries at least once within
`SESSION_TTL_DAYS`:

```yaml
rest:
  - resource: http://192.168.1.50:8080/api/substitutions
    headers:
      Cookie: !secret schulportal_cookie   # "sph_session=…"
    scan_interval: 900
    sensor:
      - name: Vertretungen
        value_template: "{{ value_json.data | map(attribute='entries') | map('length') | sum }}"
        json_attributes_path: "$"
        json_attributes: [fetchedAt, stale]
```
