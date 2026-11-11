// Connection and health LEDs in the top bar: the server itself, the services of the
// shown child (Schulportal, school meals, WebUntis) and the services of the server
// (ntfy, update check). Green = fine, yellow = limited / retrying, red = down,
// gray = not known. A click opens the details (all children). The data comes from
// GET /api/status; the server LED is this page's own connection to the server.

import { api, ApiError } from './api.js';
import { h } from './dom.js';
import { age } from './format.js';
import { accounts, current } from './accounts.js';

const POLL_MS = 30e3;
const STATE_TEXT = { ok: 'in Ordnung', warn: 'eingeschränkt', error: 'gestört', unknown: 'unbekannt' };
const ORDER = ['error', 'warn', 'unknown', 'ok'];

/** The browser's own connection to the server as a service entry. */
function serverEntry(failed, checkedAt) {
  return failed
    ? { key: 'server', name: 'Server', state: 'error', detail: 'Der Server ist nicht erreichbar' }
    : { key: 'server', name: 'Server', state: 'ok', detail: 'Verbunden', lastSuccess: checkedAt };
}

/** LED dot; the state is also in the text around it (not only in the color). */
function led(state) {
  return h('span', { class: `led led-${state}`, 'aria-hidden': 'true' });
}

function row(entry) {
  return h('li', { class: 'status-row' },
    led(entry.state),
    h('div', null,
      h('strong', null, entry.name),
      ` – ${STATE_TEXT[entry.state]}`,
      h('div', { class: 'detail' }, entry.detail,
        entry.lastSuccess ? ` · zuletzt ${age(entry.lastSuccess)}` : '')));
}

/**
 * Creates the LED cluster for the top bar.
 * @returns {{el: HTMLElement, start: () => void, stop: () => void, refresh: () => void}}
 */
export function createStatus() {
  let data = null;
  let failed = false;
  let timer = null;
  let isOpen = false;
  // Everything registered on document / window ends with stop().
  const lifetime = new AbortController();
  const { signal } = lifetime;

  const leds = h('span', { class: 'leds-row' });
  const button = h('button', {
    type: 'button', class: 'leds', 'aria-haspopup': 'true', 'aria-expanded': 'false',
    'aria-label': 'Verbindungsstatus', title: 'Verbindungsstatus',
  }, leds);
  const popover = h('div', { class: 'status-popover', role: 'dialog', 'aria-label': 'Verbindungsstatus', hidden: true });
  const el = h('div', { class: 'status-leds' }, button, popover);

  /** Entries shown as LEDs: server, services of the shown child, services of the server. */
  const ledEntries = () => {
    const server = serverEntry(failed, data?.checkedAt);
    if (failed || !data) return [server];
    const own = data.accounts.find((a) => a.id === current)?.services ?? [];
    return [server, ...own, ...data.services];
  };

  const render = () => {
    const entries = ledEntries();
    leds.replaceChildren(...entries.map((e) => led(e.state)));
    const worst = ORDER.find((s) => entries.some((e) => e.state === s)) ?? 'unknown';
    const summary = worst === 'ok' ? 'Alles in Ordnung'
      : worst === 'unknown' ? 'Status noch unbekannt'
        : worst === 'warn' ? 'Es gibt Einschränkungen' : 'Es gibt eine Störung';
    button.setAttribute('aria-label', `Verbindungsstatus: ${summary}`);
    button.title = `Verbindungsstatus: ${summary}`;
    if (isOpen) renderPopover();
  };

  const renderPopover = () => {
    const groups = [];
    groups.push(h('section', { class: 'status-group' },
      h('h3', null, 'Server'),
      h('ul', null, [serverEntry(failed, data?.checkedAt), ...(data?.services ?? [])].map(row))));
    for (const account of data?.accounts ?? []) {
      groups.push(h('section', { class: 'status-group' },
        h('h3', null, accounts.length > 1 ? account.name : 'Schulportal-Konto'),
        h('ul', null, account.services.map(row))));
    }
    popover.replaceChildren(...groups);
  };

  const load = async () => {
    try {
      data = await api('/api/status');
      failed = false;
    } catch (err) {
      // Logged out: the app shows the login. Anything else: the server cannot be reached.
      if (err instanceof ApiError && err.isUnauthorized) return;
      failed = !(err instanceof ApiError) || err.status === 0 || err.status >= 500;
    }
    render();
  };

  const setOpen = (value) => {
    isOpen = value;
    popover.hidden = !value;
    button.setAttribute('aria-expanded', String(value));
    if (value) {
      renderPopover();
      load(); // fresh values while looking at them
    }
  };

  button.addEventListener('click', () => setOpen(!isOpen));
  document.addEventListener('click', (e) => {
    if (isOpen && !el.contains(e.target)) setOpen(false);
  }, { signal });
  document.addEventListener('keydown', (e) => {
    if (isOpen && e.key === 'Escape') {
      setOpen(false);
      button.focus();
    }
  }, { signal });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && timer) load();
  }, { signal });
  window.addEventListener('lumo:accounts-changed', () => timer && load(), { signal });

  render();
  return {
    el,
    start() {
      load();
      timer = setInterval(load, POLL_MS);
    },
    stop() {
      clearInterval(timer);
      timer = null;
      lifetime.abort();
    },
    refresh: load,
  };
}
