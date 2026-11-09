import { h, empty, icon, textBlock } from '../dom.js';
import { parseYmd, relativeDay, longDate } from '../format.js';
import { classesOf, matchesText, planValues } from '../substitution-filter.js';
import { pageHeader, substitutionCard } from './common.js';

export const title = 'Vertretungen';

const STORAGE_KEY = 'substitutionFilter';

/**
 * The server applies the permanent filter from the settings (own classes);
 * this page adds temporary filters: all classes, one class, types, search.
 */
export async function render(ctx) {
  const all = ctx.query.get('alle') === '1';
  const res = await ctx.getFull(`/api/substitutions${all ? '?alle=1' : ''}`);
  const days = res.data;
  const serverFilter = res.filter ?? { active: false, hidden: 0 };

  const filter = loadFilter();
  filter.query = ctx.query.get('suche') ?? '';
  filter.className = ctx.query.get('klasse') ?? '';

  const { classes, types } = planValues(days);
  const total = days.reduce((n, d) => n + d.entries.length, 0);
  const list = h('div', { 'aria-live': 'polite' });
  const counter = h('span', { class: 'muted cal-count' });

  const visible = (e) =>
    !filter.hiddenTypes.has(e.type?.trim() ?? '') &&
    (!filter.className || classesOf(e.className).includes(filter.className)) &&
    matchesText(e, filter.query);

  const setParam = (key, value) => {
    const url = new URL(location.href);
    if (value) url.searchParams.set(key, value);
    else url.searchParams.delete(key);
    history.replaceState(null, '', url.pathname + url.search);
  };

  const update = () => {
    const shown = days.map((d) => ({ ...d, entries: d.entries.filter(visible) }));
    const count = shown.reduce((n, d) => n + d.entries.length, 0);
    counter.textContent = count === total
      ? `${total} Eintr${total === 1 ? 'ag' : 'äge'}`
      : `${count} von ${total} Einträgen`;
    list.replaceChildren(...renderDays(shown, total > 0 && count === 0));
    reset.hidden = isDefault(filter);
  };

  const search = h('input', {
    type: 'search', class: 'cal-search', placeholder: 'Fach, Lehrkraft, Raum …',
    'aria-label': 'Vertretungen durchsuchen', value: filter.query,
    oninput: (e) => {
      filter.query = e.target.value;
      setParam('suche', filter.query);
      update();
    },
  });

  const classSelect = classes.length > 1 ? h('select', {
    class: 'subject-select', 'aria-label': 'Nur eine Klasse',
    onchange: (e) => {
      filter.className = e.target.value;
      setParam('klasse', filter.className);
      update();
    },
  },
  h('option', { value: '' }, all || !serverFilter.active ? 'Alle Klassen' : 'Alle meine Klassen'),
  classes.map((c) => h('option', { value: c, selected: c === filter.className }, c))) : null;

  const chips = types.map((t) => {
    const chip = h('button', {
      type: 'button', class: 'chip', 'aria-pressed': String(!filter.hiddenTypes.has(t)),
      onclick: () => {
        if (filter.hiddenTypes.has(t)) filter.hiddenTypes.delete(t); else filter.hiddenTypes.add(t);
        chip.setAttribute('aria-pressed', String(!filter.hiddenTypes.has(t)));
        saveFilter(filter);
        update();
      },
    }, t, h('span', { class: 'chip-count' },
      String(days.reduce((n, d) => n + d.entries.filter((e) => e.type?.trim() === t).length, 0))));
    return chip;
  });

  const reset = h('button', {
    type: 'button', class: 'button small', hidden: true,
    onclick: () => {
      filter.query = '';
      filter.className = '';
      filter.hiddenTypes.clear();
      search.value = '';
      if (classSelect) classSelect.value = '';
      for (const chip of chips) chip.setAttribute('aria-pressed', 'true');
      setParam('suche', '');
      setParam('klasse', '');
      saveFilter(filter);
      update();
    },
  }, 'Filter zurücksetzen');

  // Permanent filter of the server: what is hidden, and the way to all classes.
  const scope = serverFilter.active
    ? h('div', { class: 'notice filter-scope' },
      h('span', null,
        serverFilter.classes?.length ? `Klasse ${serverFilter.classes.join(', ')}` : 'Gefiltert nach den Einstellungen',
        serverFilter.hidden ? ` · ${serverFilter.hidden} weitere Einträge ausgeblendet` : ''),
      h('a', { href: '/vertretungen?alle=1', class: 'button small' }, 'Alle Klassen anzeigen'),
      h('a', { href: '/einstellungen#vertretungsplan', class: 'settings-link' }, icon('settings'), 'Filter ändern'))
    : all
      ? h('div', { class: 'notice filter-scope' },
        h('span', null, 'Alle Klassen'),
        h('a', { href: '/vertretungen', class: 'button small' }, 'Nur meine Klassen'))
      : h('p', { class: 'hint' },
        'Der ganze Vertretungsplan der Schule. ',
        h('a', { href: '/einstellungen#vertretungsplan' }, 'Eigene Klasse festlegen'),
        ' – dann zeigen Vertretungen, Heute und Benachrichtigungen nur diese.');

  const filters = total > 0 ? h('div', { class: 'cal-filters' },
    h('div', { class: 'cal-filter-row' }, search, classSelect, reset, counter),
    types.length > 1 ? h('div', { class: 'chips', role: 'group', 'aria-label': 'Arten' }, chips) : null,
  ) : null;

  update();
  return h('div', null, pageHeader('Vertretungen'), scope, filters, list);
}

function renderDays(days, filteredAway) {
  if (days.length === 0) return [empty('Aktuell keine Vertretungen.')];
  if (filteredAway && days.every((d) => d.notices.length === 0)) {
    return [empty('Keine Einträge für diese Filter.')];
  }
  return days.map((day) => {
    const date = parseYmd(day.date);
    const rel = relativeDay(date);
    return h('section', { class: 'section' },
      h('div', { class: 'section-head' },
        h('h2', null, rel === longDate(date) ? rel : `${rel} – ${longDate(date)}`)),
      day.notices.map((n) => h('div', { class: 'notice' },
        h('strong', null, n.title), textBlock(n.lines.join('<br>')))),
      day.entries.length
        ? h('div', { class: 'stack' }, day.entries.map(substitutionCard))
        : empty('Keine Vertretungen.'),
    );
  });
}

function isDefault(filter) {
  return !filter.query.trim() && !filter.className && filter.hiddenTypes.size === 0;
}

/** Remembered per browser: hidden types. Search and class are in the URL. */
function loadFilter() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}');
    return {
      query: '',
      className: '',
      hiddenTypes: new Set(Array.isArray(saved.hiddenTypes) ? saved.hiddenTypes.filter((t) => typeof t === 'string') : []),
    };
  } catch {
    return { query: '', className: '', hiddenTypes: new Set() };
  }
}

function saveFilter(filter) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ hiddenTypes: [...filter.hiddenTypes] }));
  } catch {
    // storage unavailable (private mode) — filter still works for this page
  }
}
