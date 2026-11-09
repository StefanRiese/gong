import { h, empty, icon, textBlock } from '../dom.js';
import { addDays, monthTitle, relativeDay, longDate, sameDay, startOfDay, time, ymd } from '../format.js';
import { badge, pageHeader } from './common.js';

export const title = 'Kalender';

export async function render(ctx) {
  const month = parseMonth(ctx.query.get('monat')) ?? new Date();
  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const last = new Date(month.getFullYear(), month.getMonth() + 1, 0);
  const events = await ctx.get(`/api/calendar?from=${ymd(first)}&to=${ymd(last)}`);

  const prev = new Date(first.getFullYear(), first.getMonth() - 1, 1);
  const next = new Date(first.getFullYear(), first.getMonth() + 1, 1);
  const nav = h('div', { class: 'month-nav' },
    h('a', { href: `/kalender?monat=${monthParam(prev)}`, class: 'icon-button', 'aria-label': 'Vorheriger Monat' }, icon('prev')),
    h('strong', null, monthTitle(first)),
    h('a', { href: `/kalender?monat=${monthParam(next)}`, class: 'icon-button', 'aria-label': 'Nächster Monat' }, icon('next')),
    h('a', { href: '/kalender', class: 'button small' }, 'Heute'),
  );

  const today = startOfDay(new Date());
  const filter = loadFilter();
  filter.query = ctx.query.get('suche') ?? '';
  const list = h('div', { class: 'calendar-list', 'aria-live': 'polite' });
  const counter = h('span', { class: 'muted cal-count' });

  const update = () => {
    const visible = events.filter((e) => matches(e, filter, today));
    counter.textContent = visible.length === events.length
      ? `${events.length} Termin${events.length === 1 ? '' : 'e'}`
      : `${visible.length} von ${events.length} Terminen`;
    list.replaceChildren(...renderDays(visible, first, last, today, events.length));
    reset.hidden = isDefault(filter);
  };

  const search = h('input', {
    type: 'search', class: 'cal-search', placeholder: 'Termine durchsuchen …',
    'aria-label': 'Termine durchsuchen', value: filter.query,
    oninput: (e) => {
      filter.query = e.target.value;
      const url = new URL(location.href);
      if (filter.query) url.searchParams.set('suche', filter.query);
      else url.searchParams.delete('suche');
      history.replaceState(null, '', url.pathname + url.search);
      update();
    },
  });

  const categories = [...new Set(events.map(categoryOf))]
    .sort((a, b) => (a === NO_CATEGORY) - (b === NO_CATEGORY) || a.localeCompare(b, 'de'));
  const chips = categories.map((c) => {
    const chip = h('button', {
      type: 'button', class: 'chip', 'aria-pressed': String(!filter.hidden.has(c)),
      onclick: () => {
        if (filter.hidden.has(c)) filter.hidden.delete(c); else filter.hidden.add(c);
        chip.setAttribute('aria-pressed', String(!filter.hidden.has(c)));
        saveFilter(filter);
        update();
      },
    }, c, h('span', { class: 'chip-count' }, String(events.filter((e) => categoryOf(e) === c).length)));
    return chip;
  });

  const pastToggle = h('input', {
    type: 'checkbox', id: 'cal-hide-past', checked: filter.hidePast,
    onchange: (e) => {
      filter.hidePast = e.target.checked;
      saveFilter(filter);
      update();
    },
  });

  const reset = h('button', {
    type: 'button', class: 'button small', hidden: true,
    onclick: () => {
      filter.query = '';
      filter.hidden.clear();
      filter.hidePast = false;
      search.value = '';
      pastToggle.checked = false;
      for (const chip of chips) chip.setAttribute('aria-pressed', 'true');
      history.replaceState(null, '', location.pathname + (ctx.query.get('monat') ? `?monat=${ctx.query.get('monat')}` : ''));
      saveFilter(filter);
      update();
    },
  }, 'Filter zurücksetzen');

  const filters = h('div', { class: 'cal-filters' },
    h('div', { class: 'cal-filter-row' },
      search,
      h('label', { class: 'check', for: 'cal-hide-past' }, pastToggle, 'Vergangene ausblenden'),
      reset,
      counter),
    categories.length > 1
      ? h('div', { class: 'chips', role: 'group', 'aria-label': 'Kategorien' }, chips)
      : null,
  );

  update();
  return h('div', null, pageHeader('Kalender', nav), events.length ? filters : null, list);
}

const NO_CATEGORY = 'Ohne Kategorie';
const STORAGE_KEY = 'calendarFilter';

const categoryOf = (e) => e.category ?? NO_CATEGORY;

function matches(e, filter, today) {
  if (filter.hidden.has(categoryOf(e))) return false;
  if (filter.hidePast && new Date(e.end) < today) return false;
  const q = filter.query.trim().toLocaleLowerCase('de');
  if (!q) return true;
  return [e.title, e.description, e.place, e.category]
    .some((field) => field && field.toLocaleLowerCase('de').includes(q));
}

function isDefault(filter) {
  return !filter.query.trim() && filter.hidden.size === 0 && !filter.hidePast;
}

/** Remembered per browser: hidden categories and "hide past". */
function loadFilter() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}');
    return {
      query: '',
      hidden: new Set(Array.isArray(saved.hidden) ? saved.hidden.filter((c) => typeof c === 'string') : []),
      hidePast: saved.hidePast === true,
    };
  } catch {
    return { query: '', hidden: new Set(), hidePast: false };
  }
}

function saveFilter(filter) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ hidden: [...filter.hidden], hidePast: filter.hidePast }));
  } catch {
    // storage unavailable (private mode) — filter still works for this page
  }
}

/** Groups events by day; multi-day events appear on every day within the month. */
function renderDays(events, first, last, today, total) {
  const days = new Map();
  for (const e of events) {
    const start = new Date(e.start);
    const end = new Date(e.end);
    // All-day events often end at 00:00 of the following day.
    const lastDay = e.allDay && end > start && end.getHours() === 0 && end.getMinutes() === 0
      ? addDays(startOfDay(end), -1) : startOfDay(end);
    for (let d = startOfDay(start < first ? first : start); d <= lastDay && d <= last; d = addDays(d, 1)) {
      const key = ymd(d);
      if (!days.has(key)) days.set(key, { date: d, events: [] });
      days.get(key).events.push(e);
    }
  }
  const sorted = [...days.values()].sort((a, b) => a.date - b.date);
  if (sorted.length === 0) {
    return [empty(total === 0 ? 'Keine Termine in diesem Monat.' : 'Keine Termine passen zum Filter.')];
  }
  return sorted.map(({ date, events: list }) =>
    h('section', { class: ['cal-day', sameDay(date, today) && 'today', date < today && 'past'] },
      h('h2', null, relativeDay(date) === longDate(date) ? longDate(date) : `${relativeDay(date)} – ${longDate(date)}`),
      h('ul', { class: 'cal-events' }, list.map((e) => eventItem(e, date)))));
}

function eventItem(e, day) {
  const start = new Date(e.start);
  const end = new Date(e.end);
  const when = e.allDay ? 'ganztägig'
    : sameDay(start, end) ? `${time(start)}–${time(end)}`
    : sameDay(start, day) ? `ab ${time(start)}`
    : sameDay(end, day) ? `bis ${time(end)}`
    : 'ganztägig';
  const description = textBlock(e.description);
  return h('li', { class: 'cal-event' },
    h('span', { class: 'cal-time' }, when),
    h('div', null,
      h('strong', null, e.title),
      e.category ? badge(e.category, 'info') : null,
      e.place ? h('div', { class: 'muted' }, e.place) : null,
      description ? h('details', null, h('summary', null, 'Details'), description) : null));
}

function parseMonth(value) {
  const m = /^(\d{4})-(\d{2})$/.exec(value ?? '');
  if (!m) return null;
  const month = Number(m[2]);
  return month >= 1 && month <= 12 ? new Date(Number(m[1]), month - 1, 1) : null;
}

function monthParam(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
}
