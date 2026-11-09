// Form building blocks for the setup page and the server settings.

import { api, ApiError, errorMessage } from '../api.js';
import { h, errorBox } from '../dom.js';

let fieldCounter = 0;

/**
 * Label + input (+ hint) as one block.
 * @param {string} label
 * @param {HTMLElement} input
 * @param {string} [hint]
 */
export function field(label, input, hint) {
  if (!input.id) input.id = `field-${++fieldCounter}`;
  const hintEl = hint ? h('div', { class: 'field-hint', id: `${input.id}-hint` }, hint) : null;
  if (hintEl) input.setAttribute('aria-describedby', hintEl.id);
  return h('div', { class: 'field' }, h('label', { for: input.id }, label), input, hintEl);
}

/** Text-like input. */
export function input(props = {}) {
  return h('input', { class: 'input', type: 'text', autocomplete: 'off', ...props });
}

/** Checkbox with label. */
export function checkbox(label, checked, props = {}) {
  const box = h('input', { type: 'checkbox', checked: Boolean(checked), ...props });
  return { box, el: h('label', { class: 'check' }, box, label) };
}

/** Area for success and error messages of a form. */
export function messageArea() {
  const el = h('div', { class: 'form-message', 'aria-live': 'polite' });
  return {
    el,
    clear: () => el.replaceChildren(),
    ok: (text) => el.replaceChildren(h('div', { class: 'ok-box' }, text)),
    error: (err) => el.replaceChildren(errorView(err)),
  };
}

/** Error box; invalid settings list their problems (in German where known). */
export function errorView(err) {
  const problems = err instanceof ApiError ? err.details?.problems : null;
  if (!Array.isArray(problems) || problems.length === 0) return errorBox(errorMessage(err));
  return h('div', { class: 'error', role: 'alert' },
    h('div', null, 'Bitte die Angaben prüfen:'),
    h('ul', null, problems.map((p) => h('li', null, problemText(p)))));
}

const PROBLEMS = [
  [/SPH_USERNAME and SPH_PASSWORD/, 'Benutzername und Passwort für das Schulportal fehlen.'],
  [/APP_PASSWORD must have/, 'Das Passwort muss mindestens 8 Zeichen haben.'],
  [/APP_PASSWORD or APP_PASSWORD_HASH/, 'Ein Passwort für die Web-Oberfläche fehlt.'],
  [/POLL_INTERVAL_MINUTES/, 'Vertretungen und Hausaufgaben: höchstens alle 5 Minuten.'],
  [/GRADES_INTERVAL_MINUTES/, 'Noten und Kursseiten: höchstens alle 30 Minuten.'],
  [/ACTIVE_HOURS/, 'Uhrzeiten bitte als Stunden von 0 bis 24 angeben (z. B. 6 bis 22).'],
  [/NTFY_URL/, 'Die Adresse des ntfy-Servers muss mit http:// oder https:// beginnen.'],
  [/NTFY_TOPIC/, 'Das Thema darf nur Buchstaben, Ziffern, „-“ und „_“ enthalten (höchstens 64 Zeichen).'],
  [/APP_URL/, 'Die Adresse der Web-Oberfläche muss mit http:// oder https:// beginnen.'],
  [/PORT/, 'Der Port muss zwischen 1 und 65535 liegen.'],
  [/SESSION_TTL_DAYS/, 'Die Anmeldedauer muss mindestens 1 Tag sein.'],
  [/NOTIFY: unknown/, 'Unbekannte Art von Benachrichtigung.'],
];

function problemText(p) {
  for (const [pattern, text] of PROBLEMS) if (pattern.test(p)) return text;
  return p;
}

/**
 * School search: type a name, town or school number, pick from the list.
 * @param {{value?: number, headers?: Record<string, string>, onChange?: (id: number) => void}} options
 */
export function schoolPicker({ value, headers = {}, onChange = () => {} }) {
  let selected = value ?? null;
  const search = input({
    type: 'search', placeholder: 'Name, Ort oder Schulnummer', 'aria-label': 'Schule suchen',
    'aria-controls': `schools-${++fieldCounter}`,
  });
  const results = h('ul', { class: 'pick-list', id: search.getAttribute('aria-controls') });
  const current = h('div', { class: 'picked' });
  const status = h('div', { class: 'field-hint', 'aria-live': 'polite' });

  const showSelected = (school) => {
    current.replaceChildren(selected == null
      ? h('span', { class: 'muted' }, 'Noch keine Schule gewählt')
      : h('span', null, h('strong', null, school?.name ?? `Schule ${selected}`),
        school ? ` · ${school.city} · ` : ' · ', `Nr. ${selected}`));
  };

  let timer = null;
  let seq = 0;
  const run = async () => {
    const q = search.value.trim();
    if (q.length < 2) {
      results.replaceChildren();
      status.textContent = '';
      return;
    }
    const mine = ++seq;
    status.textContent = 'Suche …';
    try {
      const list = await api(`/api/schools?q=${encodeURIComponent(q)}`, { headers });
      if (mine !== seq) return;
      status.textContent = list.length === 0 ? 'Keine Schule gefunden.' : '';
      results.replaceChildren(...list.map((s) => h('li', null, h('button', {
        type: 'button', class: 'pick-item',
        onclick: () => {
          selected = s.id;
          showSelected(s);
          results.replaceChildren();
          search.value = '';
          onChange(s.id);
        },
      }, h('strong', null, s.name), h('span', { class: 'muted' }, ` ${s.city} · Nr. ${s.id}`)))));
    } catch (err) {
      if (mine !== seq) return;
      results.replaceChildren();
      // Fallback: the school number can always be entered directly.
      if (/^\d{3,6}$/.test(q)) {
        status.textContent = '';
        results.replaceChildren(h('li', null, h('button', {
          type: 'button', class: 'pick-item',
          onclick: () => {
            selected = Number(q);
            showSelected(null);
            results.replaceChildren();
            search.value = '';
            onChange(selected);
          },
        }, `Schulnummer ${q} verwenden`)));
      } else {
        status.textContent = `${errorMessage(err)} Die Schulnummer kann auch direkt eingegeben werden.`;
      }
    }
  };
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(run, 300);
  });

  showSelected(null);
  // Show the name of a preselected school.
  if (selected != null) {
    api(`/api/schools?q=${selected}`, { headers })
      .then((list) => showSelected(list.find((s) => s.id === selected) ?? null), () => {});
  }

  return {
    el: h('div', { class: 'school-picker' }, current, search, status, results),
    get value() {
      return selected;
    },
  };
}

/** Random ntfy topic that is hard to guess. */
export function randomTopic() {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return `sph-${Array.from(bytes, (b) => b.toString(36).padStart(2, '0')).join('').slice(0, 20)}`;
}
