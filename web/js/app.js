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
import * as notifications from './views/notifications.js';

route('/', today);
route('/stundenplan', timetable);
route('/vertretungen', substitutions);
route('/hausaufgaben', homework);
route('/noten', grades);
route('/kurse/:id', course);
route('/kalender', calendar);
route('/benachrichtigungen', notifications);

const NAV = [
  { path: '/', label: 'Heute', icon: 'today' },
  { path: '/stundenplan', label: 'Stundenplan', icon: 'timetable', feature: 'timetable' },
  { path: '/vertretungen', label: 'Vertretungen', icon: 'substitutions', feature: 'substitutions' },
  { path: '/hausaufgaben', label: 'Hausaufgaben', icon: 'homework', feature: 'lessons' },
  { path: '/noten', label: 'Noten', icon: 'grades', feature: 'lessons' },
  { path: '/kalender', label: 'Kalender', icon: 'calendar', feature: 'calendar' },
];

const root = document.getElementById('app');

/** @type {{features: Set<string>, username: string} | null} */
let account = null;
let renderToken = 0;
let shell = null;

async function boot() {
  root.className = '';
  try {
    const me = await api('/api/auth/me');
    if (!me.authenticated) return showLogin();
    const acc = await api('/api/account');
    account = { features: new Set(acc.data.features), username: acc.data.username };
    showShell();
  } catch (err) {
    if (err instanceof ApiError && err.isUnauthorized) return showLogin();
    root.replaceChildren(
      h('main', { class: 'centered' }, errorBox(errorMessage(err)),
        h('button', { class: 'button', onclick: boot }, 'Erneut versuchen')),
    );
  }
}

function showLogin() {
  account = null;
  shell = null;
  document.title = 'Anmelden – Schulportal';
  root.replaceChildren(login.render({ onSuccess: boot }));
}

function showShell() {
  const main = h('main', { id: 'main', tabindex: '-1' });
  const status = h('span', { class: 'status', 'aria-live': 'polite' });
  const refreshButton = h('button', {
    class: 'icon-button', title: 'Neu laden', 'aria-label': 'Neu vom Schulportal laden',
    onclick: refresh,
  }, icon('refresh'));
  const nav = h('nav', { class: 'nav', 'aria-label': 'Hauptnavigation' },
    NAV.filter((n) => !n.feature || account.features.has(n.feature)).map((n) =>
      h('a', { href: n.path, class: 'nav-link', dataset: { path: n.path } },
        icon(n.icon), h('span', null, n.label))),
  );
  const header = h('header', { class: 'topbar' },
    h('a', { href: '/', class: 'brand' }, h('img', { src: '/icon.svg', alt: '' }), 'Schulportal'),
    status,
    h('div', { class: 'topbar-actions' },
      refreshButton,
      h('a', {
        href: '/benachrichtigungen', class: 'icon-button', title: 'Benachrichtigungen',
        'aria-label': 'Benachrichtigungen',
      }, icon('bell')),
      h('button', {
        class: 'icon-button', title: 'Abmelden', 'aria-label': 'Abmelden', onclick: logout,
      }, icon('logout')),
    ),
  );
  shell = { main, status, nav, refreshButton };
  root.replaceChildren(header, h('div', { class: 'layout' }, nav, main));
  renderRoute();
}

async function renderRoute({ focus = true } = {}) {
  if (!shell) return;
  const token = ++renderToken;
  const found = match(location.pathname);
  const { main, status, nav } = shell;

  for (const a of nav.querySelectorAll('.nav-link')) {
    const path = a.dataset.path;
    const active = path === '/' ? location.pathname === '/' :
      location.pathname.startsWith(path) ||
      (path === '/noten' && location.pathname.startsWith('/kurse/'));
    a.classList.toggle('active', active);
    if (active) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }

  if (!found) {
    document.title = 'Nicht gefunden – Schulportal';
    main.replaceChildren(h('h1', null, 'Seite nicht gefunden'), h('a', { href: '/' }, 'Zur Startseite'));
    return;
  }

  const metas = [];
  const ctx = {
    params: found.params,
    query: new URLSearchParams(location.search),
    features: account.features,
    /** Loads a data endpoint and records its freshness. */
    async get(path) {
      const res = await api(path);
      metas.push(res);
      return res.data;
    },
  };

  status.textContent = '';
  main.setAttribute('aria-busy', 'true');
  main.replaceChildren(h('div', { class: 'loading' }, 'Laden …'));
  document.title = `${found.view.title} – Schulportal`;

  let content;
  try {
    content = await found.view.render(ctx);
  } catch (err) {
    if (token !== renderToken) return;
    if (err instanceof ApiError && err.isUnauthorized) return showLogin();
    content = h('div', null, h('h1', null, found.view.title), errorBox(errorMessage(err)));
  }
  if (token !== renderToken) return;

  main.removeAttribute('aria-busy');
  main.replaceChildren(content);
  if (focus) main.focus({ preventScroll: true });
  updateStatus(metas);
}

function updateStatus(metas) {
  const { status } = shell;
  status.className = 'status';
  if (metas.length === 0) {
    status.textContent = '';
    return;
  }
  const oldest = metas.map((m) => m.fetchedAt).sort()[0];
  if (metas.some((m) => m.stale)) {
    status.classList.add('stale');
    status.textContent = `Offline – Stand ${age(oldest)}`;
    status.title = 'Das Schulportal ist nicht erreichbar; es werden gespeicherte Daten angezeigt.';
  } else {
    status.textContent = `Stand ${age(oldest)}`;
    status.title = '';
  }
}

async function refresh() {
  const button = shell?.refreshButton;
  if (!button || button.disabled) return;
  button.disabled = true;
  button.classList.add('spinning');
  try {
    await api('/api/refresh', { method: 'POST' });
    await renderRoute({ focus: false });
  } catch (err) {
    if (err instanceof ApiError && err.isUnauthorized) return showLogin();
    shell.status.textContent = errorMessage(err);
  } finally {
    button.disabled = false;
    button.classList.remove('spinning');
  }
}

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
