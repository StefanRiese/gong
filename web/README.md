# web

Web UI for schulportal-client: plain HTML, CSS and JavaScript modules. No framework, no build
step, no npm dependencies. The Dart server serves this directory when `WEB_DIR` points to it.

## Structure

```
index.html              entry page
manifest.webmanifest    install as app (Android/iOS/desktop)
icon.svg, icon-*.png    app icons
css/app.css             all styles (light/dark, desktop sidebar / mobile tab bar)
js/app.js               shell: login gate, navigation, view rendering, refresh, logout
js/router.js            history-based router
js/api.js               fetch wrapper, German error messages
js/dom.js               h() element builder, htmlToText(), icons
js/format.js            German date formatting
js/views/*.js           one module per page
```

Pages: `/` (Heute), `/stundenplan`, `/vertretungen`, `/hausaufgaben`, `/noten`,
`/faecher` (all courses as cards → `/kurse/{id}`), `/kurse/{id}`,
`/kalender`, `/einstellungen` (gear icon: subject colors, link to notifications),
`/benachrichtigungen` (ntfy status, test message, check now).

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

Subject colors: automatic (distinct for up to 16 subjects) or set on the settings page; stored
on the server so all devices use the same colors. Navigation items are hidden when the feature is not enabled for the account.

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

With the real server (needs Schulportal credentials, see `server/README.md`):

```sh
cd server
WEB_DIR=../web dart run bin/server.dart
```

Without Schulportal, using invented sample data (Node.js, no dependencies):

```sh
node dev/mock-server.mjs          # http://127.0.0.1:8090, password: demo
MOCK_STALE=1 node dev/mock-server.mjs   # simulate "portal down, cached data"
```

Edit files and reload the browser — there is nothing to build.
