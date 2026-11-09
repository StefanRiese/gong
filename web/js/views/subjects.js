import { h, empty } from '../dom.js';
import { assignAutoColors, subjectForCourse, subjectStyle } from '../colors.js';
import { badge, load, pageHeader, settle } from './common.js';

export const title = 'Fächer';

export async function render(ctx) {
  const [courses, timetable] = await Promise.all([
    ctx.get('/api/courses'),
    load(ctx, 'timetable', '/api/timetable'),
  ]);

  const subjects = timetable?.ok ? timetable.value.lessons.map((l) => l.subject) : [];
  assignAutoColors(subjects);

  // Open-homework badges come from the full homework list (one portal request
  // per course), so they are added once it has loaded.
  const badgeSlots = new Map();
  settle(ctx.get('/api/homework?alle=1')).then((result) => {
    if (!result.ok) return;
    const openByCourse = new Map();
    for (const hw of result.value) {
      if (!hw.done) openByCourse.set(hw.courseId, (openByCourse.get(hw.courseId) ?? 0) + 1);
    }
    for (const [id, slot] of badgeSlots) {
      const open = openByCourse.get(id) ?? 0;
      if (open) slot.replaceChildren(badge(`${open} Hausaufgabe${open === 1 ? '' : 'n'} offen`, 'warn'));
    }
  }, () => {});

  const sorted = [...courses].sort((a, b) => a.name.localeCompare(b.name, 'de'));
  return h('div', null,
    pageHeader('Fächer'),
    sorted.length === 0 ? empty('Keine Kurse gefunden.') :
      h('div', { class: 'subject-grid' }, sorted.map((c) => {
        const slot = h('span', { class: 'badge-slot' });
        badgeSlots.set(c.id, slot);
        return h('a', {
          href: `/kurse/${encodeURIComponent(c.id)}`,
          class: 'subject-card',
          style: subjectStyle(subjectForCourse(c.name, subjects)),
        },
        h('strong', null, c.name),
        c.teachers.length ? h('span', { class: 'muted' }, c.teachers.join(', ')) : null,
        slot);
      })),
  );
}
