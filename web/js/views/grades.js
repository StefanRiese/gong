import { h, empty } from '../dom.js';
import { pageHeader } from './common.js';
import { courseStyle } from '../colors.js';

export const title = 'Noten';

export async function render(ctx) {
  const courses = await ctx.get('/api/grades');
  const showAll = ctx.query.get('alle') === '1';
  const withData = courses.filter((c) => c.grades.length || c.exams.length);
  const visible = showAll ? courses : withData;
  const hidden = courses.length - withData.length;

  return h('div', null,
    pageHeader('Noten'),
    hidden > 0
      ? h('p', { class: 'hint' },
        showAll
          ? h('a', { href: '/noten' }, 'Nur Kurse mit Einträgen anzeigen')
          : h('a', { href: '/noten?alle=1' },
            `${hidden} Kurs${hidden === 1 ? '' : 'e'} ohne Einträge anzeigen`))
      : null,
    visible.length === 0 ? empty('Noch keine Noten oder Klausuren eingetragen.') :
      h('div', { class: 'card-grid' }, visible.map(courseCard)),
  );
}

function courseCard(c) {
  return h('article', { class: 'card card-subject', style: courseStyle(c.course) },
    h('div', { class: 'card-title' },
      h('a', { href: `/kurse/${encodeURIComponent(c.course.id)}` }, c.course.name)),
    c.course.teachers.length ? h('div', { class: 'muted' }, c.course.teachers.join(', ')) : null,
    c.grades.length ? gradeTable(c.grades) : null,
    c.exams.length ? examList(c.exams) : null,
    !c.grades.length && !c.exams.length ? empty('Keine Einträge.') : null,
  );
}

export function gradeTable(grades) {
  return h('table', { class: 'table' },
    h('thead', null, h('tr', null,
      h('th', null, 'Leistung'), h('th', null, 'Datum'), h('th', { class: 'num' }, 'Note'))),
    h('tbody', null, grades.map((g) => h('tr', null,
      h('td', null, g.name, g.comment ? h('div', { class: 'muted' }, g.comment) : null),
      h('td', { class: 'nowrap' }, g.date),
      h('td', { class: 'num grade' }, g.mark)))));
}

export function examList(exams) {
  return h('div', { class: 'exams' },
    h('h3', null, 'Klausuren / Leistungskontrollen'),
    h('ul', null, exams.map((x) => h('li', null,
      h('span', null, x.name), x.value ? h('span', { class: 'muted' }, x.value) : null))));
}
