import { append, h, empty, icon, textBlock } from '../dom.js';
import { parseYmd, shortDate } from '../format.js';
import { homeworkToggle, pageHeader } from './common.js';
import { courseStyle } from '../colors.js';
import { examList, gradeTable } from './grades.js';

export const title = 'Kurs';

export async function render(ctx) {
  const d = await ctx.get(`/api/courses/${encodeURIComponent(ctx.params.id)}`);
  document.title = `${d.course.name} – Lumo`;
  const history = [...d.history].sort((a, b) => (b.date ?? '').localeCompare(a.date ?? ''));
  const attendance = Object.entries(d.attendance);

  return h('div', null,
    h('a', { href: '/faecher', class: 'back-link' }, icon('back'), 'Fächer'),
    pageHeader(h('span', { class: 'course-title', style: courseStyle(d.course) },
      h('span', { class: 'subject-dot', 'aria-hidden': 'true' }), d.course.name),
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
          h('ol', { class: 'timeline' }, history.map((e) => entry(e, d.course.id))),
      ),
    ),
  );
}

function entry(e, courseId) {
  return h('li', { class: 'card' },
    h('div', { class: 'card-title' },
      h('strong', null, e.topic ?? 'Ohne Thema'),
      h('span', { class: 'muted' },
        [e.date && shortDate(parseYmd(e.date)), e.periods && `${e.periods}. Std.`].filter(Boolean).join(' · '))),
    textBlock(e.description),
    e.homework ? homeworkBox(e, courseId) : null,
    e.attendance ? h('div', { class: 'muted' }, `Anwesenheit: ${e.attendance}`) : null,
  );
}

function homeworkBox(e, courseId) {
  const box = h('div', { class: 'homework' });
  return append(box, [
    h('div', { class: 'homework-head' },
      h('strong', null, 'Hausaufgabe'),
      homeworkToggle({ courseId, entryId: e.id, done: e.homeworkDone, card: box })),
    textBlock(e.homework),
  ]);
}
