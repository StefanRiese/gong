import { h, empty, textBlock } from '../dom.js';
import { parseYmd, relativeDay, longDate } from '../format.js';
import { pageHeader, substitutionCard } from './common.js';

export const title = 'Vertretungen';

export async function render(ctx) {
  const days = await ctx.get('/api/substitutions');
  if (days.length === 0) {
    return h('div', null, pageHeader('Vertretungen'), empty('Aktuell keine Vertretungen.'));
  }
  return h('div', null,
    pageHeader('Vertretungen'),
    days.map((day) => {
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
    }),
  );
}
