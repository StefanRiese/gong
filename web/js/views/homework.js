import { h, empty, textBlock } from '../dom.js';
import { parseYmd, shortDate } from '../format.js';
import { badge, pageHeader } from './common.js';

export const title = 'Hausaufgaben';

export async function render(ctx) {
  const items = await ctx.get('/api/homework');
  const sorted = [...items].sort((a, b) =>
    Number(a.done) - Number(b.done) || (b.date ?? '').localeCompare(a.date ?? ''));

  return h('div', null,
    pageHeader('Hausaufgaben'),
    h('p', { class: 'hint' },
      'Aktuelle Hausaufgaben aus „Mein Unterricht“. Ältere Einträge stehen im jeweiligen Kurs.'),
    sorted.length === 0 ? empty('Keine Hausaufgaben eingetragen.') :
      h('div', { class: 'stack' }, sorted.map((i) =>
        h('article', { class: ['card', i.done && 'done'] },
          h('div', { class: 'card-title' },
            h('a', { href: `/kurse/${encodeURIComponent(i.courseId)}` }, i.courseName),
            i.done ? badge('erledigt', 'ok') : badge('offen', 'warn')),
          h('div', { class: 'muted' },
            [i.date && shortDate(parseYmd(i.date)), i.topic].filter(Boolean).join(' · ')),
          textBlock(i.description),
        ))),
  );
}
