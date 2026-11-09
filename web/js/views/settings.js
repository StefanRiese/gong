import { api, errorMessage } from '../api.js';
import { h, empty, errorBox, icon } from '../dom.js';
import {
  autoColor, autoSubjectOf, courseKey, courseSubject, getCourseOverrides, getCourses,
  getSubjectColors, getSubjects, initColors, subjectColor,
} from '../colors.js';
import { pageHeader } from './common.js';
import { planValues, sortClasses } from '../substitution-filter.js';

export const title = 'Einstellungen';

/** No live re-rendering: it would discard unsaved changes. */
export const live = false;

let rowCounter = 0;

export async function render(ctx) {
  const [settings, timetable, courses, plan] = await Promise.all([
    api('/api/settings'),
    ctx.features.has('timetable') ? ctx.get('/api/timetable') : Promise.resolve(null),
    ctx.features.has('lessons') ? ctx.get('/api/courses') : Promise.resolve([]),
    // The full plan (all classes) to choose from.
    ctx.features.has('substitutions')
      ? api('/api/substitutions?alle=1').then((r) => r.data, () => [])
      : Promise.resolve(null),
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
    plan ? substitutionFilterSection(settings.substitutionFilter, plan) : null,
    h('section', { class: 'section' },
      h('h2', null, 'Server'),
      h('p', null, h('a', { href: '/einstellungen/server', class: 'settings-link' },
        icon('settings'), 'Schulportal-Zugang, Passwort, Abgleich, Benachrichtigungen, Netzwerk')),
    ),
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
        icon('bell'), 'Push-Benachrichtigungen: Status, Testnachricht')),
    ),
  );
}

/**
 * Permanent filter of the substitution plan, stored on the server: applies to
 * Vertretungen, Heute (only these entries are shown in the lessons) and
 * notifications, on all devices.
 */
function substitutionFilterSection(saved, plan) {
  const filter = {
    classes: [...(saved?.classes ?? [])],
    showUnassigned: saved?.showUnassigned === true,
    hiddenTypes: [...(saved?.hiddenTypes ?? [])],
    hiddenNotices: [...(saved?.hiddenNotices ?? [])],
  };
  const values = planValues(plan);
  const status = h('span', { class: 'muted', 'aria-live': 'polite' });

  let saving = Promise.resolve();
  const save = () => {
    saving = saving.then(async () => {
      status.textContent = 'Speichern …';
      try {
        await api('/api/settings', { method: 'PUT', body: { substitutionFilter: filter } });
        status.textContent = 'Gespeichert';
      } catch (err) {
        status.replaceChildren(errorBox(errorMessage(err)));
      }
    });
    renderAll();
  };

  const toggle = (list, value) => {
    const i = list.indexOf(value);
    if (i >= 0) list.splice(i, 1); else list.push(value);
    save();
  };

  const classChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Meine Klassen' });
  const typeChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Ausgeblendete Arten' });
  const noticeChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Ausgeblendete Hinweise' });
  const unassigned = h('input', {
    type: 'checkbox', id: 'sub-unassigned',
    onchange: (e) => {
      filter.showUnassigned = e.target.checked;
      save();
    },
  });
  const addInput = h('input', {
    class: 'input class-input', placeholder: 'z. B. 05eG', 'aria-label': 'Klasse hinzufügen', maxlength: '40',
  });
  const add = h('button', {
    type: 'button', class: 'button small',
    onclick: () => {
      const c = addInput.value.trim();
      if (c && !filter.classes.includes(c)) {
        filter.classes.push(c);
        save();
      }
      addInput.value = '';
    },
  }, 'Hinzufügen');
  addInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      add.click();
    }
  });

  function renderAll() {
    const classes = sortClasses([...new Set([...values.classes, ...filter.classes])]);
    classChips.replaceChildren(...classes.map((c) => h('button', {
      type: 'button', class: 'chip pick', 'aria-pressed': String(filter.classes.includes(c)),
      onclick: () => toggle(filter.classes, c),
    }, c)));
    const types = [...new Set([...values.types, ...filter.hiddenTypes])].sort((a, b) => a.localeCompare(b, 'de'));
    typeChips.replaceChildren(...types.map((t) => h('button', {
      type: 'button', class: 'chip pick', 'aria-pressed': String(filter.hiddenTypes.includes(t)),
      onclick: () => toggle(filter.hiddenTypes, t),
    }, t)));
    const notices = [...new Set([...values.notices, ...filter.hiddenNotices])].sort((a, b) => a.localeCompare(b, 'de'));
    noticeChips.replaceChildren(...notices.map((t) => h('button', {
      type: 'button', class: 'chip pick', 'aria-pressed': String(filter.hiddenNotices.includes(t)),
      onclick: () => toggle(filter.hiddenNotices, t),
    }, t)));
    unassigned.checked = filter.showUnassigned;
    unassigned.disabled = filter.classes.length === 0;
  }
  renderAll();

  return h('section', { class: 'section', id: 'vertretungsplan' },
    h('div', { class: 'section-head' }, h('h2', null, 'Vertretungsplan'), status),
    h('p', { class: 'hint' },
      'Der Vertretungsplan enthält alle Klassen der Schule. Mit eigenen Klassen zeigen Vertretungen, ',
      'Heute und die Benachrichtigungen nur deren Einträge, und Heute trägt sie in die Stunden ein. ',
      'Gilt auf allen Geräten; auf der Seite Vertretungen lassen sich zusätzlich alle Klassen anzeigen.'),
    h('div', { class: 'card settings-form' },
      h('div', { class: 'field' },
        h('span', { class: 'field-label' }, 'Meine Klassen'),
        values.classes.length || filter.classes.length
          ? classChips
          : h('span', { class: 'muted' }, 'Im aktuellen Plan stehen keine Klassen.'),
        h('div', { class: 'inline-fields' }, addInput, add)),
      h('label', { class: 'check', for: 'sub-unassigned' }, unassigned,
        'Einträge ohne Klasse anzeigen (z. B. Pausenaufsicht, Betreuung)'),
      h('div', { class: 'field' },
        h('span', { class: 'field-label' }, 'Diese Arten ausblenden'),
        typeChips),
      h('div', { class: 'field' },
        h('span', { class: 'field-label' }, 'Diese Hinweise ausblenden'),
        values.notices.length || filter.hiddenNotices.length
          ? noticeChips
          : h('span', { class: 'muted' }, 'Im aktuellen Plan stehen keine Hinweise.'),
        h('span', { class: 'field-hint' }, 'Hinweise wie „Allgemein“ stehen über den Vertretungen eines Tages.'))));
}
