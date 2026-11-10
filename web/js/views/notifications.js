import { api, errorMessage } from '../api.js';
import { h, empty, errorBox, icon } from '../dom.js';
import { age } from '../format.js';
import { badge, pageHeader } from './common.js';

export const title = 'Benachrichtigungen';

const KIND_LABELS = {
  substitutions: 'Vertretungen',
  homework: 'Hausaufgaben',
  grades: 'Noten',
};

export async function render() {
  const info = await api('/api/notifications');
  const back = h('a', { href: '/einstellungen', class: 'back-link' }, icon('back'), 'Einstellungen');
  if (!info.enabled) {
    return h('div', null,
      back,
      pageHeader('Benachrichtigungen', badge('aus')),
      empty('Push-Benachrichtigungen sind nicht eingerichtet.'),
      h('p', null, h('a', { href: '/einstellungen#benachrichtigungen', class: 'settings-link' },
        icon('settings'), 'In den Einstellungen einrichten')),
      h('p', { class: 'hint' },
        'Dort ein ntfy-Thema angeben, dann die ntfy-App installieren und dasselbe Thema abonnieren.'),
    );
  }

  const message = h('div', { 'aria-live': 'polite' });
  const show = (node) => message.replaceChildren(node);

  const testButton = h('button', {
    class: 'button', type: 'button',
    onclick: async () => {
      testButton.disabled = true;
      try {
        await api('/api/notifications/test', { method: 'POST' });
        show(h('div', { class: 'notice' }, 'Testnachricht gesendet – sie sollte gleich in der ntfy-App erscheinen.'));
      } catch (err) {
        show(errorBox(`Senden fehlgeschlagen: ${err.details?.message ?? errorMessage(err)}`));
      } finally {
        testButton.disabled = false;
      }
    },
  }, 'Testnachricht senden');

  const checkButton = h('button', {
    class: 'button', type: 'button',
    onclick: async () => {
      checkButton.disabled = true;
      checkButton.textContent = 'Prüfe …';
      try {
        const { sent } = await api('/api/notifications/check', { method: 'POST' });
        show(h('div', { class: 'notice' },
          sent === 0 ? 'Geprüft – nichts Neues.' : `Geprüft – ${sent} Benachrichtigung${sent === 1 ? '' : 'en'} gesendet.`));
        table.replaceWith(table = statusTable((await api('/api/notifications')).status));
      } catch (err) {
        show(errorBox(errorMessage(err)));
      } finally {
        checkButton.disabled = false;
        checkButton.textContent = 'Jetzt prüfen';
      }
    },
  }, 'Jetzt prüfen');

  let table = statusTable(info.status);
  const [from, to] = info.activeHours;

  return h('div', null,
    back,
    pageHeader('Benachrichtigungen', badge('aktiv', 'ok')),
    h('section', { class: 'section' },
      h('dl', { class: 'facts' },
        h('dt', null, 'Ziel'), h('dd', null, `ntfy (${info.target})`),
        h('dt', null, 'Themen'), h('dd', null, info.kinds.map((k) => KIND_LABELS[k] ?? k).join(', ')),
        h('dt', null, 'Prüfung'), h('dd', null,
          `alle ${info.intervalMinutes} Min. (Noten alle ${info.gradesIntervalMinutes} Min.), ${from}–${to} Uhr`),
        h('dt', null, 'Noten'), h('dd', null,
          info.includeGradeValues ? 'mit Notenwert' : 'ohne Notenwert (nur in der App sichtbar)')),
    ),
    h('section', { class: 'section' }, h('h2', null, 'Status'), table),
    h('div', { class: 'button-row' }, testButton, checkButton),
    message,
  );
}

function statusTable(status) {
  return h('table', { class: 'table' },
    h('thead', null, h('tr', null,
      h('th', null, 'Bereich'), h('th', null, 'Zuletzt geprüft'),
      h('th', null, 'Nächste Prüfung'), h('th', { class: 'num' }, 'Gesendet'))),
    h('tbody', null, Object.entries(status).map(([kind, s]) => h('tr', null,
      h('td', null, KIND_LABELS[kind] ?? kind,
        !s.baseline ? h('div', { class: 'muted' }, 'noch nicht erfasst') : null,
        s.lastError ? h('div', { class: 'error-text' }, s.lastError) : null),
      h('td', null, s.lastRun ? age(s.lastRun) : '—'),
      h('td', null, nextLabel(s.nextRun)),
      h('td', { class: 'num' }, String(s.sent))))));
}

function nextLabel(iso) {
  const minutes = Math.round((new Date(iso) - new Date()) / 60000);
  if (minutes <= 0) return 'bald';
  if (minutes < 60) return `in ${minutes} Min.`;
  return `in ${Math.round(minutes / 60)} Std.`;
}
