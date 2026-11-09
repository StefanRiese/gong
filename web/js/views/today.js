import { append, h, empty, textBlock } from '../dom.js';
import { navigate } from '../router.js';
import {
  addDays, isoWeekday, longDate, minutesOf, parseYmd, relativeDay, shortDate, startOfDay, time, ymd,
} from '../format.js';
import {
  badge, homeworkDoneToast, homeworkToggle, isCancellation, lazySection, lessonsOn, load, pageHeader,
  periodRange, removeAnimated, section,
  substitutionCard, weekFor,
} from './common.js';
import { assignAutoColors, subjectStyle } from '../colors.js';

export const title = 'Heute';

export async function render(ctx) {
  const now = new Date();
  // Homework is loaded lazily (see below): the full list needs one portal
  // request per course and should not delay the rest of the page.
  const [tt, subs, cal] = await Promise.all([
    load(ctx, 'timetable', '/api/timetable'),
    load(ctx, 'substitutions', '/api/substitutions'),
    load(ctx, 'calendar', '/api/calendar'),
  ]);

  if (tt?.ok) assignAutoColors(tt.value.lessons.map((l) => l.subject));
  const target = targetDay(now, tt?.ok ? tt.value : null);
  const week = tt?.ok ? weekFor(target, tt.value.currentWeek, now) : null;
  const lessons = tt?.ok ? lessonsOn(tt.value, isoWeekday(target), week) : [];
  const subDay = subs?.ok ? subs.value.find((d) => d.date === ymd(target)) : null;

  const heading = relativeDay(target, now);
  const subtitle = heading === longDate(target) ? null : longDate(target);

  return h('div', { class: 'today' },
    pageHeader(heading,
      subtitle ? h('p', { class: 'subtitle' }, subtitle) : null,
      week ? badge(`Woche ${week}`, 'info') : null),
    h('div', { class: 'today-grid' },
      h('div', null,
        section('Stundenplan', tt, () => lessonList(lessons, subDay)),
        subs ? substitutionsSection(subs, subDay, target) : null,
      ),
      h('div', null,
        lazySection('Hausaufgaben',
          ctx.features.has('lessons') ? () => ctx.get('/api/homework?alle=1') : null,
          (items) => homeworkList(items, now)),
        section('Nächste Termine', cal, (events) => eventList(events, now)),
      ),
    ),
  );
}

/** Today, or the next school day once today's lessons are over. */
function targetDay(now, timetable) {
  let day = startOfDay(now);
  const isSchoolDay = (d) => isoWeekday(d) <= 5;
  if (isSchoolDay(day) && timetable) {
    const lessons = lessonsOn(timetable, isoWeekday(day), weekFor(day, timetable.currentWeek, now));
    const last = lessons.at(-1);
    const nowMinutes = now.getHours() * 60 + now.getMinutes();
    if (last && minutesOf(last.end) > nowMinutes) return day;
    if (!last && nowMinutes < 14 * 60) return day;
  } else if (isSchoolDay(day)) {
    return day;
  }
  do day = addDays(day, 1); while (!isSchoolDay(day));
  return day;
}

function lessonList(lessons, subDay) {
  if (lessons.length === 0) return empty('Kein Unterricht.');
  const entries = subDay?.entries ?? [];
  return h('ol', { class: 'lesson-list' }, lessons.map((l) => {
    const from = l.period ?? 0;
    const to = from + Math.max(1, l.duration) - 1;
    const matching = entries.filter((s) => {
      const r = periodRange(s.period);
      return r && l.period != null && r[0] <= to && r[1] >= from;
    });
    const cancelled = matching.some(isCancellation);
    return h('li', {
      class: ['lesson', matching.length && 'changed', cancelled && 'cancelled'],
      style: subjectStyle(l.subject),
    },
      h('div', { class: 'lesson-time' },
        h('span', null, l.start), h('span', null, l.end)),
      h('div', { class: 'lesson-body' },
        h('div', { class: 'lesson-title' },
          h('strong', null, l.subject ?? '—'),
          l.period != null
            ? h('span', { class: 'muted' }, l.duration > 1 ? `${from}.–${to}. Std.` : `${from}. Std.`)
            : null),
        h('div', { class: 'muted' }, [l.room, l.teacher].filter(Boolean).join(' · ')),
        matching.map((s) => h('div', { class: 'lesson-change' },
          badge(s.type ?? 'Änderung', isCancellation(s) ? 'danger' : 'warn'),
          [s.substitute && `Vertretung: ${s.substitute}`,
            s.room && s.room !== l.room && `Raum ${s.room}`,
            s.note].filter(Boolean).join(' · '))),
      ),
    );
  }));
}

function substitutionsSection(subs, subDay, target) {
  return section(`Vertretungen ${shortDate(target)}`, subs, () => {
    const parts = [];
    for (const n of subDay?.notices ?? []) {
      parts.push(h('div', { class: 'notice' }, h('strong', null, n.title),
        textBlock(n.lines.join('<br>'))));
    }
    if (subDay?.entries.length) {
      parts.push(h('div', { class: 'stack' }, subDay.entries.map(substitutionCard)));
    } else {
      parts.push(empty('Keine Vertretungen.'));
    }
    const others = subs.value.filter((d) => d.date !== ymd(target) && d.entries.length);
    if (others.length) {
      const count = others.reduce((n, d) => n + d.entries.length, 0);
      parts.push(h('p', null, h('a', { href: '/vertretungen' },
        `${count} weitere Vertretung${count === 1 ? '' : 'en'} an anderen Tagen →`)));
    }
    return parts;
  });
}

/** Open homework of the last [RECENT_DAYS] days; older ones are linked. */
const RECENT_DAYS = 14;

function homeworkList(items, now) {
  const cutoff = addDays(startOfDay(now), -RECENT_DAYS);
  const open = items.filter((i) => !i.done);
  const recent = open
    .filter((i) => !i.date || parseYmd(i.date) >= cutoff)
    .sort((a, b) => (b.date ?? '').localeCompare(a.date ?? ''));
  const older = open.length - recent.length;
  const moreLink = older > 0
    ? h('p', null, h('a', { href: '/hausaufgaben' },
      `${older} ältere offene Hausaufgabe${older === 1 ? '' : 'n'} →`))
    : null;
  const emptyText = 'Keine offenen Hausaufgaben der letzten zwei Wochen.';
  if (recent.length === 0) return [empty(emptyText), moreLink];
  const stack = h('div', { class: 'stack' });
  // Only open homework is listed here: hide items once they are marked done.
  const hide = async (item, card) => {
    await removeAnimated(card);
    if (!stack.querySelector('article.card')) stack.replaceWith(empty(emptyText));
    homeworkDoneToast(item, () => navigate(location.pathname + location.search, { replace: true }));
  };
  return [append(stack, recent.map((i) => {
    const card = h('article', { class: 'card' });
    return append(card, [
      h('div', { class: 'card-title' },
        h('a', { href: `/kurse/${encodeURIComponent(i.courseId)}` }, i.courseName),
        i.date ? h('span', { class: 'muted' }, shortDate(parseYmd(i.date))) : null),
      textBlock(i.description),
      h('div', { class: 'card-actions' },
        homeworkToggle({
          courseId: i.courseId, entryId: i.entryId, done: i.done, card,
          onSaved: (value) => { if (value) hide(i, card); },
        })),
    ]);
  })), moreLink];
}

function eventList(events, now) {
  const end = addDays(startOfDay(now), 8);
  const upcoming = events.filter((e) => new Date(e.end) >= startOfDay(now) && new Date(e.start) < end);
  if (upcoming.length === 0) return empty('Keine Termine in den nächsten 7 Tagen.');
  return h('ul', { class: 'event-list' }, upcoming.slice(0, 8).map((e) => {
    const start = new Date(e.start);
    return h('li', null,
      h('span', { class: 'event-date' }, shortDate(start)),
      h('span', null, h('strong', null, e.title),
        h('span', { class: 'muted' }, e.allDay ? ' ganztägig' : ` ${time(start)}`,
          e.place ? ` · ${e.place}` : '')));
  }));
}
