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
    notificationLinks(),
    serverLinks(),
    h('section', { class: 'section', id: 'farben' },
      h('div', { class: 'section-head' }, h('h2', null, 'Fächer & Farben'), resetAll, status),
      h('p', { class: 'hint' },
        'Jeder Kurs nutzt die Farbe seines Stundenplan-Fachs, damit Stundenplan, Fächer, ',
        'Hausaufgaben und Noten gleich aussehen. Die Zuordnung zum Stundenplan-Kürzel ',
        'wird automatisch erkannt und kann hier korrigiert werden. Gilt auf allen Geräten.'),
      hasData ? list : empty('Keine Fächer gefunden.'),
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

  // One class for now; a list saved earlier stays selectable as it is.
  const savedKey = filter.classes.join(', ');
  const classOptions = sortClasses([...new Set([...values.classes, ...(filter.classes.length === 1 ? filter.classes : [])])]);
  const classSelect = h('select', {
    id: 'sub-class', class: 'input class-select',
    onchange: (e) => {
      const v = e.target.value;
      filter.classes = v === '' ? [] : v === savedKey ? [...(saved?.classes ?? [])] : [v];
      save();
    },
  },
  h('option', { value: '' }, 'Alle Klassen (ganzer Plan)'),
  filter.classes.length > 1 ? h('option', { value: savedKey, selected: true }, savedKey) : null,
  classOptions.map((c) => h('option', { value: c, selected: filter.classes.length === 1 && filter.classes[0] === c }, c)));

  const typeChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Ausgeblendete Arten' });
  const noticeChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Ausgeblendete Hinweise' });
  const unassigned = h('input', {
    type: 'checkbox', id: 'sub-unassigned',
    onchange: (e) => {
      filter.showUnassigned = e.target.checked;
      save();
    },
  });

  const chips = (container, all, hidden) => container.replaceChildren(...all.map((t) => h('button', {
    type: 'button', class: 'chip pick', 'aria-pressed': String(hidden.includes(t)),
    onclick: () => toggle(hidden, t),
  }, t)));
  const byName = (a, b) => a.localeCompare(b, 'de');

  function renderAll() {
    chips(typeChips, [...new Set([...values.types, ...filter.hiddenTypes])].sort(byName), filter.hiddenTypes);
    chips(noticeChips, [...new Set([...values.notices, ...filter.hiddenNotices])].sort(byName), filter.hiddenNotices);
    unassigned.checked = filter.showUnassigned;
    unassigned.disabled = filter.classes.length === 0;
  }
  renderAll();

  const extraCount = filter.hiddenTypes.length + filter.hiddenNotices.length;
  return h('section', { class: 'section', id: 'vertretungsplan' },
    h('div', { class: 'section-head' }, h('h2', null, 'Vertretungsplan'), status),
    h('div', { class: 'card settings-form' },
      h('div', { class: 'field' },
        h('label', { for: 'sub-class' }, 'Meine Klasse'),
        classSelect,
        h('span', { class: 'field-hint' },
          values.classes.length
            ? 'Vertretungen, Heute und Benachrichtigungen zeigen dann nur diese Klasse. Gilt auf allen Geräten.'
            : 'Im aktuellen Plan stehen keine Klassen – die Auswahl füllt sich, sobald Vertretungen eingetragen sind.')),
      h('label', { class: 'check', for: 'sub-unassigned' }, unassigned,
        'Einträge ohne Klasse anzeigen (z. B. Pausenaufsicht, Betreuung)'),
      h('details', { class: 'more-filters', open: extraCount > 0 },
        h('summary', null, 'Weitere Filter', extraCount ? ` (${extraCount} aktiv)` : ''),
        h('div', { class: 'field' },
          h('span', { class: 'field-label' }, 'Diese Arten ausblenden'),
          values.types.length || filter.hiddenTypes.length
            ? typeChips
            : h('span', { class: 'muted' }, 'Im aktuellen Plan stehen keine Arten.')),
        h('div', { class: 'field' },
          h('span', { class: 'field-label' }, 'Diese Hinweise ausblenden'),
          values.notices.length || filter.hiddenNotices.length
            ? noticeChips
            : h('span', { class: 'muted' }, 'Im aktuellen Plan stehen keine Hinweise.'),
          h('span', { class: 'field-hint' }, 'Hinweise wie „Allgemein“ stehen über den Vertretungen eines Tages.')))));
}

/** Links to the server settings, grouped like that page. */
function serverLinks() {
  const link = (anchor, text, hint) => h('li', null,
    h('a', { href: `/einstellungen/server#${anchor}` }, text),
    h('span', { class: 'muted' }, ` – ${hint}`));
  return h('section', { class: 'section', id: 'server' },
    h('h2', null, 'Konto & Server'),
    h('div', { class: 'card link-card' },
      h('ul', { class: 'link-list' },
        link('schulportal', 'Schulportal-Zugang', 'Schule, Benutzername, Passwort'),
        link('passwort', 'Passwort dieser Web-Oberfläche', 'ändern, andere Geräte abmelden'),
        link('abgleich', 'Abgleich', 'wie oft die Daten geladen werden'),
        link('webuntis', 'WebUntis', 'Vertretungen aus einer zweiten Quelle ergänzen'),
        link('schulessen', 'Schulessen (Caseda)', 'Guthaben und bestelltes Essen anzeigen'),
        link('netzwerk', 'Netzwerk', 'Erreichbarkeit, Port, Anmeldedauer'),
        link('update', 'Update', 'Version, neue Versionen installieren'))));
}

/** Notification status and setup. */
function notificationLinks() {
  return h('section', { class: 'section', id: 'benachrichtigungen' },
    h('h2', null, 'Benachrichtigungen'),
    h('div', { class: 'card link-card' },
      h('ul', { class: 'link-list' },
        h('li', null, h('a', { href: '/benachrichtigungen' }, 'Status und Testnachricht'),
          h('span', { class: 'muted' }, ' – was zuletzt gesendet wurde')),
        h('li', null, h('a', { href: '/einstellungen/server#benachrichtigungen' }, 'Einrichten'),
          h('span', { class: 'muted' }, ' – ntfy-Server, Thema, worüber benachrichtigt wird')))));
}
