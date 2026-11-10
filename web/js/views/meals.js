// School meals (Caseda Schulmenü): own orders per week and the balance.
// Read-only – ordering stays on the Caseda website.

import { h, empty } from '../dom.js';
import { addDays, startOfDay, startOfWeek, WEEKDAYS_SHORT, ymd } from '../format.js';
import { badge, pageHeader } from './common.js';

export const title = 'Schulessen';

/** Weeks shown: the current one and the next two (what the server loads). */
const WEEKS = 3;

const euro = (cents) => `${(cents / 100).toFixed(2).replace('.', ',')} €`;

export async function render(ctx) {
  const res = await ctx.getFull('/api/meals');
  const data = res.data;
  const today = startOfDay(new Date());
  const low = data.balanceCents != null && data.balanceCents < (res.balanceWarningCents ?? 1000);

  const byDay = new Map();
  for (const o of data.orders) {
    if (!byDay.has(o.date)) byDay.set(o.date, []);
    byDay.get(o.date).push(o);
  }

  const monday = startOfWeek(today);
  const weeks = [];
  for (let w = 0; w < WEEKS; w++) weeks.push(weekCard(addDays(monday, 7 * w), w, byDay, today));

  return h('div', { class: 'meals' },
    pageHeader('Schulessen',
      res.orderUrl
        ? h('a', { href: res.orderUrl, target: '_blank', rel: 'noopener', class: 'button small' },
          'Bei Caseda bestellen')
        : null),
    h('div', { class: ['meal-balance', 'meal-balance-page', low && 'low'] },
      data.balanceCents == null ? 'Guthaben unbekannt' : `Guthaben: ${euro(data.balanceCents)}`,
      low ? badge('niedrig', 'warn') : null),
    weeks,
  );
}

function weekCard(monday, index, byDay, today) {
  const friday = addDays(monday, 4);
  const days = [0, 1, 2, 3, 4].map((i) => addDays(monday, i));
  const orders = days.flatMap((d) => byDay.get(ymd(d)) ?? []);
  const total = orders.reduce((sum, o) => sum + (o.priceCents ?? 0) * o.ordered, 0);
  const heading = ['Diese Woche', 'Nächste Woche', 'Übernächste Woche'][index] ?? 'Woche';
  const range = `${dm(monday)} – ${dm(friday)}`;

  return h('section', { class: 'section' },
    h('div', { class: 'section-head' }, h('h2', null, heading)),
    h('p', { class: 'meal-week-info muted' },
      [range, orders.length && `${orders.length} Essen`, total && euro(total)].filter(Boolean).join(' · ')),
    h('ol', { class: 'meal-week' }, days.map((d) => {
      const list = byDay.get(ymd(d)) ?? [];
      const past = d < today;
      const isToday = ymd(d) === ymd(today);
      return h('li', { class: ['meal-day', past && 'past', isToday && 'today'] },
        h('div', { class: 'meal-date' },
          h('strong', null, WEEKDAYS_SHORT[d.getDay()]),
          h('span', null, dm(d))),
        h('div', { class: 'meal-body' },
          list.length === 0
            ? empty('Nichts bestellt')
            : list.map((o) => h('div', { class: 'meal-item' },
              h('div', null,
                h('strong', null, o.name),
                o.ordered > 1 ? h('span', null, ` (${o.ordered}×)`) : null),
              h('div', { class: 'muted' },
                [o.line, o.priceCents != null && euro(o.priceCents * o.ordered),
                  o.allergens?.length ? `Allergene: ${o.allergens.join(', ')}` : null]
                  .filter(Boolean).join(' · '))))));
    })),
  );
}

const dm = (d) => d.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' });
