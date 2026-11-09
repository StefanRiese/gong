import { h, empty, icon, textBlock } from '../dom.js';
import { parseYmd, shortDate } from '../format.js';
import { badge, pageHeader } from './common.js';
import { examList, gradeTable } from './grades.js';

export const title = 'Kurs';

export async function render(ctx) {
  const d = await ctx.get(`/api/courses/${encodeURIComponent(ctx.params.id)}`);
  document.title = `${d.course.name} – Schulportal`;
  const history = [...d.history].sort((a, b) => (b.date ?? '').localeCompare(a.date ?? ''));
  const attendance = Object.entries(d.attendance);

  return h('div', null,
    h('a', { href: '/noten', class: 'back-link' }, icon('back'), 'Noten'),
    pageHeader(d.course.name,
      d.course.teachers.length ? h('p', { class: 'subtitle' }, d.course.teachers.join(', ')) : null),
    h('div', { class: 'course-grid' },
      h('div', null,
        h('section', { class: 'section' },
          h('h2', null, 'Noten'),
          d.grades.length ? gradeTable(d.grades) : empty('Keine Noten eingetragen.'),
          d.exams.length ? examList(d.exams) : null),
        attendance.length
          ? h('section', { class: 'section' },
            h('h2', null, 'Anwesenheit'),
            h('dl', { class: 'facts' }, attendance.map(([k, v]) => [h('dt', null, k), h('dd', null, v)])))
          : null,
      ),
      h('section', { class: 'section' },
        h('h2', null, 'Unterrichtsverlauf'),
        history.length === 0 ? empty('Keine Einträge.') :
          h('ol', { class: 'timeline' }, history.map(entry)),
      ),
    ),
  );
}

function entry(e) {
  return h('li', { class: 'card' },
    h('div', { class: 'card-title' },
      h('strong', null, e.topic ?? 'Ohne Thema'),
      h('span', { class: 'muted' },
        [e.date && shortDate(parseYmd(e.date)), e.periods && `${e.periods}. Std.`].filter(Boolean).join(' · '))),
    textBlock(e.description),
    e.homework
      ? h('div', { class: ['homework', e.homeworkDone && 'done'] },
        h('div', { class: 'homework-head' },
          h('strong', null, 'Hausaufgabe'),
          e.homeworkDone ? badge('erledigt', 'ok') : badge('offen', 'warn')),
        textBlock(e.homework))
      : null,
    e.attendance ? h('div', { class: 'muted' }, `Anwesenheit: ${e.attendance}`) : null,
  );
}
