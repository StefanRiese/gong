// Development server for the web UI with a fake API (no Schulportal access).
//
// Serves ../web and answers /api/* with invented sample data in the same
// format as the real Dart server. Login password: "demo".
//
//   node dev/mock-server.mjs [port]      (default 8090)
//   MOCK_STALE=1 node dev/mock-server.mjs   → responses marked as stale

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const port = Number(process.argv[2] ?? 8090);
const webDir = resolve(fileURLToPath(new URL('../web', import.meta.url)));
const stale = process.env.MOCK_STALE === '1';
const sessions = new Set();

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
const lesson = (weekday, period, duration, subject, room, teacher, week = null) => ({
  weekday, period, duration, start: slot(period).start, end: slot(period + duration - 1).end,
  subject, room, teacher, week,
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
    ],
    notices: [{ title: 'Allgemein', lines: ['Wandertag der Klassen 9a und 9b.', '<b>Bitte Sportzeug</b> nicht vergessen!'] }],
  },
  {
    date: ymd(d2),
    entries: [
      { period: '1', type: 'Raumänderung', subject: 'Biologie', previousSubject: null, teacher: 'Hartmann',
        substitute: null, room: 'N201', previousRoom: 'N203', className: '7b', note: null },
    ],
    notices: [],
  },
];

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
const data = (res, value) => json(res, 200, {
  data: value,
  fetchedAt: new Date(Date.now() - (stale ? 26 * 3600e3 : 4 * 60e3)).toISOString(),
  cached: true,
  stale,
});

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
  if (req.method === 'POST' && path === '/api/auth/login') {
    const { password } = JSON.parse((await readBody(req)) || '{}');
    if (password !== 'demo') return error(res, 401, 'invalid_password', 'Wrong password');
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

  if (req.method === 'POST' && path === '/api/refresh') {
    res.writeHead(204);
    return res.end();
  }
  switch (path) {
    case '/api/account':
      return data(res, { schoolId: 9999, username: 'max.muster', accountType: 'student',
        features: ['timetable', 'substitutions', 'calendar', 'lessons'] });
    case '/api/timetable': return data(res, timetable);
    case '/api/substitutions': return data(res, substitutions);
    case '/api/courses': return data(res, courses);
    case '/api/homework': return data(res, homework);
    case '/api/grades': return data(res, grades);
    case '/api/calendar': {
      const from = url.searchParams.get('from') ? new Date(`${url.searchParams.get('from')}T00:00`) : today;
      const to = url.searchParams.get('to') ? new Date(`${url.searchParams.get('to')}T00:00`) : addDays(today, 60);
      return data(res, calendar(from, to));
    }
  }
  const m = /^\/api\/courses\/([^/]+)$/.exec(path);
  if (m) {
    const d = courseDetails(decodeURIComponent(m[1]));
    return d ? data(res, d) : error(res, 404, 'not_found', 'Unknown course');
  }
  return error(res, 404, 'not_found', 'No such endpoint');
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
});
