// Einstellungen: everything on one page, in flat groups, with one save button.
// Personal settings (substitution filter, subject colors) and server settings
// (logins, sync, notifications, network, update) are saved together; only
// what changed is sent.

import { api, ApiError, errorMessage } from '../api.js';
import { h, errorBox } from '../dom.js';
import { initColors } from '../colors.js';
import { pageHeader } from './common.js';
import { messageArea } from './forms.js';
import { createForm } from './settings-form.js';
import {
  accessGroup, colorsGroup, mealsGroup, notifyGroup, portalGroup, substitutionsGroup, syncGroup,
  updateGroup,
} from './settings-groups.js';

export const title = 'Einstellungen';

/** No live re-rendering: it would discard unsaved changes. */
export const live = false;

let guard = null;

export async function render(ctx) {
  let server;
  try {
    server = await api('/api/server-settings');
  } catch (err) {
    return h('div', null, pageHeader('Einstellungen'), errorBox(errorMessage(err)));
  }
  const [personal, sync, update, timetable, courses, plan] = await Promise.all([
    api('/api/settings'),
    api('/api/sync').catch(() => null),
    api('/api/update').catch(() => null),
    ctx.features.has('timetable') ? ctx.get('/api/timetable') : Promise.resolve(null),
    ctx.features.has('lessons') ? ctx.get('/api/courses') : Promise.resolve([]),
    // The full plan (all classes) to choose the own class from.
    ctx.features.has('substitutions')
      ? api('/api/substitutions?alle=1').then((r) => r.data, () => [])
      : Promise.resolve(null),
  ]);
  initColors({ settings: personal, subjects: timetable?.lessons.map((l) => l.subject) ?? [], courses });

  const v = server.values;
  const secrets = server.secrets;
  const form = createForm();
  const base = { form, v, secrets };

  // --- restart notice (network settings) ---
  const restartNotice = h('div');
  const showRestart = (keys) => {
    restartNotice.replaceChildren(keys.length === 0 ? '' : h('div', { class: 'notice' },
      h('strong', null, 'Neustart nötig: '),
      'Die Netzwerk-Einstellungen gelten erst nach einem Neustart des Servers (',
      server.desktop ? 'Symbol im Infobereich bzw. in der Menüleiste → „Neu starten“' :
        h('code', null, 'systemctl restart lumo'),
      ').'));
  };
  showRestart(server.restartRequired ?? []);

  // --- groups ---
  const updateFirst = update?.available ? updateGroup({ ...base, status: update }) : null;
  const groups = [
    updateFirst,
    portalGroup(base),
    ctx.features.has('substitutions')
      ? substitutionsGroup({ ...base, saved: personal.substitutionFilter, plan })
      : null,
    mealsGroup(base),
    ctx.features.has('lessons') || ctx.features.has('timetable') ? colorsGroup(base) : null,
    notifyGroup(base),
    syncGroup({ ...base, sync }),
    accessGroup({ ...base, desktop: server.desktop }),
    update && !update.available ? updateGroup({ ...base, status: update }) : null,
  ];

  // --- floating save entry: appears at the top while there is something to save or to say ---
  const message = messageArea();
  const status = h('span', { class: 'settings-status' },
    h('span', { class: 'long' }, 'Ungespeicherte Änderungen'), h('span', { class: 'short' }, 'Ungespeichert'));
  const discard = h('button', { type: 'button', class: 'button' }, 'Verwerfen');
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Speichern');
  const row = h('div', { class: 'settings-float-row' }, status, discard, submit);
  const float = h('div', { class: 'settings-float', role: 'status', hidden: true }, message.el, row);

  const root = h('form', { class: 'settings-page' },
    pageHeader('Einstellungen'),
    h('p', { class: 'hint' }, 'Alles auf einer Seite. Gilt für alle Geräte und wird auf dem Server gespeichert.'),
    restartNotice,
    groups,
    float);

  let saving = false;
  let leaving = false;
  let hideTimer = null;
  const refresh = () => {
    const dirty = form.dirty();
    submit.disabled = saving || !dirty;
    discard.hidden = !dirty || saving;
    row.hidden = !dirty;
    float.hidden = !dirty && message.el.childElementCount === 0;
  };
  form.onChange(refresh);
  /** Shows a message in the floating entry; [ms] > 0: hides it again (when nothing is unsaved). */
  const say = (kind, arg, ms = 0) => {
    clearTimeout(hideTimer);
    message[kind](arg);
    refresh();
    if (ms > 0) {
      hideTimer = setTimeout(() => {
        if (!form.dirty() && !saving) {
          message.clear();
          refresh();
        }
      }, ms);
    }
  };
  const edited = () => {
    clearTimeout(hideTimer);
    message.clear();
    form.touch();
  };
  root.addEventListener('input', edited);
  root.addEventListener('change', edited);
  refresh();

  discard.addEventListener('click', () => {
    leaving = true;
    location.reload();
  });

  root.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (saving || !form.dirty()) return;
    const problem = form.firstProblem();
    if (problem) {
      say('error', new ApiError(400, 'bad_request', problem));
      return;
    }
    saving = true;
    refresh();
    say('ok', 'Speichern …');
    try {
      const serverChanges = form.changed('server');
      const extra = form.extraBody();
      let result = null;
      if (Object.keys(serverChanges).length > 0 || extra.appPassword) {
        // The server checks changed logins first; on a problem nothing is stored.
        result = await api('/api/server-settings', {
          method: 'PUT',
          body: {
            ...(Object.keys(serverChanges).length > 0 ? { settings: serverChanges } : {}),
            ...extra,
          },
        });
        showRestart(result.restartRequired ?? []);
      }
      const personalChanges = form.changed('personal');
      if (Object.keys(personalChanges).length > 0) {
        const body = Object.fromEntries(Object.entries(personalChanges).map(([k, val]) => [k, JSON.parse(val)]));
        initColors({ settings: await api('/api/settings', { method: 'PUT', body }) });
      }
      form.commit();
      if (Object.keys(serverChanges).some((k) => k.startsWith('CASEDA_'))) {
        window.dispatchEvent(new Event('lumo:meals-changed')); // menu item Schulessen
      }
      say('ok', result?.accountChanged
        ? 'Gespeichert. Die Daten des neuen Kontos werden jetzt geladen.'
        : extra.appPassword
          ? 'Gespeichert. Das Passwort wurde geändert, andere Geräte sind abgemeldet.'
          : 'Gespeichert.', result?.accountChanged || extra.appPassword ? 6000 : 2500);
    } catch (err) {
      say('error', err);
    } finally {
      saving = false;
      refresh();
    }
  });

  // Unsaved changes: ask before leaving by a link or closing the page.
  guard?.abort();
  guard = new AbortController();
  const { signal } = guard;
  document.addEventListener('click', (e) => {
    if (!root.isConnected) {
      guard?.abort();
      return;
    }
    const a = e.target instanceof Element ? e.target.closest('a[href]') : null;
    if (!a || !form.dirty() || a.target || root.contains(a) && a.hash && a.pathname === location.pathname) return;
    if (!confirm('Ungespeicherte Änderungen verwerfen?')) {
      e.preventDefault();
      e.stopPropagation();
    }
  }, { capture: true, signal });
  window.addEventListener('beforeunload', (e) => {
    if (!leaving && root.isConnected && form.dirty()) e.preventDefault();
  }, { signal });

  return root;
}

