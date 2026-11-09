import { api, errorMessage } from '../api.js';
import { h, empty, errorBox, icon } from '../dom.js';
import {
  autoColor, autoSubjectOf, courseKey, courseSubject, getCourseOverrides, getCourses,
  getSubjectColors, getSubjects, initColors, subjectColor,
} from '../colors.js';
import { pageHeader } from './common.js';

export const title = 'Einstellungen';

let rowCounter = 0;

export async function render(ctx) {
  const [settings, timetable, courses] = await Promise.all([
    api('/api/settings'),
    ctx.features.has('timetable') ? ctx.get('/api/timetable') : Promise.resolve(null),
    ctx.features.has('lessons') ? ctx.get('/api/courses') : Promise.resolve([]),
  ]);
  initColors({
    settings,
    subjects: timetable?.lessons.map((l) => l.subject) ?? [],
    courses,
  });

  const status = h('span', { class: 'muted', 'aria-live': 'polite' });
  const list = h('ul', { class: 'color-list' });
  const resetAll = h('button', { class: 'button small', type: 'button' }, 'Alles automatisch');

  let saving = Promise.resolve();
  const save = (patch) => {
    saving = saving.then(async () => {
      status.textContent = 'Speichern …';
      try {
        const saved = await api('/api/settings', {
          method: 'PUT',
          body: {
            subjectColors: patch.subjectColors ?? getSubjectColors(),
            courseSubjects: patch.courseSubjects ?? getCourseOverrides(),
          },
        });
        initColors({ settings: saved });
        status.textContent = 'Gespeichert';
      } catch (err) {
        status.replaceChildren(errorBox(errorMessage(err)));
      }
      renderList();
    });
  };

  const colorInput = (key, label) => {
    const id = `color-${++rowCounter}`;
    return [id, h('input', {
      type: 'color', id, value: subjectColor(key), 'aria-label': `Farbe für ${label}`,
      onchange: (e) => save({ subjectColors: { ...getSubjectColors(), [key]: e.target.value } }),
    })];
  };

  const resetButton = (key) => (key in getSubjectColors()
    ? h('button', {
      class: 'button small', type: 'button', title: `Automatische Farbe (${autoColor(key)})`,
      onclick: () => {
        const next = getSubjectColors();
        delete next[key];
        save({ subjectColors: next });
      },
    }, 'Zurücksetzen')
    : h('span', { class: 'muted color-mode' }, 'automatisch'));

  const subjectSelect = (course) => {
    const auto = autoSubjectOf(course.id);
    const overrides = getCourseOverrides();
    const current = course.id in overrides ? overrides[course.id] : '__auto';
    const options = [
      ['__auto', `automatisch${auto ? ` (${auto})` : ' (keins gefunden)'}`],
      ...getSubjects().sort((a, b) => a.localeCompare(b, 'de')).map((s) => [s, s]),
      ['', 'kein Stundenplan-Fach'],
    ];
    return h('select', {
      class: 'subject-select', 'aria-label': `Stundenplan-Fach für ${course.name}`,
      onchange: (e) => {
        const next = getCourseOverrides();
        if (e.target.value === '__auto') delete next[course.id];
        else next[course.id] = e.target.value;
        save({ courseSubjects: next });
      },
    }, options.map(([value, label]) => h('option', { value, selected: value === current }, label)));
  };

  const renderList = () => {
    const allCourses = getCourses().sort((a, b) => a.name.localeCompare(b.name, 'de'));
    const mapped = new Set(allCourses.map((c) => courseSubject(c.id)).filter(Boolean));
    const unmappedSubjects = getSubjects().filter((s) => !mapped.has(s)).sort((a, b) => a.localeCompare(b, 'de'));
    resetAll.hidden = Object.keys(getSubjectColors()).length === 0
      && Object.keys(getCourseOverrides()).length === 0;

    const rows = allCourses.map((c) => {
      const key = courseKey(c);
      const [id, input] = colorInput(key, c.name);
      return h('li', { class: 'color-row', style: { '--subject': subjectColor(key) } },
        input,
        h('div', { class: 'color-name' },
          h('label', { for: id }, c.name),
          h('div', { class: 'color-sub' }, 'Stundenplan: ', subjectSelect(c))),
        resetButton(key));
    });
    for (const s of unmappedSubjects) {
      const [id, input] = colorInput(s, s);
      rows.push(h('li', { class: 'color-row', style: { '--subject': subjectColor(s) } },
        input,
        h('div', { class: 'color-name' },
          h('label', { for: id }, s),
          h('div', { class: 'color-sub muted' }, 'nur im Stundenplan, keinem Kurs zugeordnet')),
        resetButton(s)));
    }
    list.replaceChildren(...rows);
  };

  resetAll.addEventListener('click', () => save({ subjectColors: {}, courseSubjects: {} }));
  renderList();

  const hasData = getCourses().length > 0 || getSubjects().length > 0;
  return h('div', null,
    pageHeader('Einstellungen'),
    h('section', { class: 'section' },
      h('div', { class: 'section-head' }, h('h2', null, 'Fächer & Farben'), resetAll, status),
      h('p', { class: 'hint' },
        'Jeder Kurs nutzt die Farbe seines Stundenplan-Fachs, damit Stundenplan, Fächer, ',
        'Hausaufgaben und Noten gleich aussehen. Die Zuordnung zum Stundenplan-Kürzel ',
        'wird automatisch erkannt und kann hier korrigiert werden. Gilt auf allen Geräten.'),
      hasData ? list : empty('Keine Fächer gefunden.'),
    ),
    h('section', { class: 'section' },
      h('h2', null, 'Benachrichtigungen'),
      h('p', null, h('a', { href: '/benachrichtigungen', class: 'settings-link' },
        icon('bell'), 'Push-Benachrichtigungen (ntfy): Status, Testnachricht')),
    ),
  );
}
