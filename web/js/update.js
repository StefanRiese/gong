// App updates: hint bar, release notes, installing and waiting for the
// restarted server.

import { api } from './api.js';
import { h } from './dom.js';

const DISMISSED_KEY = 'updateDismissed';

/** Hint below the top bar when a new release is available (dismissable per version). */
export async function updateHint() {
  let status;
  try {
    status = await api('/api/update');
  } catch {
    return null;
  }
  if (!status.available) return null;
  try {
    if (localStorage.getItem(DISMISSED_KEY) === status.latest) return null;
  } catch {
    // storage unavailable: show it
  }
  const bar = h('div', { class: 'portal-notice update-notice', role: 'status' },
    h('span', null, `Version ${status.latest.replace(/^v/, '')} ist verfügbar.`),
    h('a', { href: '/einstellungen#update', class: 'button small' }, 'Details'),
    h('button', {
      type: 'button', class: 'button small', 'aria-label': 'Hinweis ausblenden',
      onclick: () => {
        try {
          localStorage.setItem(DISMISSED_KEY, status.latest);
        } catch {
          // ignore
        }
        bar.remove();
      },
    }, '×'));
  return bar;
}

/**
 * Release notes (Markdown from CHANGELOG.md) as DOM: headings, bullet lists,
 * paragraphs; inline markup is dropped. The install instructions that the
 * release page adds are left out.
 */
export function releaseNotes(markdown) {
  const text = (markdown ?? '').split(/^### Installation/m)[0].split(/^\*\*Full Changelog/m)[0];
  const plain = (s) => s.replace(/`([^`]*)`/g, '$1').replace(/\*\*([^*]*)\*\*/g, '$1').replace(/\*([^*]*)\*/g, '$1');
  const out = [];
  let list = null;
  let item = null;
  for (const raw of text.split('\n')) {
    const line = raw.trimEnd();
    if (/^#{2,4}\s/.test(line)) {
      list = item = null;
      out.push(h('h4', null, plain(line.replace(/^#+\s*/, ''))));
    } else if (/^\s*[-*]\s/.test(line)) {
      if (!list) out.push(list = h('ul'));
      item = h('li', null, plain(line.replace(/^\s*[-*]\s*/, '')));
      list.append(item);
    } else if (/^\s+\S/.test(line) && item) {
      item.append(` ${plain(line.trim())}`);
    } else if (line.trim()) {
      list = item = null;
      out.push(h('p', null, plain(line.trim())));
    } else {
      item = null;
    }
  }
  return h('div', { class: 'release-notes' }, out);
}

let versionWatch = false;

/**
 * Reloads the app when the server runs a newer version than the one loaded.
 * An installed app (home screen) stays in memory for days and is not reloaded
 * when it is opened again, so it would keep running old code. Checks at start,
 * when the app becomes visible again, when the network is back and every
 * 10 minutes; not while someone is typing.
 */
export function watchServerVersion() {
  if (versionWatch) return;
  versionWatch = true;
  let running = null;
  let last = 0;
  const check = async () => {
    if (Date.now() - last < 10e3) return;
    last = Date.now();
    let current;
    try {
      current = (await api('/api/update')).current;
    } catch {
      return; // offline, logged out or restarting: next time
    }
    if (!current) return; // development build
    if (running == null) {
      running = current;
      return;
    }
    if (current === running) return;
    if (document.activeElement?.matches('input, textarea, select')) {
      last = 0; // typing: try again at the next trigger
      return;
    }
    await reloadFresh();
  };
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') check();
  });
  window.addEventListener('pageshow', check);
  window.addEventListener('online', check);
  setInterval(check, 10 * 60e3);
  check();
}

/** Loads the app's files again past the HTTP cache, then reloads the page. */
async function reloadFresh() {
  const own = (url) => url.startsWith(location.origin);
  const urls = new Set([
    `${location.origin}/`,
    ...performance.getEntriesByType('resource').map((e) => e.name).filter(own),
  ]);
  await Promise.all([...urls].filter((u) => !u.includes('/api/'))
    .map((u) => fetch(u, { cache: 'reload' }).catch(() => {})));
  location.reload();
}

/**
 * Waits until the server answers with a version other than [from] (after the
 * restart), then reloads the page. [onProgress] gets German status texts.
 */
export async function waitForNewVersion(from, onProgress, { timeoutMs = 5 * 60e3 } = {}) {
  const until = Date.now() + timeoutMs;
  let wasDown = false;
  while (Date.now() < until) {
    await new Promise((r) => setTimeout(r, 2000));
    try {
      const s = await api('/api/update');
      if (s.phase === 'failed') throw Object.assign(new Error(s.error ?? 'Update fehlgeschlagen'), { failed: true });
      if (s.current && s.current !== from) {
        onProgress('Neue Version läuft – Seite wird neu geladen …');
        location.reload();
        return;
      }
      onProgress(wasDown ? 'Server startet …' : 'Update wird installiert …');
    } catch (err) {
      if (err.failed) throw err;
      wasDown = true; // restarting
      onProgress('Server wird neu gestartet …');
    }
  }
  throw new Error('Der Server ist nach dem Update nicht wieder erreichbar. Bitte später neu laden.');
}
