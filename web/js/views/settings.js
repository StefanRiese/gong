import { api, errorMessage } from '../api.js';
import { h, empty, errorBox, icon } from '../dom.js';
import { assignAutoColors, autoColor, getSubjectColors, setSubjectColors, subjectColor } from '../colors.js';
import { pageHeader } from './common.js';

export const title = 'Einstellungen';

export async function render(ctx) {
  const [settings, timetable] = await Promise.all([
    api('/api/settings'),
    ctx.features.has('timetable') ? ctx.get('/api/timetable') : Promise.resolve(null),
  ]);
  setSubjectColors(settings.subjectColors);

  const fromTimetable = [...new Set((timetable?.lessons ?? []).map((l) => l.subject?.trim()).filter(Boolean))];
  assignAutoColors(fromTimetable);
  const extra = Object.keys(settings.subjectColors).filter((s) => !fromTimetable.includes(s));
  const subjects = [...fromTimetable, ...extra].sort((a, b) => a.localeCompare(b, 'de'));

  const status = h('span', { class: 'muted', 'aria-live': 'polite' });
  const list = h('ul', { class: 'color-list' });
  const resetAll = h('button', { class: 'button small', type: 'button' }, 'Alle automatisch');

  let saving = Promise.resolve();
  const save = (colors) => {
    saving = saving.then(async () => {
      status.textContent = 'Speichern …';
      try {
        const saved = await api('/api/settings', { method: 'PUT', body: { subjectColors: colors } });
        setSubjectColors(saved.subjectColors);
        status.textContent = 'Gespeichert';
      } catch (err) {
        status.replaceChildren(errorBox(errorMessage(err)));
      }
      renderList();
    });
  };

  const renderList = () => {
    const colors = getSubjectColors();
    resetAll.hidden = Object.keys(colors).length === 0;
    list.replaceChildren(...subjects.map((name) => {
      const isCustom = name in colors;
      const id = `color-${[...name].map((c) => c.codePointAt(0).toString(16)).join('')}`;
      const input = h('input', {
        type: 'color', id, value: subjectColor(name), 'aria-label': `Farbe für ${name}`,
        onchange: (e) => save({ ...getSubjectColors(), [name]: e.target.value }),
      });
      return h('li', { class: 'color-row', style: { '--subject': subjectColor(name) } },
        input,
        h('label', { for: id, class: 'color-name' }, name,
          !fromTimetable.includes(name) ? h('span', { class: 'muted' }, ' (nicht im Stundenplan)') : null),
        h('span', { class: 'muted color-mode' }, isCustom ? 'eigene Farbe' : 'automatisch'),
        isCustom
          ? h('button', {
            class: 'button small', type: 'button', title: `Automatische Farbe (${autoColor(name)})`,
            onclick: () => {
              const next = getSubjectColors();
              delete next[name];
              save(next);
            },
          }, 'Zurücksetzen')
          : h('span'));
    }));
  };

  resetAll.addEventListener('click', () => save({}));
  renderList();

  return h('div', null,
    pageHeader('Einstellungen'),
    h('section', { class: 'section' },
      h('div', { class: 'section-head' }, h('h2', null, 'Fächerfarben'), resetAll, status),
      h('p', { class: 'hint' },
        'Farben für Stundenplan und „Heute“. Ohne eigene Farbe bekommt jedes Fach automatisch eine. ',
        'Die Einstellung gilt auf allen Geräten.'),
      subjects.length ? list : empty('Keine Fächer im Stundenplan gefunden.'),
    ),
    h('section', { class: 'section' },
      h('h2', null, 'Benachrichtigungen'),
      h('p', null, h('a', { href: '/benachrichtigungen', class: 'settings-link' },
        icon('bell'), 'Push-Benachrichtigungen (ntfy): Status, Testnachricht')),
    ),
  );
}
