import { append, h, empty, textBlock } from '../dom.js';
import { parseYmd, shortDate } from '../format.js';
import { navigate } from '../router.js';
import { assignAutoColors, subjectForCourse, subjectStyle } from '../colors.js';
import { homeworkDoneToast, homeworkToggle, load, pageHeader, removeAnimated } from './common.js';

export const title = 'Hausaufgaben';

const STORAGE_KEY = 'homeworkShowDone';

function savedPreference() {
  try {
    return localStorage.getItem(STORAGE_KEY) === '1';
  } catch {
    return false;
  }
}

function savePreference(value) {
  try {
    localStorage.setItem(STORAGE_KEY, value ? '1' : '0');
  } catch {
    // storage unavailable — the URL still carries the choice
  }
}

const byDateDesc = (a, b) => (b.date ?? '').localeCompare(a.date ?? '');

export async function render(ctx) {
  const param = ctx.query.get('erledigte');
  const showDone = param == null ? savedPreference() : param === '1';

  // All homework from the course histories (the portal's overview only has the
  // latest lesson per course, so older open homework would be missing).
  const [items, timetable] = await Promise.all([
    ctx.get('/api/homework?alle=1'),
    load(ctx, 'timetable', '/api/timetable'),
  ]);
  const subjects = timetable?.ok ? timetable.value.lessons.map((l) => l.subject) : [];
  assignAutoColors(subjects);

  const openCount = items.filter((i) => !i.done).length;
  const doneCount = items.length - openCount;
  const visible = showDone ? items : items.filter((i) => !i.done);

  // Group by course; courses with open homework first, then alphabetically.
  const groups = new Map();
  for (const i of visible) {
    if (!groups.has(i.courseId)) groups.set(i.courseId, { id: i.courseId, name: i.courseName, items: [] });
    groups.get(i.courseId).items.push(i);
  }
  const sortedGroups = [...groups.values()]
    .map((g) => ({ ...g, open: g.items.filter((i) => !i.done).length }))
    .sort((a, b) => Number(b.open > 0) - Number(a.open > 0) || a.name.localeCompare(b.name, 'de'));

  const toggle = h('label', { class: 'check', for: 'hw-show-done' },
    h('input', {
      type: 'checkbox', id: 'hw-show-done', checked: showDone,
      onchange: (e) => {
        savePreference(e.target.checked);
        navigate(`/hausaufgaben?erledigte=${e.target.checked ? '1' : '0'}`, { replace: true });
      },
    }),
    'Erledigte anzeigen');

  let open = openCount;
  let done = doneCount;
  const summary = h('span', { class: 'muted' });
  const updateSummary = () => {
    summary.textContent = `${open} offen` + (showDone ? `, ${done} erledigt` : '');
  };
  updateSummary();

  const emptyText = showDone ? 'Keine Hausaufgaben eingetragen.' : 'Keine offenen Hausaufgaben.';
  const list = sortedGroups.length === 0
    ? empty(emptyText)
    : h('div', { class: 'hw-groups' });

  // Called after the portal confirmed a change.
  const changed = async (item, value, card, group) => {
    open += value ? -1 : 1;
    done += value ? 1 : -1;
    updateSummary();
    group.setOpen(group.open + (value ? -1 : 1));
    if (showDone || !value) return;
    // Open-only view: hide the finished homework right away.
    await removeAnimated(card);
    if (!group.el.querySelector('article.card')) await removeAnimated(group.el);
    if (!list.querySelector('.hw-group')) list.replaceWith(empty(emptyText));
    homeworkDoneToast(item, () => navigate(location.pathname + location.search, { replace: true }));
  };

  if (sortedGroups.length) {
    list.append(...sortedGroups.map((g) => courseGroup(g, subjects, changed)));
  }

  return h('div', null,
    pageHeader('Hausaufgaben'),
    h('div', { class: 'filter-row' }, toggle, summary),
    list,
  );
}

function courseGroup(group, subjects, changed) {
  const items = [...group.items].sort((a, b) => Number(a.done) - Number(b.done) || byDateDesc(a, b));
  const count = h('span', { class: 'muted' });
  const state = {
    open: group.open,
    el: null,
    setOpen(n) {
      state.open = n;
      count.textContent = n ? `${n} offen` : 'alles erledigt';
    },
  };
  state.setOpen(group.open);
  state.el = h('section', { class: 'hw-group', style: subjectStyle(subjectForCourse(group.name, subjects)) },
    h('div', { class: 'hw-group-head' },
      h('a', { href: `/kurse/${encodeURIComponent(group.id)}` }, group.name),
      count),
    h('div', { class: 'stack' }, items.map((i) => {
      const card = h('article', { class: 'card' });
      return append(card, [
        h('div', { class: 'card-title' },
          h('span', { class: 'muted' },
            [i.date && shortDate(parseYmd(i.date)), i.topic].filter(Boolean).join(' · ') || 'ohne Datum'),
          homeworkToggle({
            courseId: i.courseId, entryId: i.entryId, done: i.done, card,
            onSaved: (value) => changed(i, value, card, state),
          })),
        textBlock(i.description),
      ]);
    })),
  );
  return state.el;
}
