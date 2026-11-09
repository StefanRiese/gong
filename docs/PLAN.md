# Plan: Schulportal Hessen Client

Goal: a personal client for **Schulportal Hessen** (school ID `6128`, login at
`https://login.schulportal.hessen.de/?i=6128`) that shows Stundenplan, Vertretungsplan,
Hausaufgaben, Noten, Kalender and Nachrichten in a clean, fast UI.

## 1. Background: how Schulportal Hessen works

- There is **no official API**. Every client (Lanis-Mobile, SPHclient, sph-ha, …) logs in like
  a browser and parses HTML / internal AJAX responses. Changes to the portal can break the client,
  so parsing must be isolated and covered by tests with saved HTML fixtures.
- **Login flow** (verified in the MIT-licensed reference `lanis-mobile/SPHclient`):
  1. `POST https://login.schulportal.hessen.de/?i=6128`
     form body: `user2=<username>&user=6128.<username>&password=<password>`
  2. Follow the redirect via `https://connect.schulportal.hessen.de`
  3. Final redirect to `https://start.schulportal.hessen.de` sets the session cookie `sid`
  4. All further requests send cookies `sid`, `i=6128`, `schulportal_lastschool=6128`
  5. Logout: `https://start.schulportal.hessen.de/index.php?logout=all`
- **Modules / endpoints** (on `start.schulportal.hessen.de`):

  | Feature          | Endpoint                         | Status        |
  |------------------|----------------------------------|---------------|
  | Vertretungsplan  | `vertretungsplan.php`            | verified      |
  | Kalender         | `kalender.php` (POST, JSON)      | verified      |
  | Stundenplan      | `stundenplan.php`                | to verify     |
  | Hausaufgaben     | `meinunterricht.php` (per course)| to verify     |
  | Noten/Leistungen | `meinunterricht.php` → course detail | to verify; only if the school enables it |
  | Nachrichten      | `nachrichten.php` (AES-encrypted, key handshake via `ajax.php`) | to verify, hardest |

  Which modules exist depends on the school's configuration. The first step is to log in
  manually and record what school 6128 actually offers (browser DevTools → Network tab).

## 2. Architecture decision: webapp vs. server-client

**Important constraint:** a pure browser webapp **cannot** talk to Schulportal directly.
The portal sends no CORS headers and its cookies cannot be read cross-origin. Any web UI
therefore needs a backend that does the portal requests. The real choice is:

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A. Self-hosted server + web UI** (recommended) | Backend logs into SPH, caches data, exposes a small REST/JSON API; web frontend (PWA) runs in any browser/phone | Works on every device; one place for parsing; can poll and send notifications (new grade, homework, substitution); fits existing home setup (Proxmox/Home Assistant) | Credentials stored on the server → must be encrypted; server needs to be reachable (VPN/Tailscale or reverse proxy) |
| B. Thin proxy + smart frontend | Backend only forwards requests; parsing happens in the browser | Little server logic | Parsing in frontend is harder to test; still needs a server; no background notifications |
| C. Native/mobile app or desktop app | App talks to SPH directly (no CORS in native apps) | No server, credentials stay on the device | Separate builds per platform; no background polling without extra effort; Lanis-Mobile already exists |
| D. CLI/library only | Command-line tool | Simplest start | No nice UI |

**Recommendation: Option A**, built so the SPH access is a standalone **library**
(`core`). The library can later be reused by a CLI, a Home Assistant integration or a
native app, so the decision is not locked in.

```
┌───────────────┐    HTTPS/JSON    ┌──────────────────────────────┐    HTTPS (scraping)    ┌──────────────────────┐
│ Web UI (PWA)  │ ───────────────▶ │ Backend server               │ ─────────────────────▶ │ Schulportal Hessen   │
│ phone/desktop │ ◀─────────────── │  api/  ── core/ (SPH lib)    │ ◀───────────────────── │ login./start.        │
└───────────────┘                  │  cache (SQLite), scheduler   │                        └──────────────────────┘
                                   │  notifications (optional)    │
                                   └──────────────────────────────┘
```

## 3. Language choice (open)

| Language | Fit |
|---|---|
| **TypeScript** (Node backend + React/Svelte frontend) | One language for frontend and backend; MIT reference `SPHclient` is TS; good HTML parsing (cheerio) |
| Python (FastAPI + separate frontend) | Very good scraping tools (httpx, BeautifulSoup); several Python SPH projects exist as reference; easy Home Assistant reuse |
| Rust (axum) | Fast, single binary; more effort for HTML scraping and frontend |

Suggestion: **TypeScript** if the web UI is the focus, **Python** if Home Assistant integration
matters more.

## 4. Milestones

1. **Exploration** – log in manually, record requests/responses for each module (save anonymised
   HTML as test fixtures in `tests/fixtures/`). Document endpoints in `docs/endpoints.md`.
2. **Core: login & session** – login, session keep-alive, re-login when `sid` expires, logout.
3. **Core: read-only modules** – Vertretungsplan → Kalender → Stundenplan → Hausaufgaben
   (Mein Unterricht) → Noten. Each one: fetch, parse into typed models, fixture tests.
4. **Backend API** – endpoints like `GET /api/timetable`, `/api/substitutions`, `/api/homework`,
   `/api/grades`, `/api/calendar`; caching in SQLite to keep request volume to SPH low.
5. **Web UI** – PWA with views: Today (timetable + substitutions), Homework, Grades, Calendar.
6. **Extras** – Nachrichten (encryption handshake), notifications (Pushover/ntfy/Home Assistant)
   for new homework, grades and substitutions, marking homework as done, multiple children/accounts.
7. **Deployment** – Docker container, run on the home server; access via VPN or reverse proxy
   with authentication.

## 5. Security & privacy

- Credentials and data belong to a (possibly minor) student → personal data under DSGVO.
  Self-host only, for your own family's accounts; no public multi-user service.
- Store credentials encrypted (secret key from env), never in the repo (`.env` is git-ignored).
- The web UI must have its own login; never expose the backend to the internet unauthenticated.
- Be polite to the portal: caching, low polling intervals (e.g. every 15–30 min), clear User-Agent.
- Unofficial access may conflict with the portal's terms of use; keep it for personal use.

## 6. Open decisions

- [ ] Architecture: Option A (recommended) / B / C / D
- [ ] Language: TypeScript / Python / Rust
- [ ] Which modules does school 6128 actually provide (Noten especially)?
- [ ] Notifications: needed? Which channel?
- [ ] How the server is reached from outside (VPN, Tailscale, reverse proxy)
- [ ] License (MIT would allow reuse of ideas from `SPHclient`)

## References

- `lanis-mobile/SPHclient` (TypeScript, MIT) – compact login + Vertretungsplan/Kalender
- `lanis-mobile` app (Flutter) – most complete feature set, incl. Nachrichten encryption
- `leonsio/sph-ha` (Python, MIT) – Home Assistant integration
- `dewenni/lanis` (Python, MIT) – Hausaufgaben/Termine via Pushover
