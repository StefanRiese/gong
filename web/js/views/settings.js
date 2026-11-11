// Einstellungen: everything on one page, in flat groups, with one save button.
// Personal settings (substitution filter, subject colors) and server settings
// (logins, sync, notifications, network, update) are saved together; only
// what changed is sent.

import { api, ApiError, errorMessage } from '../api.js';
import { h, errorBox } from '../dom.js';
import { initColors } from '../colors.js';
import { accounts, current, loadAccounts } from '../accounts.js';
import { pageHeader } from './common.js';
import { accountGroup, addChildGroup } from './accounts.js';
import { messageArea } from './forms.js';
import { createForm } from './settings-form.js';
import {
  accessGroup, colorsGroup, mealsGroup, notifyGroup, restartGroup, restartServer, substitutionsGroup,
  syncGroup, updateGroup,
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
    // Portal problems of the shown account must not lock the settings page
    // (the account may be the very thing to fix or remove here).
    ctx.features.has('timetable') ? ctx.get('/api/timetable').catch(() => null) : Promise.resolve(null),
    ctx.features.has('lessons') ? ctx.get('/api/courses').catch(() => []) : Promise.resolve([]),
    // The full plan (all classes) to choose the own class from.
    ctx.features.has('substitutions')
      ? api('/api/substitutions?alle=1').then((r) => r.data, () => [])
      : Promise.resolve(null),
  ]);
  initColors({ settings: personal, subjects: timetable?.lessons?.map((l) => l.subject) ?? [], courses });

  const v = server.values;
  const secrets = server.secrets;
  const form = createForm();
  const base = { form, v, secrets };

  // --- restart notice (network settings) ---
  const restartNotice = h('div');
  const showRestart = (keys) => {
    if (keys.length === 0) {
      restartNotice.replaceChildren();
      return;
    }
    const restartMsg = messageArea();
    const restartButton = h('button', { type: 'button', class: 'button small' }, 'Jetzt neu starten');
    restartButton.addEventListener('click', () => restartServer({ form, button: restartButton, msg: restartMsg }));
    restartNotice.replaceChildren(h('div', { class: 'notice' },
      h('strong', null, 'Neustart nötig: '),
      'Die Netzwerk-Einstellungen gelten erst nach einem Neustart des Servers',
      server.canRestart ? '.' : [' (',
        server.desktop ? 'Symbol im Infobereich bzw. in der Menüleiste → „Neu starten“' :
          h('code', null, 'systemctl restart lumo'),
        ').'],
      server.canRestart ? h('div', { class: 'button-row' }, restartButton) : null,
      server.canRestart ? restartMsg.el : null));
  };
  showRestart(server.restartRequired ?? []);

  // --- groups ---
  // Tabs: Allgemein (server, notifications, access, update), one tab per child, and
  // "+ Kind". Every child has the same form (login, Caseda, WebUntis); only the shown
  // child's tab has content, the others load the child anew when clicked.
  const shown = accounts.find((a) => a.id === current) ?? accounts[0];
  const accountPart = accountGroup({ form, account: shown });
  const panelOf = (id, groups) => h('div', { class: 'tab-panel', id: `panel-${id}`, role: 'tabpanel', hidden: true }, groups);
  const panels = {
    allgemein: panelOf('allgemein', [
      update?.available ? updateGroup({ ...base, status: update }) : null,
      mealsGroup(base),
      notifyGroup(base),
      syncGroup({ ...base, sync }),
      accessGroup({ ...base, desktop: server.desktop }),
      restartGroup({ form, server }),
      update && !update.available ? updateGroup({ ...base, status: update }) : null,
    ]),
    konto: panelOf('konto', [
      accountPart.el,
      ctx.features.has('substitutions')
        ? substitutionsGroup({ ...base, saved: personal.substitutionFilter, plan })
        : null,
      ctx.features.has('lessons') || ctx.features.has('timetable') ? colorsGroup(base) : null,
    ]),
    neu: panelOf('neu', [addChildGroup({ defaultSchool: shown?.schoolId })]),
  };

  const tabList = [
    { key: 'allgemein', label: 'Allgemein' },
    ...accounts.map((a) => ({ key: a.id === current ? 'konto' : `konto:${a.id}`, label: a.name, account: a.id })),
    { key: 'neu', label: '+ Kind' },
  ];
  const tabButtons = new Map();
  const setUrl = (key) => {
    const url = new URL(location.href);
    if (key === 'allgemein' || key === 'neu') url.searchParams.set('tab', key); else url.searchParams.delete('tab');
    history.replaceState(null, '', `${url.pathname}${url.search}`);
  };
  const show = (key, { remember = true } = {}) => {
    for (const [k, panel] of Object.entries(panels)) panel.hidden = k !== key;
    for (const [k, button] of tabButtons) {
      button.setAttribute('aria-selected', String(k === key));
      button.tabIndex = k === key ? 0 : -1;
    }
    if (remember) setUrl(key);
  };
  const tabs = h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'Einstellungen' },
    tabList.map((t) => {
      const button = h('button', {
        type: 'button', class: 'tab', role: 'tab',
        'aria-controls': t.key === 'konto' || t.account ? 'panel-konto' : `panel-${t.key}`,
      }, t.label);
      tabButtons.set(t.key, button);
      button.addEventListener('click', () => {
        if (!t.account || t.key === 'konto') return show(t.key === 'konto' ? 'konto' : t.key);
        // Another child: its page is loaded anew (own filter, colors, login).
        if (form.dirty() && !confirm('Ungespeicherte Änderungen verwerfen?')) return;
        setUrl('konto');
        window.dispatchEvent(new CustomEvent('lumo:switch-account', { detail: t.account }));
      });
      return button;
    }));
  tabs.addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    const buttons = [...tabs.children];
    const i = buttons.indexOf(document.activeElement);
    if (i < 0) return;
    e.preventDefault();
    buttons[(i + (e.key === 'ArrowRight' ? 1 : buttons.length - 1)) % buttons.length].focus();
  });
  // Links like /einstellungen#vertretungsplan open the tab that has the section.
  const hashId = location.hash.slice(1);
  const byHash = hashId
    ? Object.entries(panels).find(([, panel]) => [...panel.querySelectorAll('[id]')].some((el) => el.id === hashId))?.[0]
    : null;
  const param = ctx.query.get('tab');
  show(byHash ?? (param === 'allgemein' || param === 'neu' ? param : 'konto'), { remember: false });

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
    tabs,
    restartNotice,
    panels.allgemein, panels.konto, panels.neu,
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
      // The shown child's logins: the server tries changed logins first.
      let accountResult = null;
      if (Object.keys(form.changed('account')).length > 0) {
        const before = { username: shown.username.toLowerCase(), schoolId: shown.schoolId };
        const updated = await api(`/api/accounts/${encodeURIComponent(shown.id)}`, {
          method: 'PUT', body: accountPart.body(),
        });
        Object.assign(shown, updated);
        accountResult = {
          otherPerson: updated.username.toLowerCase() !== before.username || updated.schoolId !== before.schoolId,
        };
        tabButtons.get('konto').textContent = shown.name;
      }
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
      if (accountResult) {
        await loadAccounts();
        window.dispatchEvent(new CustomEvent('lumo:accounts-changed')); // name in the top bar
        window.dispatchEvent(new Event('lumo:meals-changed')); // menu item Schulessen
      }
      say('ok', accountResult?.otherPerson
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

