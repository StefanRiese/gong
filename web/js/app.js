// App shell: login gate, navigation, view rendering.

import { api, ApiError, errorMessage } from './api.js';
import { h, icon, errorBox } from './dom.js';
import { age } from './format.js';
import { route, match, navigate, startRouter } from './router.js';
import * as login from './views/login.js';
import * as today from './views/today.js';
import * as timetable from './views/timetable.js';
import * as substitutions from './views/substitutions.js';
import * as homework from './views/homework.js';
import * as grades from './views/grades.js';
import * as course from './views/course.js';
import * as calendar from './views/calendar.js';
import * as meals from './views/meals.js';
import * as notifications from './views/notifications.js';
import * as settings from './views/settings.js';
import * as subjects from './views/subjects.js';
import * as setup from './views/setup.js';
import { initColors } from './colors.js';
import { initScheme, isDark, toggleMode } from './scheme.js';
import { updateHint, watchServerVersion } from './update.js';

initScheme();

/** The server settings are part of the settings page now (old links and apps). */
const serverSettingsMoved = {
  title: 'Einstellungen',
  async render() {
    navigate(`/einstellungen${location.hash}`, { replace: true });
    return h('div');
  },
};

route('/', today);
route('/stundenplan', timetable);
route('/vertretungen', substitutions);
route('/hausaufgaben', homework);
route('/noten', grades);
route('/kurse/:id', course);
route('/kalender', calendar);
route('/schulessen', meals);
route('/benachrichtigungen', notifications);
route('/einstellungen', settings);
route('/einstellungen/server', serverSettingsMoved);
route('/faecher', subjects);

// short: label in the phone tab bar
const NAV = [
  { path: '/', label: 'Heute', icon: 'today' },
  { path: '/stundenplan', label: 'Stundenplan', short: 'Plan', icon: 'timetable', feature: 'timetable' },
  { path: '/vertretungen', label: 'Vertretungen', short: 'Vertr.', icon: 'substitutions', feature: 'substitutions' },
  { path: '/hausaufgaben', label: 'Hausaufgaben', short: 'HA', icon: 'homework', feature: 'lessons' },
  { path: '/noten', label: 'Noten', icon: 'grades', feature: 'lessons' },
  { path: '/faecher', label: 'Fächer', icon: 'subjects', feature: 'lessons' },
  { path: '/kalender', label: 'Kalender', short: 'Termine', icon: 'calendar', feature: 'calendar' },
  { path: '/schulessen', label: 'Schulessen', short: 'Essen', icon: 'meals', feature: 'meals' },
];

const root = document.getElementById('app');

/** @type {{features: Set<string>, username: string} | null} */
let account = null;
let renderToken = 0;
let shell = null;

/** Cache keys of the data shown by the current page (for live updates). */
let liveKeys = new Set();
/** @type {EventSource | null} */
let events = null;
let liveTimer = null;

const ACCOUNT_KEY = 'lastAccount';
const ALL_FEATURES = ['timetable', 'substitutions', 'calendar', 'lessons'];

/** Last successfully loaded account (per browser), for starting while the portal is down. */
function rememberedAccount() {
  try {
    const saved = JSON.parse(localStorage.getItem(ACCOUNT_KEY) ?? 'null');
    return Array.isArray(saved?.features) ? saved : null;
  } catch {
    return null;
  }
}

function rememberAccount(acc) {
  try {
    localStorage.setItem(ACCOUNT_KEY, JSON.stringify({ features: acc.features, username: acc.username }));
  } catch {
    // storage unavailable
  }
}

async function boot() {
  root.className = '';
  try {
    const { setupRequired } = await api('/api/setup');
    if (setupRequired) return showSetup();
    if (location.pathname === '/einrichtung') history.replaceState(null, '', '/');
    const me = await api('/api/auth/me');
    if (!me.authenticated) return showLogin();
    let portalProblem = null;
    try {
      const acc = await api('/api/account');
      rememberAccount(acc.data);
      account = { features: new Set(acc.data.features), username: acc.data.username };
    } catch (err) {
      if (err instanceof ApiError && err.isUnauthorized) throw err;
      // Portal down or disturbed: start anyway with what we knew last time;
      // pages show cached data or their own error.
      const saved = rememberedAccount();
      account = { features: new Set(saved?.features ?? ALL_FEATURES), username: saved?.username ?? '' };
      portalProblem = err;
    }
    const [, withMeals] = await Promise.all([loadColors(), mealsEnabled()]);
    if (withMeals) account.features.add('meals');
    showShell();
    watchServerVersion();
    if (portalProblem) showPortalProblem(portalProblem);
    updateHint().then((bar) => {
      if (bar) root.querySelector('.topbar')?.after(bar);
    });
  } catch (err) {
    if (err instanceof ApiError && err.isUnauthorized) return showLogin();
    root.replaceChildren(
      h('main', { class: 'centered' }, errorBox(errorMessage(err)),
        h('button', { class: 'button', onclick: boot }, 'Erneut versuchen')),
    );
  }
}

/** Whether school meals (Caseda) are set up and switched on on the server. */
async function mealsEnabled() {
  try {
    await api('/api/meals');
    return true;
  } catch (err) {
    if (err instanceof ApiError && err.isUnauthorized) throw err;
    // Caseda down: the page still shows cached data or the error.
    return !(err instanceof ApiError && err.code === 'meals_disabled');
  }
}

/** Server settings switched school meals on or off: update the menu. */
window.addEventListener('lumo:meals-changed', async () => {
  if (!account || !shell) return;
  const on = await mealsEnabled().catch(() => false);
  if (on === account.features.has('meals')) return;
  if (on) account.features.add('meals'); else account.features.delete('meals');
  // Only the menu: the settings page keeps its message.
  const nav = buildNav();
  markActiveNav(nav);
  shell.nav.replaceWith(nav);
  shell.nav = nav;
});

/** Loads what subject colors are derived from (one assignment app-wide). */
async function loadColors() {
  const optional = (enabled, path) =>
    (enabled ? api(path).then((r) => r.data ?? r, () => null) : Promise.resolve(null));
  const [settings, timetable, courses] = await Promise.all([
    api('/api/settings').catch(() => null),
    optional(account.features.has('timetable'), '/api/timetable'),
    optional(account.features.has('lessons'), '/api/courses'),
  ]);
  initColors({
    settings: settings ?? undefined,
    subjects: timetable?.lessons?.map((l) => l.subject) ?? [],
    courses: courses ?? [],
  });
}

/** Server not set up yet: setup page instead of the login. */
function showSetup() {
  stopLive();
  account = null;
  shell = null;
  root.replaceChildren(setup.render({ token: setup.takeToken(), onDone: boot }));
}

function showLogin() {
  stopLive();
  account = null;
  shell = null;
  document.title = 'Anmelden – Lumo';
  root.replaceChildren(login.render({ onSuccess: boot }));
}

/** Main navigation for the features of the account. */
function buildNav() {
  return h('nav', { class: 'nav', 'aria-label': 'Hauptnavigation' },
    NAV.filter((n) => !n.feature || account.features.has(n.feature)).map((n) =>
      h('a', {
        href: n.path, class: 'nav-link', dataset: { path: n.path },
        title: n.label, 'aria-label': n.label,
      },
      icon(n.icon),
      h('span', { class: 'label-long' }, n.label),
      h('span', { class: 'label-short', 'aria-hidden': 'true' }, n.short ?? n.label))),
  );
}

/** Marks the navigation link of the current page. */
function markActiveNav(nav) {
  for (const a of nav.querySelectorAll('.nav-link')) {
    const path = a.dataset.path;
    const active = path === '/' ? location.pathname === '/' :
      location.pathname.startsWith(path) ||
      (path === '/faecher' && location.pathname.startsWith('/kurse/'));
    a.classList.toggle('active', active);
    if (active) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
}

function showShell() {
  const main = h('main', { id: 'main', tabindex: '-1' });
  const status = h('span', { class: 'status', 'aria-live': 'polite' });
  const refreshButton = h('button', {
    class: 'icon-button', title: 'Neu laden', 'aria-label': 'Neu vom Schulportal laden',
    onclick: refresh,
  }, icon('refresh'));
  // Light / dark by hand: shows the mode it switches to.
  const modeButton = h('button', { class: 'icon-button', onclick: toggleMode });
  const showMode = () => {
    const dark = isDark();
    modeButton.title = dark ? 'Helles Design' : 'Dunkles Design';
    modeButton.setAttribute('aria-label', modeButton.title);
    modeButton.replaceChildren(icon(dark ? 'sun' : 'moon'));
  };
  showMode();
  window.addEventListener('lumo:theme', showMode);
  const nav = buildNav();
  const header = h('header', { class: 'topbar' },
    h('a', { href: '/', class: 'brand' }, h('img', { src: '/icon.svg', alt: '' }), 'Lumo'),
    status,
    h('div', { class: 'topbar-actions' },
      refreshButton,
      modeButton,
      h('a', {
        href: '/einstellungen', class: 'icon-button', title: 'Einstellungen',
        'aria-label': 'Einstellungen',
      }, icon('settings')),
    ),
  );
  shell = { main, status, nav, refreshButton };
  root.replaceChildren(header, h('div', { class: 'layout' }, nav, main));
  renderRoute();
  startLive();
}

/**
 * Renders the current route. quiet: live update of the same page (no loading
 * placeholder, no focus change; on errors the old content stays).
 */
async function renderRoute({ focus = true, quiet = false } = {}) {
  if (!shell) return;
  const token = ++renderToken;
  const found = match(location.pathname);
  const { main, status, nav } = shell;

  markActiveNav(nav);

  if (!found) {
    document.title = 'Nicht gefunden – Lumo';
    main.replaceChildren(h('h1', null, 'Seite nicht gefunden'), h('a', { href: '/' }, 'Zur Startseite'));
    return;
  }

  const metas = [];
  const keys = new Set();
  /** Loads a data endpoint (whole response) and records freshness and cache key. */
  const getFull = async (path) => {
    const res = await api(path);
    metas.push(res);
    if (res.key) keys.add(res.key);
    return res;
  };
  const ctx = {
    params: found.params,
    query: new URLSearchParams(location.search),
    features: account.features,
    /** Loads a data endpoint and returns its data. */
    get: async (path) => (await getFull(path)).data,
    /** Like get(), but returns the whole response (e.g. with `filter`). */
    getFull,
  };

  if (!quiet) {
    status.textContent = '';
    main.setAttribute('aria-busy', 'true');
    main.replaceChildren(h('div', { class: 'loading' }, 'Laden …'));
    document.title = `${found.view.title} – Lumo`;
  }

  let content;
  try {
    content = await found.view.render(ctx);
  } catch (err) {
    if (token !== renderToken) return;
    if (err instanceof ApiError && err.isUnauthorized) return showLogin();
    if (quiet) return; // keep what is shown
    content = h('div', null, h('h1', null, found.view.title), errorBox(errorMessage(err)));
  }
  if (token !== renderToken) return;

  main.removeAttribute('aria-busy');
  main.replaceChildren(content);
  if (focus) main.focus({ preventScroll: true });
  // Links like /einstellungen#vertretungsplan jump to the section.
  if (!quiet && location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
  // Same Set object: data a page loads later (e.g. Heute) is tracked too.
  liveKeys = keys;
  updateStatus(metas);
}

// --- live updates -------------------------------------------------------------

/** Follows /api/events: re-renders the page when its data changed on the server. */
function startLive() {
  stopLive();
  if (typeof EventSource === 'undefined') return;
  events = new EventSource('/api/events');
  const parse = (e) => {
    try {
      return JSON.parse(e.data);
    } catch {
      return null;
    }
  };
  events.addEventListener('update', (e) => {
    const msg = parse(e);
    if (msg && liveKeys.has(msg.key)) scheduleLiveRender();
  });
  events.addEventListener('sync', (e) => {
    const msg = parse(e);
    if (msg) setSyncing(Boolean(msg.running));
  });
}

function stopLive() {
  events?.close();
  events = null;
  clearTimeout(liveTimer);
  liveKeys = new Set();
}

/** Several updates arrive together during a sync: render once. */
function scheduleLiveRender() {
  clearTimeout(liveTimer);
  liveTimer = setTimeout(liveRender, 600);
}

function liveRender() {
  if (!shell) return;
  const found = match(location.pathname);
  if (!found || found.view.live === false) return;
  // Do not pull the rug from under someone typing or choosing.
  const active = document.activeElement;
  if (active && shell.main.contains(active) && active.matches('input, select, textarea')) {
    active.addEventListener('blur', scheduleLiveRender, { once: true });
    return;
  }
  renderRoute({ focus: false, quiet: true });
}

/** Refresh button shows whether a sync with Schulportal is running. */
function setSyncing(running) {
  const button = shell?.refreshButton;
  if (!button) return;
  button.classList.toggle('spinning', running);
  button.disabled = running;
  button.title = running ? 'Wird aktualisiert …' : 'Neu laden';
}

let portalNotice = null;

/** Persistent notice below the top bar while the portal cannot be used. */
function showPortalProblem(err) {
  portalNotice?.remove();
  portalNotice = h('div', { class: 'portal-notice', role: 'status' },
    h('span', null, errorMessage(err), ' Angezeigt werden – falls vorhanden – zuletzt geladene Daten.'),
    h('button', {
      class: 'button small', type: 'button',
      onclick: () => {
        portalNotice?.remove();
        portalNotice = null;
        boot(); // full restart; shows the notice again if the portal is still down
      },
    }, 'Erneut versuchen'));
  root.querySelector('.topbar')?.after(portalNotice);
}

function updateStatus(metas) {
  const { status } = shell;
  status.className = 'status';
  if (metas.length === 0) {
    status.textContent = '';
    return;
  }
  const oldest = metas.map((m) => m.fetchedAt).sort()[0];
  const refreshing = metas.some((m) => m.refreshing) ? ' · wird aktualisiert' : '';
  if (metas.some((m) => m.stale)) {
    status.classList.add('stale');
    status.textContent = `Offline – Stand ${age(oldest)}${refreshing}`;
    status.title = 'Das Schulportal ist nicht erreichbar; es werden gespeicherte Daten angezeigt.';
  } else {
    status.textContent = refreshing ? 'Wird aktualisiert …' : '';
    status.title = refreshing ? 'Die Daten werden im Hintergrund vom Schulportal geladen.' : '';
  }
}

/**
 * Asks the server to sync all data with Schulportal. The request returns
 * right away; the page updates when the sync is done (and in between via
 * live updates).
 */
async function refresh() {
  const button = shell?.refreshButton;
  if (!button || button.disabled) return;
  setSyncing(true);
  try {
    const res = await api('/api/refresh', { method: 'POST' });
    if (res === null) {
      await renderRoute({ focus: false }); // 204: server without sync
    } else {
      await waitForSync();
      // With an open event stream the page already followed the updates.
      if (events?.readyState !== EventSource.OPEN) await renderRoute({ focus: false, quiet: true });
    }
  } catch (err) {
    if (err instanceof ApiError && err.isUnauthorized) return showLogin();
    if (shell) shell.status.textContent = errorMessage(err);
  } finally {
    setSyncing(false);
  }
}

/** Waits until the server's sync is finished (max. 5 minutes). */
async function waitForSync() {
  const until = Date.now() + 5 * 60e3;
  while (Date.now() < until) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    const s = await api('/api/sync');
    if (!s.running) return;
  }
}

/** The logout button is on the settings page (it fires this event). */
window.addEventListener('lumo:logout', () => logout());

async function logout() {
  try {
    await api('/api/auth/logout', { method: 'POST' });
  } finally {
    navigate('/', { replace: true });
    showLogin();
  }
}

startRouter(() => {
  window.scrollTo(0, 0);
  renderRoute();
});
boot();
