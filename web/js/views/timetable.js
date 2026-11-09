import { h, empty } from '../dom.js';
import { isoWeekday, minutesOf } from '../format.js';
import { badge, lessonsOn, pageHeader } from './common.js';
import { assignAutoColors, subjectStyle } from '../colors.js';

export const title = 'Stundenplan';

const DAYS = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag'];

export async function render(ctx) {
  const tt = await ctx.get('/api/timetable');
  assignAutoColors(tt.lessons.map((l) => l.subject));
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
    grid(tt, week, today),
    dayList(tt, week, today),
  );
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

/** Week grid (wide screens). */
function grid(tt, week, today) {
  const slots = slotsOf(tt);
  const cells = [h('div', { class: 'tt-corner' })];

  DAYS.forEach((day, i) => cells.push(
    h('div', {
      class: ['tt-day', i + 1 === today && 'today'],
      style: { 'grid-column': i + 2, 'grid-row': 1 },
    }, day)));

  slots.forEach((s, i) => cells.push(
    h('div', {
      class: ['tt-slot', s.period == null && 'break'],
      style: { 'grid-column': 1, 'grid-row': i + 2 },
    },
    s.period != null ? h('strong', null, `${s.period}.`) : h('span', null, s.label || 'Pause'),
    h('small', null, `${s.start}–${s.end}`))));

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

  return h('div', {
    class: 'tt-grid',
    style: { 'grid-template-rows': `auto repeat(${slots.length}, minmax(3.2rem, auto))` },
  }, cells);
}

function lessonBox(l) {
  return h('div', { class: 'tt-lesson', style: subjectStyle(l.subject) },
    h('strong', null, l.subject ?? '—', l.week ? badge(l.week, 'info') : null),
    h('span', null, [l.room, l.teacher].filter(Boolean).join(' · ')));
}

/** Lessons per day (narrow screens). */
function dayList(tt, week, today) {
  const order = [1, 2, 3, 4, 5];
  if (today <= 5) order.push(...order.splice(0, today - 1));
  return h('div', { class: 'tt-days' }, order.map((d) => {
    const lessons = lessonsOn(tt, d, week);
    return h('section', { class: ['section', d === today && 'today'] },
      h('h2', null, DAYS[d - 1], d === today ? badge('heute', 'info') : null),
      lessons.length === 0 ? empty('Kein Unterricht.') :
        h('ol', { class: 'lesson-list' }, lessons.map((l) =>
          h('li', { class: 'lesson', style: subjectStyle(l.subject) },
            h('div', { class: 'lesson-time' }, h('span', null, l.start), h('span', null, l.end)),
            h('div', { class: 'lesson-body' },
              h('div', { class: 'lesson-title' }, h('strong', null, l.subject ?? '—'),
                l.week ? badge(`Woche ${l.week}`, 'info') : null),
              h('div', { class: 'muted' }, [l.room, l.teacher].filter(Boolean).join(' · ')))))));
  }));
}
