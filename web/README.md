# web

Web UI for Gong: plain HTML, CSS and JavaScript modules. No framework, no build
step, no npm dependencies. The Dart server serves this directory when `WEB_DIR` points to it.

## Structure

```
index.html              entry page
manifest.webmanifest    install as app (Android/iOS/desktop)
icon.svg, icon-*.png    app icons
css/app.css             all styles (light/dark, desktop sidebar / mobile tab bar)
js/app.js               shell: setup/login gate, navigation, view rendering, live updates,
                        refresh, logout
js/router.js            history-based router
js/api.js               fetch wrapper, German error messages
js/dom.js               h() element builder, htmlToText(), icons
js/format.js            German date formatting
js/views/*.js           one module per page
js/views/forms.js       form helpers for setup and server settings (fields, school search)
```

Pages: `/` (Heute), `/stundenplan`, `/vertretungen`, `/hausaufgaben`, `/noten`,
`/faecher` (all courses as cards → `/kurse/{id}`), `/kurse/{id}`,
`/kalender`, `/einstellungen` (gear icon: subject colors, links),
`/einstellungen/server` (Schulportal login, web UI password, sync, notifications, network),
`/benachrichtigungen` (ntfy status, test message, check now), and `/einrichtung` (setup page,
shown instead of the login while the server is not set up; the token from the setup link is
kept in `sessionStorage` and removed from the address bar).

**Live updates and refresh:** pages answer from the server's cache right away. `app.js` follows
`/api/events` (Server-Sent Events): when a cache key used by the current page changes, the page
is re-rendered quietly (no loading placeholder, no focus change; postponed while an input has
focus). Pages with forms export `live = false` and are never re-rendered. „Neu laden“ starts a
sync on the server (`POST /api/refresh`, 202); the button spins while the server syncs. The
status shows the age of the oldest data („Stand …“, „· wird aktualisiert“, „Offline“).

Homework can be marked as „erledigt“ on Hausaufgaben, Heute and the course page; the change is
saved in Schulportal. All homework views use the full list from the course histories
(`/api/homework?alle=1`), because the portal's overview only contains the latest lesson per
course:

- Hausaufgaben: grouped by course (subject color), open homework by default; „Erledigte
  anzeigen“ (`?erledigte=1`, remembered in `localStorage`) also shows done homework.
- In open-only lists (Hausaufgaben without „Erledigte anzeigen“, Heute) homework marked as done
  disappears right away; a toast offers „Rückgängig“ for 6 seconds.
- Heute: open homework of the last 14 days (older ones are linked), loaded after the page.
- Fächer: open-homework badges per course, loaded after the page.

Subject colors (`js/colors.js`): one assignment for the whole app. Color keys are the timetable
subjects (often abbreviations like „M“, „BIO“); courses („Mathematik 05eg“) are matched to them
automatically (exact, prefix, word start, letters in order; one-to-one, longest abbreviation
first) or by the user on the settings page. Colors are automatic (distinct for up to 16 keys)
or user-defined; both settings are stored on the server (`/api/settings`). Navigation items are hidden when the feature is not enabled for the account.

Vertretungen: the portal's plan contains all classes. The permanent filter (own classes, hidden
types, hidden notices such as „Allgemein“) is set under *Einstellungen → Vertretungsplan* (`#vertretungsplan`), stored on the server
and applied by it to `/api/substitutions` and the notifications. Heute shows substitutions in
the lessons only for entries that name one of the own classes exactly (and match period and
subject); without own classes nothing is merged into the lessons. The Vertretungen page adds
temporary filters: all classes (`?alle=1`), one class (`?klasse=`), search (`?suche=`) and
type chips (remembered in `localStorage`, key `substitutionFilter`). Shared helpers:
`js/substitution-filter.js`.

App updates (`js/update.js`): a hint bar below the top bar when a new release is available
(dismissable per version, `localStorage` key `updateDismissed`); *Einstellungen → Server →
Update* (`#update`) shows versions and release notes and installs the update, then waits for
the restarted server and reloads the page. Mock: `MOCK_UPDATE=1 node dev/mock-server.mjs`.

The calendar can be filtered by text (`?suche=…`, searches title, description, place and
category), by category (chips) and by hiding past events. Hidden categories and "hide past" are
remembered per browser in `localStorage` (key `calendarFilter`).

## Security rules

- Never use `innerHTML`, `outerHTML`, `insertAdjacentHTML` or `document.write`. Build DOM with
  `h()`; all strings become text nodes.
- Portal text that contains HTML goes through `htmlToText()` (DOMParser, no script execution).
- No inline scripts or `style="…"` attributes in HTML: the server sends a strict
  Content-Security-Policy (`script-src 'self'; style-src 'self'`). Set styles via `h(…, {style})`
  (CSSOM), which the policy allows.

## Development

With the real server (without credentials it shows the setup page, see `server/README.md`):

```sh
cd server
WEB_DIR=../web dart run bin/server.dart
```

Without Schulportal, using invented sample data (Node.js, no dependencies). „Neu laden“
simulates a 2.5 s sync with live updates:

```sh
node dev/mock-server.mjs          # http://127.0.0.1:8090, password: demo
MOCK_STALE=1 node dev/mock-server.mjs   # simulate "portal down, cached data"
MOCK_SETUP=1 node dev/mock-server.mjs   # not set up: /einrichtung?token=demo-token
MOCK_UPDATE=1 node dev/mock-server.mjs  # update v0.7.0 available (install simulates a restart)
```

Edit files and reload the browser — there is nothing to build.
