import { h, empty } from '../dom.js';
import { isoWeekday, minutesOf } from '../format.js';
import { badge, lessonsOn, pageHeader } from './common.js';
import { initColors, subjectStyle } from '../colors.js';

export const title = 'Stundenplan';

const DAYS = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag'];
const SHORT_DAYS = ['Mo', 'Di', 'Mi', 'Do', 'Fr'];

export async function render(ctx) {
  const res = await ctx.getFull('/api/timetable');
  const tt = res.data;
  initColors({ subjects: tt.lessons.map((l) => l.subject) });
  const hasWeeks = tt.lessons.some((l) => l.week);
  const requested = ctx.query.get('woche');
  const week = !hasWeeks ? null
    : requested === 'alle' ? null
    : requested === 'A' || requested === 'B' ? requested
    : tt.currentWeek;

  const toggle = hasWeeks
    ? h('div', { class: 'segmented', role: 'group', 'aria-label': 'Woche' },
      [['A', 'Woche A'], ['B', 'Woche B'], ['alle', 'Alle']].map(([value, label]) => {
        const active = (value === 'alle' && week == null) || value === week;
        return h('a', {
          href: `/stundenplan?woche=${value}`,
          class: ['segment', active && 'active'],
          'aria-current': active ? 'true' : null,
        }, label, value === tt.currentWeek ? ' (aktuell)' : '');
      }))
    : null;

  if (tt.lessons.length === 0) {
    return h('div', null, pageHeader('Stundenplan'), empty('Kein Stundenplan vorhanden.'));
  }

  const today = isoWeekday(new Date());
  return h('div', null,
    pageHeader('Stundenplan', tt.currentWeek ? badge(`Aktuell Woche ${tt.currentWeek}`, 'info') : null, toggle),
    // Week table on all screens; compact on phones (see .tt-grid in app.css).
    differences(res.differences),
    h('div', { class: 'tt-scroll' }, grid(tt, week, today)),
  );
}

/** Warning when WebUntis (second source) shows a different timetable. */
function differences(list) {
  if (!list?.length) return null;
  return h('div', { class: 'notice warn', role: 'alert' },
    h('strong', null, 'Achtung: Schulportal und WebUntis zeigen einen unterschiedlichen Stundenplan'),
    h('ul', null, list.map((d) => h('li', null, d.text))),
    h('small', null, 'Prüfe, welcher Plan stimmt – im Schulportal kann der Stundenplan veraltet sein.'));
}

function slotsOf(tt) {
  if (tt.slots.length) return tt.slots;
  // Fallback when the portal hides the time column: derive rows from lessons.
  const starts = [...new Set(tt.lessons.map((l) => l.start))].sort((a, b) => minutesOf(a) - minutesOf(b));
  return starts.map((start, i) => ({
    period: i + 1, label: `${i + 1}.`, start,
    end: tt.lessons.find((l) => l.start === start && l.duration === 1)?.end ?? '',
  }));
}

/** Week table: days as columns, periods as rows. */
function grid(tt, week, today) {
  const slots = slotsOf(tt);
  const cells = [h('div', { class: 'tt-corner' })];

  DAYS.forEach((day, i) => cells.push(
    h('div', {
      class: ['tt-day', i + 1 === today && 'today'],
      style: { 'grid-column': i + 2, 'grid-row': 1 },
      title: day,
    }, h('span', { class: 'long' }, day), h('span', { class: 'short', 'aria-hidden': 'true' }, SHORT_DAYS[i]))));

  slots.forEach((s, i) => cells.push(
    h('div', {
      class: ['tt-slot', s.period == null && 'break'],
      style: { 'grid-column': 1, 'grid-row': i + 2 },
    },
    s.period != null ? h('strong', null, `${s.period}.`) : h('span', { class: 'break-label' }, s.label || 'Pause'),
    h('small', null, s.start, h('span', { class: 'tt-end' }, `–${s.end}`)))));

  for (let d = 1; d <= 5; d++) {
    // Group lessons that start in the same slot (e.g. A/B week shown together).
    const groups = new Map();
    for (const l of lessonsOn(tt, d, week)) {
      let start = slots.findIndex((s) => s.start === l.start);
      if (start < 0) start = slots.findIndex((s) => minutesOf(s.end) > minutesOf(l.start));
      if (start < 0) continue;
      let end = slots.findIndex((s) => s.end === l.end);
      if (end < start) end = Math.min(slots.length - 1, start + Math.max(1, l.duration) - 1);
      const g = groups.get(start) ?? { start, end, lessons: [] };
      g.end = Math.max(g.end, end);
      g.lessons.push(l);
      groups.set(start, g);
    }
    for (const g of groups.values()) {
      cells.push(h('div', {
        class: ['tt-cell', d === today && 'today'],
        style: { 'grid-column': d + 1, 'grid-row': `${g.start + 2} / ${g.end + 3}` },
      }, g.lessons.map(lessonBox)));
    }
  }

  // Lesson rows and (lower) break rows; heights come from CSS variables.
  const rows = slots.map((s) => (s.period == null
    ? 'minmax(var(--tt-break-row), auto)'
    : 'minmax(var(--tt-row), auto)'));
  return h('div', {
    class: 'tt-grid',
    style: { 'grid-template-rows': `auto ${rows.join(' ')}` },
  }, cells);
}

function lessonBox(l) {
  // Abbreviations (M, D, Geo, PoWi) get a larger font on phones than long names.
  const short = (l.subject ?? '').length <= 5;
  return h('div', {
    class: ['tt-lesson', short && 'short'], style: subjectStyle(l.subject),
    title: [l.subject, l.room, l.teacher, l.week && `Woche ${l.week}`, `${l.start}–${l.end}`].filter(Boolean).join(' · '),
  },
  h('strong', null, l.subject ?? '—', l.week ? badge(l.week, 'info') : null),
  h('span', null,
    l.room ? h('span', { class: 'tt-room' }, l.room) : null,
    l.room && l.teacher ? h('span', { class: 'tt-teacher' }, ' · ') : null,
    l.teacher ? h('span', { class: 'tt-teacher' }, l.teacher) : null));
}
