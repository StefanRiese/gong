// Development server for the web UI with a fake API (no Schulportal access).
//
// Serves ../web and answers /api/* with invented sample data in the same
// format as the real Dart server. Login password: "demo".
//
//   node dev/mock-server.mjs [port]      (default 8090)
//   MOCK_STALE=1 node dev/mock-server.mjs   → responses marked as stale
//   MOCK_SETUP=1 node dev/mock-server.mjs   → not set up yet: setup page at
//                                             /einrichtung?token=demo-token
//   MOCK_UPDATE=1 node dev/mock-server.mjs  → an update (v0.7.0) is available
//   MOCK_ABBREV=1 node dev/mock-server.mjs  → timetable with subject abbreviations (M, D, Geo …)
//
// "Neu laden" (POST /api/refresh) simulates a 2.5 s sync: /api/events pushes
// sync start/end and an update for every data key the UI has loaded.

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const port = Number(process.argv[2] ?? 8090);
const webDir = resolve(fileURLToPath(new URL('../web', import.meta.url)));
const stale = process.env.MOCK_STALE === '1';
let setupRequired = process.env.MOCK_SETUP === '1';
const SETUP_TOKEN = 'demo-token';
let appPassword = 'demo';
const serverValues = {
  SPH_SCHOOL_ID: 9999, SPH_USERNAME: 'max.muster', SYNC: true, POLL_INTERVAL_MINUTES: 15,
  GRADES_INTERVAL_MINUTES: 120, ACTIVE_HOURS: '6-22', NTFY_URL: 'https://ntfy.sh', NTFY_TOPIC: '',
  NOTIFY: 'substitutions,homework,grades', NOTIFY_GRADE_VALUES: false, APP_URL: '', HOST: '0.0.0.0',
  PORT: 8090, SESSION_TTL_DAYS: 30, COOKIE_SECURE: false, TRUST_PROXY: false, OPEN_BROWSER: false, UPDATE_CHECK: true,
  CASEDA_ENABLED: true, CASEDA_URL: 'https://www.caseda-schulmenue.de', CASEDA_USERNAME: 'eltern@example.org',
  CASEDA_BALANCE_WARNING: '10,00',
  UNTIS_ENABLED: true, UNTIS_SERVER: 'musterschule.webuntis.com', UNTIS_SCHOOL: 'musterschule', UNTIS_USERNAME: 'klasse7b',
};
const SCHOOLS = [
  { id: 9999, name: 'Musterschule', city: 'Musterstadt' },
  { id: 1234, name: 'Beispiel-Gymnasium', city: 'Darmstadt' },
  { id: 4321, name: 'Gesamtschule am Park', city: 'Frankfurt am Main' },
  { id: 5555, name: 'Grundschule Sonnenschein', city: 'Kassel' },
];
const sessions = new Set();
let settings = {
  subjectColors: {}, courseSubjects: {},
  substitutionFilter: { classes: [], showUnassigned: false, hiddenTypes: [], hiddenNotices: [] },
};
const doneOverrides = new Map(); // "course/entry" → done
const fetched = new Map(); // cache key → fetchedAt (ISO)
const eventClients = new Set();
let syncRunning = false;
// Simulated app update (Einstellungen → Server → Update).
const update = {
  current: 'v0.6.0', latest: null, available: false, notes: null, mode: 'systemd',
  url: 'https://github.com/StefanRiese/gong/releases/tag/v0.7.0',
  checkedAt: null, checkError: null, checkEnabled: true, phase: 'idle', error: null,
};
const updateStatus = () => ({ ...update, canInstall: update.available && update.phase !== 'restarting' });
let restartingUntil = 0;
if (process.env.MOCK_UPDATE === '1') {
  Object.assign(update, { latest: 'v0.7.0', available: true, checkedAt: new Date().toISOString(),
    notes: '### Added\n- Neue Funktion für den Vertretungsplan\n- Updates direkt aus der Web-Oberfläche' });
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.webmanifest': 'application/manifest+json',
};

// ---------- sample data (fictional) ----------

const p = (n) => String(n).padStart(2, '0');
const ymd = (d) => `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
const localIso = (d) => `${ymd(d)}T${p(d.getHours())}:${p(d.getMinutes())}:00.000`;
const today = new Date();
today.setHours(0, 0, 0, 0);
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const nextSchoolDay = (d) => {
  let x = addDays(d, 1);
  while (x.getDay() === 0 || x.getDay() === 6) x = addDays(x, 1);
  return x;
};
const at = (d, h, m = 0) => new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, m);

const slots = [
  [1, '1. Stunde', '07:50', '08:35'], [2, '2. Stunde', '08:40', '09:25'],
  [null, 'Pause', '09:25', '09:45'],
  [3, '3. Stunde', '09:45', '10:30'], [4, '4. Stunde', '10:35', '11:20'],
  [null, 'Pause', '11:20', '11:35'],
  [5, '5. Stunde', '11:35', '12:20'], [6, '6. Stunde', '12:25', '13:10'],
  [7, '7. Stunde', '13:15', '14:00'], [8, '8. Stunde', '14:00', '14:45'],
].map(([period, label, start, end]) => ({ period, label, start, end }));

const slot = (n) => slots.find((s) => s.period === n);
// MOCK_ABBREV=1: subject abbreviations in the timetable, like many schools' portals.
const ABBREV = {
  Mathematik: 'M', Deutsch: 'D', Englisch: 'E', Biologie: 'Bio', Sport: 'Spo', Physik: 'Ph',
  Chemie: 'Ch', Religion: 'Rel', Erdkunde: 'Geo', Französisch: 'F', Geschichte: 'G', Kunst: 'Ku',
  Musik: 'Mu', 'Politik & Wirtschaft': 'PoWi', Informatik: 'Inf',
};
const abbrev = process.env.MOCK_ABBREV === '1';
const lesson = (weekday, period, duration, subject, room, teacher, week = null) => ({
  weekday, period, duration, start: slot(period).start, end: slot(period + duration - 1).end,
  subject: abbrev ? ABBREV[subject] ?? subject : subject, room, teacher, week,
});

const timetable = {
  currentWeek: 'A',
  slots,
  lessons: [
    lesson(1, 1, 2, 'Mathematik', 'A104', 'Becker'), lesson(1, 3, 2, 'Deutsch', 'A104', 'Yilmaz'),
    lesson(1, 5, 1, 'Englisch', 'B012', 'Novak'), lesson(1, 6, 1, 'Musik', 'M1', 'Schuster'),
    lesson(2, 1, 2, 'Biologie', 'N203', 'Hartmann'), lesson(2, 3, 2, 'Sport', 'Halle 2', 'Krüger'),
    lesson(2, 5, 2, 'Geschichte', 'A108', 'Wolf'),
    lesson(3, 1, 1, 'Englisch', 'B012', 'Novak'), lesson(3, 2, 1, 'Mathematik', 'A104', 'Becker'),
    lesson(3, 3, 2, 'Physik', 'N105', 'Lange', 'A'), lesson(3, 3, 2, 'Chemie', 'N110', 'Roth', 'B'),
    lesson(3, 5, 2, 'Kunst', 'K2', 'Fischer'),
    lesson(4, 1, 2, 'Deutsch', 'A104', 'Yilmaz'), lesson(4, 3, 1, 'Religion', 'A110', 'Peters'),
    lesson(4, 4, 1, 'Erdkunde', 'A108', 'Wolf'), lesson(4, 5, 2, 'Französisch', 'B014', 'Martin'),
    lesson(4, 7, 2, 'Informatik', 'PC1', 'Braun'),
    lesson(5, 1, 1, 'Mathematik', 'A104', 'Becker'), lesson(5, 2, 1, 'Englisch', 'B012', 'Novak'),
    lesson(5, 3, 2, 'Französisch', 'B014', 'Martin'), lesson(5, 5, 1, 'Politik & Wirtschaft', 'A108', 'Wolf'),
  ],
};

const d1 = nextSchoolDay(addDays(today, -1)).getTime() === today.getTime() ? today : nextSchoolDay(today);
const d2 = nextSchoolDay(d1);
const substitutions = [
  {
    date: ymd(d1),
    entries: [
      { period: '3 - 4', type: 'Vertretung', subject: 'Deutsch', previousSubject: null, teacher: 'Yilmaz',
        substitute: 'Schmitt', room: 'A112', previousRoom: 'A104', className: '7b', note: 'Arbeitsblätter im Fach' },
      { period: '6', type: 'Entfall', subject: 'Musik', previousSubject: null, teacher: 'Schuster',
        substitute: null, room: null, previousRoom: 'M1', className: '7b', note: null },
      // Other classes: the portal's plan contains the whole school.
      { period: '2', type: 'Vertretung', subject: 'Mathematik', previousSubject: null, teacher: 'Becker',
        substitute: 'Wolf', room: 'A104', previousRoom: null, className: '7a, 7b, 7c', note: 'Test verschoben' },
      { period: '3', type: 'Fällt aus', subject: 'Englisch', previousSubject: null, teacher: 'Novak',
        substitute: null, room: null, previousRoom: 'B012', className: '8a', note: null },
      { period: '5', type: 'Vertretung', subject: 'Deutsch', previousSubject: null, teacher: 'Yilmaz',
        substitute: 'Peters', room: 'A110', previousRoom: null, className: '9a?9b', note: null },
      { period: '1 - 2', type: 'Pausenaufsicht', subject: null, previousSubject: null, teacher: 'Lange',
        substitute: 'Krüger', room: 'Hof', previousRoom: null, className: null, note: null },
    ],
    notices: [{ title: 'Allgemein', lines: ['Wandertag der Klassen 9a und 9b.', '<b>Bitte Sportzeug</b> nicht vergessen!'] }],
  },
  {
    date: ymd(d2),
    entries: [
      { period: '1', type: 'Raumänderung', subject: 'Biologie', previousSubject: null, teacher: 'Hartmann',
        substitute: null, room: 'N201', previousRoom: 'N203', className: '7b', note: null },
      { period: '4', type: 'Betreuung', subject: null, previousSubject: null, teacher: null,
        substitute: 'Fischer', room: 'Mensa', previousRoom: null, className: null, note: null },
      { period: '6', type: 'Fällt aus', subject: 'Sport', previousSubject: null, teacher: 'Krüger',
        substitute: null, room: null, previousRoom: 'Halle 2', className: '10a', note: null },
    ],
    notices: [],
  },
];

// WebUntis (second source): a change on a day the Schulportal plan does not cover yet.
const untisDay = {
  date: ymd(nextSchoolDay(addDays(d2, 5))),
  entries: [
    { period: '1', type: 'Vertretung', subject: 'Mathematik', previousSubject: null, teacher: 'Becker',
      substitute: 'Wolf', room: 'N104', previousRoom: 'B1', className: '07bG', note: null, source: 'WebUntis' },
    { period: '2', type: 'Entfall', subject: 'Deutsch', previousSubject: null, teacher: 'Yilmaz',
      substitute: null, room: null, previousRoom: null, className: '07bG', note: null, source: 'WebUntis' },
  ],
  notices: [],
};
const allSubstitutions = () => (serverValues.UNTIS_ENABLED ? [...substitutions, untisDay] : substitutions);

const courses = [
  ['101', 'Mathematik 7b', ['Becker']], ['102', 'Deutsch 7b', ['Yilmaz']],
  ['103', 'Englisch 7b', ['Novak']], ['104', 'Biologie 7b', ['Hartmann']],
  ['105', 'Geschichte 7b', ['Wolf']], ['106', 'Französisch 7b', ['Martin']],
].map(([id, name, teachers]) => ({ id, name, teachers }));

const homework = [
  { courseId: '101', courseName: 'Mathematik 7b', entryId: 'e1', date: ymd(addDays(today, -1)),
    topic: 'Bruchrechnung', description: 'Buch S. 54, Nr. 3a–f\nZusatz: Nr. 7', done: false },
  { courseId: '103', courseName: 'Englisch 7b', entryId: 'e2', date: ymd(addDays(today, -2)),
    topic: 'Unit 3 – Vocabulary', description: 'Vokabeln S. 210 lernen (Test am Freitag)', done: false },
  { courseId: '104', courseName: 'Biologie 7b', entryId: 'e3', date: ymd(addDays(today, -6)),
    topic: 'Zellaufbau', description: 'Arbeitsblatt „Pflanzenzelle“ beschriften', done: true },
];

const gradesByCourse = {
  101: { grades: [{ name: 'Lernkontrolle 1', date: '18.09.2026', mark: '2', comment: null },
    { name: 'Hausaufgabenüberprüfung', date: '14.10.2026', mark: '1-', comment: 'sehr sorgfältig' }],
  exams: [{ name: 'Klassenarbeit 1', value: '02.12.2026' }] },
  102: { grades: [{ name: 'Diktat', date: '25.09.2026', mark: '3+', comment: null }],
    exams: [{ name: 'Klassenarbeit 1', value: '20.11.2026' }] },
  103: { grades: [{ name: 'Vokabeltest Unit 1', date: '01.10.2026', mark: '2+', comment: null }], exams: [] },
  104: { grades: [], exams: [{ name: 'Lernkontrolle', value: '27.11.2026' }] },
  105: { grades: [], exams: [] },
  106: { grades: [], exams: [] },
};

const grades = courses.map((course) => ({ course, ...gradesByCourse[course.id] }));

function courseDetails(id) {
  const course = courses.find((c) => c.id === id);
  if (!course) return null;
  const history = [0, 2, 7, 9].map((n, i) => ({
    id: `${id}-h${i}`, date: ymd(addDays(today, -n)), periods: i % 2 ? '1 - 2' : '3',
    topic: ['Wiederholung', 'Einführung neues Thema', 'Übungsstunde', 'Besprechung Test'][i],
    description: i === 1 ? 'Tafelbild im Dateispeicher.\nBitte nacharbeiten, wer gefehlt hat.' : null,
    homework: i < 2 ? 'Aufgaben aus dem Arbeitsheft S. 12' : null,
    homeworkDone: i === 1, attendance: i === 2 ? 'entschuldigt' : null,
  }));
  for (const e of history) e.homeworkDone = doneOverrides.get(`${id}/${e.id}`) ?? e.homeworkDone;
  return { course, history, ...gradesByCourse[id], attendance: { 'Fehlstunden': '2', 'davon unentschuldigt': '0' } };
}

function calendar(from, to) {
  const base = new Date(from);
  const events = [];
  for (let m = new Date(base.getFullYear(), base.getMonth(), 1); m <= to; m = new Date(m.getFullYear(), m.getMonth() + 1, 1)) {
    const day = (n) => new Date(m.getFullYear(), m.getMonth(), n);
    events.push(
      { id: `${ymd(m)}-1`, title: 'Elternabend 7b', description: 'Themen: Klassenfahrt, Wahl der 2. Fremdsprache',
        start: localIso(at(day(4), 19)), end: localIso(at(day(4), 20, 30)), allDay: false, place: 'Raum A104', category: 'Termine' },
      { id: `${ymd(m)}-2`, title: 'Pädagogischer Tag – unterrichtsfrei', description: '',
        start: localIso(day(13)), end: localIso(day(14)), allDay: true, place: null, category: 'Ferien/Frei' },
      { id: `${ymd(m)}-3`, title: 'Bundesjugendspiele', description: '',
        start: localIso(at(day(22), 8)), end: localIso(at(day(22), 13)), allDay: false, place: 'Sportplatz', category: 'Schulveranstaltung' },
    );
  }
  events.push({ id: 'soon', title: 'Vokabeltest Englisch', description: '', start: localIso(at(addDays(today, 2), 9, 45)),
    end: localIso(at(addDays(today, 2), 10, 30)), allDay: false, place: null, category: 'Termine' });
  return events.filter((e) => new Date(e.end) >= from && new Date(e.start) <= addDays(to, 1))
    .sort((a, b) => a.start.localeCompare(b.start));
}

// ---------- HTTP ----------

const json = (res, status, body, headers = {}) => {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers });
  res.end(JSON.stringify(body));
};
const error = (res, status, code, message) => json(res, status, { error: { code, message } });
const data = (res, key, value, extra = {}) => {
  if (!fetched.has(key)) {
    fetched.set(key, new Date(Date.now() - (stale ? 26 * 3600e3 : 4 * 60e3)).toISOString());
  }
  json(res, 200, { data: value, ...extra, key, fetchedAt: fetched.get(key), cached: true, stale, refreshing: false });
};

function broadcast(event, payload) {
  for (const c of eventClients) c.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
}

/** Simulated sync: marks all loaded keys as fresh after 2.5 s. */
function simulateSync() {
  if (syncRunning) return;
  syncRunning = true;
  broadcast('sync', { running: true });
  setTimeout(() => {
    const now = new Date().toISOString();
    for (const key of fetched.keys()) {
      fetched.set(key, now);
      broadcast('update', { key, fetchedAt: now });
    }
    syncRunning = false;
    broadcast('sync', { running: false });
  }, 2500);
}

function token(req) {
  return /(?:^|;\s*)sph_session=([^;]+)/.exec(req.headers.cookie ?? '')?.[1];
}

async function readBody(req) {
  let body = '';
  for await (const chunk of req) body += chunk;
  return body;
}

async function handleApi(req, res, url) {
  const path = url.pathname;
  if (path === '/api/setup') return json(res, 200, { setupRequired });
  // During the simulated update the "server" is away for a moment.
  if (Date.now() < restartingUntil) return error(res, 503, 'restarting', 'Restarting');
  if (path === '/api/server-settings' || path.startsWith('/api/server-settings/') || path === '/api/schools') {
    const allowed = setupRequired ? req.headers['x-setup-token'] === SETUP_TOKEN : sessions.has(token(req));
    if (!allowed) {
      return setupRequired ? error(res, 403, 'setup_token_invalid', 'Missing or wrong setup token')
        : error(res, 401, 'unauthorized', 'Login required');
    }
    return handleServerSettings(req, res, url);
  }
  if (setupRequired) return error(res, 503, 'setup_required', 'Not set up');
  if (req.method === 'POST' && path === '/api/auth/login') {
    const { password } = JSON.parse((await readBody(req)) || '{}');
    if (password !== appPassword) return error(res, 401, 'invalid_password', 'Wrong password');
    const t = Math.random().toString(36).slice(2);
    sessions.add(t);
    return json(res, 200, { authenticated: true },
      { 'set-cookie': `sph_session=${t}; Path=/; HttpOnly; SameSite=Strict` });
  }
  if (req.method === 'POST' && path === '/api/auth/logout') {
    sessions.delete(token(req));
    return json(res, 200, { authenticated: false }, { 'set-cookie': 'sph_session=; Path=/; Max-Age=0' });
  }
  if (path === '/api/auth/me') return json(res, 200, { authenticated: sessions.has(token(req)) });
  if (!sessions.has(token(req))) return error(res, 401, 'unauthorized', 'Login required');

  const hw = /^\/api\/courses\/([^/]+)\/entries\/([^/]+)\/homework$/.exec(path);
  if (hw && req.method === 'PUT') {
    const { done } = JSON.parse((await readBody(req)) || '{}');
    if (typeof done !== 'boolean') return error(res, 400, 'bad_request', 'Expected {"done": bool}');
    // Course 104 simulates the portal refusing the change.
    if (hw[1] === '104') return error(res, 502, 'sph_bad_response', 'Unexpected response from Schulportal');
    doneOverrides.set(`${hw[1]}/${hw[2]}`, done);
    return json(res, 200, { done });
  }
  if (path === '/api/settings' && req.method === 'GET') return json(res, 200, settings);
  if (path === '/api/settings' && req.method === 'PUT') {
    // Fields not sent keep their value (like the real server).
    const body = JSON.parse((await readBody(req)) || '{}');
    const colors = {};
    for (const [k, v] of Object.entries(body.subjectColors ?? settings.subjectColors)) {
      if (!/^#[0-9a-f]{6}$/i.test(v) || !k.trim()) return error(res, 400, 'bad_request', `Invalid color for ${k}`);
      colors[k.trim()] = v.toLowerCase();
    }
    const courseSubjects = {};
    for (const [k, v] of Object.entries(body.courseSubjects ?? settings.courseSubjects)) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(k) || typeof v !== 'string') return error(res, 400, 'bad_request', `Invalid course ${k}`);
      courseSubjects[k] = v.trim();
    }
    const f = body.substitutionFilter ?? settings.substitutionFilter;
    const list = (v) => [...new Set((Array.isArray(v) ? v : []).map((x) => String(x).trim()).filter(Boolean))];
    settings = {
      subjectColors: colors, courseSubjects,
      substitutionFilter: {
        classes: list(f.classes), showUnassigned: f.showUnassigned === true,
        hiddenTypes: list(f.hiddenTypes), hiddenNotices: list(f.hiddenNotices),
      },
    };
    return json(res, 200, settings);
  }
  if (path === '/api/notifications' && req.method === 'GET') {
    const ago = (min) => new Date(Date.now() - min * 60e3).toISOString();
    const ahead = (min) => new Date(Date.now() + min * 60e3).toISOString();
    return json(res, 200, {
      enabled: true, target: 'ntfy.sh, Thema sph-x7…', kinds: ['substitutions', 'homework', 'grades'],
      intervalMinutes: 20, gradesIntervalMinutes: 120, activeHours: [6, 22], includeGradeValues: false,
      status: {
        substitutions: { lastRun: ago(7), lastSuccess: ago(7), lastError: null, sent: 3, baseline: true, nextRun: ahead(13) },
        homework: { lastRun: ago(7), lastSuccess: ago(7), lastError: null, sent: 5, baseline: true, nextRun: ahead(13) },
        grades: { lastRun: ago(95), lastSuccess: ago(215), lastError: 'Schulportal nicht erreichbar', sent: 1, baseline: true, nextRun: ahead(25) },
      },
    });
  }
  if (req.method === 'POST' && path === '/api/notifications/test') {
    res.writeHead(204);
    return res.end();
  }
  if (req.method === 'POST' && path === '/api/notifications/check') return json(res, 200, { sent: 1 });
  if (path === '/api/update' && req.method === 'GET') return json(res, 200, updateStatus());
  if (path === '/api/update/check' && req.method === 'POST') {
    Object.assign(update, {
      latest: 'v0.7.0', available: update.current !== 'v0.7.0', checkedAt: new Date().toISOString(),
      notes: '### Added\n- Neue Funktion für den Vertretungsplan\n- Updates direkt aus der Web-Oberfläche\n\n### Fixed\n- Kleinere Korrekturen\n\n### Installation / Update\n\n```sh\nbash install.sh\n```',
    });
    return json(res, 200, updateStatus());
  }
  if (path === '/api/update/install' && req.method === 'POST') {
    if (!updateStatus().canInstall) return error(res, 409, 'no_update', 'No update can be installed');
    update.phase = 'downloading';
    setTimeout(() => {
      update.phase = 'restarting';
      restartingUntil = Date.now() + 3000;
      setTimeout(() => Object.assign(update, { current: update.latest, available: false, phase: 'idle' }), 3000);
    }, 1500);
    return json(res, 202, updateStatus());
  }
  if (req.method === 'POST' && path === '/api/refresh') {
    simulateSync();
    return json(res, 202, { refreshing: true });
  }
  if (path === '/api/sync') {
    const ago = (min) => new Date(Date.now() - min * 60e3).toISOString();
    const task = (interval, last) => ({ lastRun: ago(last), lastSuccess: ago(last), lastError: null,
      failures: 0, intervalMinutes: interval, nextRun: ago(last - interval) });
    return json(res, 200, { enabled: true, running: syncRunning, activeHours: [6, 22], tasks: {
      account: task(360, 50), timetable: task(360, 50), substitutions: task(15, 4), homework: task(15, 4),
      calendar: task(60, 20), lessons: task(120, 35) } });
  }
  if (path === '/api/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store' });
    res.write(`retry: 5000\n\nevent: sync\ndata: ${JSON.stringify({ running: syncRunning })}\n\n`);
    eventClients.add(res);
    const ping = setInterval(() => res.write(': ping\n\n'), 25000);
    req.on('close', () => {
      clearInterval(ping);
      eventClients.delete(res);
    });
    return;
  }
  switch (path) {
    case '/api/account':
      return data(res, 'account', { schoolId: 9999, username: 'max.muster', accountType: 'student',
        features: ['timetable', 'substitutions', 'calendar', 'lessons'] });
    case '/api/timetable': return data(res, 'timetable', timetable);
    case '/api/substitutions': {
      // Permanent filter from the settings, like the real server.
      const f = settings.substitutionFilter;
      const active = f.classes.length > 0 || f.hiddenTypes.length > 0 || f.hiddenNotices.length > 0;
      if (!active || url.searchParams.get('alle') === '1') {
        return data(res, 'substitutions', allSubstitutions(), { filter: { active: false, hidden: 0 } });
      }
      const classesOf = (c) => (c ?? '').split(/[,;?/]+/).map((x) => x.trim().toLowerCase()).filter(Boolean);
      const wanted = new Set(f.classes.map((c) => c.toLowerCase()));
      const hiddenTypes = new Set(f.hiddenTypes.map((t) => t.toLowerCase()));
      const keep = (e) => {
        if (e.type && hiddenTypes.has(e.type.toLowerCase())) return false;
        if (wanted.size === 0) return true;
        const own = classesOf(e.className);
        return own.length === 0 ? f.showUnassigned : own.some((c) => wanted.has(c));
      };
      let hidden = 0;
      const days = allSubstitutions().map((d) => {
        const entries = d.entries.filter(keep);
        hidden += d.entries.length - entries.length;
        const hiddenNotices = new Set(f.hiddenNotices.map((t) => t.toLowerCase()));
        return { ...d, entries, notices: d.notices.filter((n) => !hiddenNotices.has(n.title.trim().toLowerCase())) };
      });
      return data(res, 'substitutions', days, { filter: { active: true, hidden, classes: f.classes } });
    }
    case '/api/courses': return data(res, 'courses', courses);
    case '/api/homework': {
      const withDone = (h) => ({ ...h, done: doneOverrides.get(`${h.courseId}/${h.entryId}`) ?? h.done });
      if (url.searchParams.get('alle') !== '1') return data(res, 'homework', homework.map(withDone));
      // All homework: current entries plus older ones from the course histories.
      const all = [...homework.map(withDone)];
      for (const c of courses) {
        for (const e of courseDetails(c.id).history) {
          if (!e.homework || all.some((h) => h.courseId === c.id && h.entryId === e.id)) continue;
          all.push({ courseId: c.id, courseName: c.name, entryId: e.id, date: e.date, topic: e.topic,
            description: e.homework, done: e.homeworkDone });
        }
      }
      return data(res, 'homework:all', all.sort((a, b) => (b.date ?? '').localeCompare(a.date ?? '')));
    }
    case '/api/grades': return data(res, 'grades', grades);
    case '/api/meals': {
      // School meals (Caseda): own orders and balance; off in the settings → 404.
      if (!serverValues.CASEDA_ENABLED) return error(res, 404, 'meals_disabled', 'School meals are not set up');
      const order = (date, line, name, allergens = [], priceCents = 390, ordered = 1) =>
        ({ date: ymd(date), line, name, allergens, priceCents, ordered, deadlinePassed: date < today });
      const monday = addDays(today, -((today.getDay() + 6) % 7));
      const orders = [
        order(monday, 'Menü 1', 'Spaghetti Bolognese', ['a', 'i']),
        order(d1, 'Menü 1', 'Gemüsemaultaschen mit Kräuter-Frischkäsesauce', ['a', 'c', 'g']),
        order(d2, 'Tagesmenue', 'Putensteak mit Bio-Reis und Kräutervelouté', ['g'], 450),
        order(nextSchoolDay(d2), 'Menü 2', 'Ofenkartoffeln mit Kräuterquark', ['g']),
        order(addDays(monday, 8), 'Menü 1', 'Hähnchencurry mit Basmatireis'),
        order(addDays(monday, 10), 'Menü 2', 'Linsen-Dal mit Fladenbrot', ['a'], 390, 2),
        order(addDays(monday, 15), 'Menü 1', 'Fischstäbchen mit Kartoffelpüree', ['a', 'd', 'g']),
      ].filter((o, i, all) => all.findIndex((x) => x.date === o.date) === i)
        .sort((a, b) => a.date.localeCompare(b.date));
      return data(res, 'meals', {
        balanceCents: 845,
        orders,
      }, { balanceWarningCents: Math.round(parseFloat(String(serverValues.CASEDA_BALANCE_WARNING).replace(',', '.')) * 100), orderUrl: 'https://www.caseda-schulmenue.de/kunden/essen/' });
    }
    case '/api/calendar': {
      const from = url.searchParams.get('from') ? new Date(`${url.searchParams.get('from')}T00:00`) : today;
      const to = url.searchParams.get('to') ? new Date(`${url.searchParams.get('to')}T00:00`) : addDays(today, 60);
      const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      return data(res, `calendar:${ymd(from)}:${ymd(to)}`, calendar(from, to));
    }
  }
  const m = /^\/api\/courses\/([^/]+)$/.exec(path);
  if (m) {
    const d = courseDetails(decodeURIComponent(m[1]));
    return d ? data(res, `course:${decodeURIComponent(m[1])}`, d) : error(res, 404, 'not_found', 'Unknown course');
  }
  return error(res, 404, 'not_found', 'No such endpoint');
}

async function handleServerSettings(req, res, url) {
  const path = url.pathname;
  if (path === '/api/schools') {
    const words = (url.searchParams.get('q') ?? '').toLowerCase().split(/\s+/).filter(Boolean);
    return json(res, 200, words.length === 0 ? [] : SCHOOLS.filter((s) =>
      words.every((w) => `${s.id} ${s.name} ${s.city}`.toLowerCase().includes(w))));
  }
  if (path === '/api/server-settings/test-login') {
    const b = JSON.parse((await readBody(req)) || '{}');
    // Password "falsch" simulates wrong credentials.
    if (b.password === 'falsch') return error(res, 400, 'sph_login_failed', 'Wrong username or password');
    return json(res, 200, { ok: true });
  }
  if (path === '/api/server-settings/test-untis') {
    const b = JSON.parse((await readBody(req)) || '{}');
    if (b.password === 'falsch') return error(res, 400, 'untis_login_failed', 'Login failed');
    return json(res, 200, { ok: true, className: '07bG' });
  }
  if (path === '/api/server-settings/test-caseda') {
    const b = JSON.parse((await readBody(req)) || '{}');
    if (b.password === 'falsch') return error(res, 400, 'meals_login_failed', 'Login failed');
    return json(res, 200, { ok: true });
  }
  if (req.method === 'GET') {
    return json(res, 200, {
      setupRequired, values: serverValues, desktop: false,
      secrets: { SPH_PASSWORD: !setupRequired, NTFY_TOKEN: false, APP_PASSWORD: !setupRequired, CASEDA_PASSWORD: true, UNTIS_PASSWORD: true },
      sources: {}, restartRequired: [],
    });
  }
  const b = JSON.parse((await readBody(req)) || '{}');
  const s = b.settings ?? {};
  if (s.SPH_PASSWORD === 'falsch') return error(res, 400, 'sph_login_failed', 'Wrong username or password');
  if (s.POLL_INTERVAL_MINUTES && Number(s.POLL_INTERVAL_MINUTES) < 5) {
    return json(res, 400, { error: { code: 'invalid_settings', message: 'Invalid settings',
      problems: ['POLL_INTERVAL_MINUTES must be at least 5'] } });
  }
  if (b.appPassword) {
    if (!setupRequired && b.currentPassword !== appPassword) {
      return error(res, 403, 'invalid_password', 'Current password is wrong');
    }
    appPassword = b.appPassword;
  }
  const restart = [];
  for (const [k, v] of Object.entries(s)) {
    if (k === 'SPH_PASSWORD' || k === 'NTFY_TOKEN' || k === 'CASEDA_PASSWORD' || k === 'UNTIS_PASSWORD') continue;
    if (['HOST', 'PORT'].includes(k) && String(serverValues[k]) !== String(v)) restart.push(k);
    serverValues[k] = typeof serverValues[k] === 'number' ? Number(v)
      : typeof serverValues[k] === 'boolean' ? v === 'true' : v;
  }
  const headers = {};
  const wasSetup = setupRequired;
  if (setupRequired) {
    setupRequired = false;
    const t = Math.random().toString(36).slice(2);
    sessions.add(t);
    headers['set-cookie'] = `sph_session=${t}; Path=/; HttpOnly; SameSite=Strict`;
  }
  return json(res, 200, { saved: true, setupRequired, restartRequired: restart,
    accountChanged: !wasSetup && 'SPH_USERNAME' in s }, headers);
}

async function handleStatic(req, res, url) {
  const rel = normalize(decodeURIComponent(url.pathname)).replace(/^([/\\])+/, '');
  let file = join(webDir, rel);
  if (!file.startsWith(webDir + sep) && file !== webDir) return error(res, 403, 'forbidden', 'Forbidden');
  try {
    if ((await stat(file)).isDirectory()) file = join(file, 'index.html');
  } catch {
    file = join(webDir, 'index.html'); // SPA fallback
  }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(body);
  } catch {
    error(res, 404, 'not_found', 'Not found');
  }
}

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname.startsWith('/api/')) await handleApi(req, res, url);
    else await handleStatic(req, res, url);
  } catch (e) {
    error(res, 500, 'internal', String(e));
  }
}).listen(port, '127.0.0.1', () => {
  console.log(`Mock server: http://127.0.0.1:${port}  (password: demo${stale ? ', stale mode' : ''})`);
  if (setupRequired) console.log(`Setup page: http://127.0.0.1:${port}/einrichtung?token=${SETUP_TOKEN}`);
});
