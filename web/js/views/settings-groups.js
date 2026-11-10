// The groups of the settings page: one flat block per topic (heading, fields).
// Controls register with the form (settings-form.js); saving is done once by
// the page. Buttons in here only run actions (login test, update).

import { api, ApiError } from '../api.js';
import { h, empty } from '../dom.js';
import { age } from '../format.js';
import {
  autoColor, autoSubjectOf, getCourseOverrides, getCourses, getSubjectColors, getSubjects,
} from '../colors.js';
import { planValues, sortClasses } from '../substitution-filter.js';
import { releaseNotes, waitForNewVersion } from '../update.js';
import { checkbox, field, input, messageArea, randomTopic, schoolPicker } from './forms.js';
import { bindCheck, bindText, stable } from './settings-form.js';

const byName = (a, b) => a.localeCompare(b, 'de');

/** A group: heading, optional hint, one card with the fields. */
export function group(id, titleText, hint, ...content) {
  return h('section', { class: 'settings-group', id },
    h('h2', { class: 'group-title' }, titleText),
    hint ? h('p', { class: 'hint' }, hint) : null,
    h('div', { class: 'card settings-form' }, content));
}

/** Label for a part of a group (not a heading: the hierarchy stays flat). */
const partLabel = (text, id) => h('div', { class: 'part-label', id }, text);

/** Button that tests a login without saving; the result shows below it. */
function loginTest(path, body, okText) {
  const msg = messageArea();
  const button = h('button', { type: 'button', class: 'button' }, 'Anmeldung prüfen');
  button.addEventListener('click', async () => {
    msg.ok('Anmeldung wird geprüft …');
    button.disabled = true;
    try {
      msg.ok(okText(await api(path, { method: 'POST', body: body() })));
    } catch (err) {
      msg.error(err);
    } finally {
      button.disabled = false;
    }
  });
  return [h('div', { class: 'button-row' }, button), msg.el];
}

/** Shows [fields] only while [enabled] is checked. */
function showWhenOn(enabled, fields) {
  const update = () => {
    fields.hidden = !enabled.box.checked;
  };
  enabled.box.addEventListener('change', update);
  update();
  return fields;
}

// --- Schulportal -----------------------------------------------------------------

export function portalGroup({ form, v, secrets }) {
  const school = schoolPicker({ value: v.SPH_SCHOOL_ID, onChange: () => form.touch() });
  form.add('server', 'SPH_SCHOOL_ID', () => (school.value == null ? '' : String(school.value)));
  const username = bindText(form, 'SPH_USERNAME', input({ value: v.SPH_USERNAME ?? '', required: true }));
  const password = bindText(form, 'SPH_PASSWORD', input({
    type: 'password', autocomplete: 'off', placeholder: secrets.SPH_PASSWORD ? 'unverändert' : '',
  }), { secret: true });
  return group('schulportal', 'Schulportal',
    'Mit diesen Daten meldet sich der Server beim Schulportal an. Bei einem anderen Konto werden die gespeicherten Daten verworfen.',
    field('Schule', school.el),
    field('Benutzername', username),
    field('Passwort', password, secrets.SPH_PASSWORD ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
    loginTest('/api/server-settings/test-login',
      () => ({ schoolId: school.value, username: username.value.trim(), password: password.value || undefined }),
      () => 'Anmeldung beim Schulportal erfolgreich.'));
}

// --- Vertretungen (own class, filters) and WebUntis ---------------------------------

/**
 * The permanent filter of the substitution plan (stored on the server; applies to
 * Vertretungen, Heute and notifications) and WebUntis as a second source.
 */
export function substitutionsGroup({ form, v, secrets, saved, plan }) {
  const parts = [];

  if (plan) {
    const filter = {
      classes: [...(saved?.classes ?? [])],
      showUnassigned: saved?.showUnassigned === true,
      hiddenTypes: [...(saved?.hiddenTypes ?? [])],
      hiddenNotices: [...(saved?.hiddenNotices ?? [])],
    };
    form.add('personal', 'substitutionFilter', () => stable(filter));
    const values = planValues(plan);

    // One class for now; a list saved earlier stays selectable as it is.
    const savedKey = filter.classes.join(', ');
    const classOptions = sortClasses([...new Set([...values.classes, ...(filter.classes.length === 1 ? filter.classes : [])])]);
    const classSelect = h('select', {
      id: 'sub-class', class: 'input class-select',
      onchange: (e) => {
        const val = e.target.value;
        filter.classes = val === '' ? [] : val === savedKey ? [...(saved?.classes ?? [])] : [val];
        renderAll();
      },
    },
    h('option', { value: '' }, 'Alle Klassen (ganzer Plan)'),
    filter.classes.length > 1 ? h('option', { value: savedKey, selected: true }, savedKey) : null,
    classOptions.map((c) => h('option', { value: c, selected: filter.classes.length === 1 && filter.classes[0] === c }, c)));

    const unassigned = h('input', {
      type: 'checkbox', id: 'sub-unassigned',
      onchange: (e) => {
        filter.showUnassigned = e.target.checked;
        renderAll();
      },
    });
    const typeChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Ausgeblendete Arten' });
    const noticeChips = h('div', { class: 'chips', role: 'group', 'aria-label': 'Ausgeblendete Hinweise' });
    const chips = (container, all, hidden) => container.replaceChildren(...all.map((t) => h('button', {
      type: 'button', class: 'chip pick', 'aria-pressed': String(hidden.includes(t)),
      onclick: () => {
        const i = hidden.indexOf(t);
        if (i >= 0) hidden.splice(i, 1); else hidden.push(t);
        renderAll();
      },
    }, t)));
    const renderAll = () => {
      chips(typeChips, [...new Set([...values.types, ...filter.hiddenTypes])].sort(byName), filter.hiddenTypes);
      chips(noticeChips, [...new Set([...values.notices, ...filter.hiddenNotices])].sort(byName), filter.hiddenNotices);
      unassigned.checked = filter.showUnassigned;
      unassigned.disabled = filter.classes.length === 0;
      form.touch();
    };
    renderAll();

    parts.push(
      h('div', { class: 'field' },
        h('label', { for: 'sub-class' }, 'Meine Klasse'),
        classSelect,
        h('span', { class: 'field-hint' },
          values.classes.length
            ? 'Vertretungen, Heute und Benachrichtigungen zeigen dann nur diese Klasse.'
            : 'Im aktuellen Plan stehen keine Klassen – die Auswahl füllt sich, sobald Vertretungen eingetragen sind.')),
      h('label', { class: 'check', for: 'sub-unassigned' }, unassigned,
        'Einträge ohne Klasse anzeigen (z. B. Pausenaufsicht, Betreuung)'),
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
        h('span', { class: 'field-hint' }, 'Hinweise wie „Allgemein“ stehen über den Vertretungen eines Tages.')),
    );
  }

  parts.push(...untisPart({ form, v, secrets }));
  return group('vertretungsplan', 'Vertretungen',
    'Gilt auf allen Geräten.', parts);
}

function untisPart({ form, v, secrets }) {
  const enabled = bindCheck(form, 'UNTIS_ENABLED',
    checkbox('WebUntis als zweite Quelle nutzen', v.UNTIS_ENABLED));
  const server = bindText(form, 'UNTIS_SERVER', input({
    type: 'text', value: v.UNTIS_SERVER ?? '', placeholder: 'meineschule.webuntis.com',
    autocapitalize: 'none', spellcheck: false,
  }));
  const school = bindText(form, 'UNTIS_SCHOOL', input({
    type: 'text', value: v.UNTIS_SCHOOL ?? '', placeholder: 'wie vor „.webuntis.com“',
  }));
  const username = bindText(form, 'UNTIS_USERNAME', input({ type: 'text', value: v.UNTIS_USERNAME ?? '', autocomplete: 'off' }));
  const password = bindText(form, 'UNTIS_PASSWORD', input({
    type: 'password', autocomplete: 'off', placeholder: secrets.UNTIS_PASSWORD ? 'unverändert' : '',
  }), { secret: true });
  const fields = showWhenOn(enabled, h('div', { class: 'stack' },
    field('Adresse von WebUntis', server, 'Die Adresse der Webseite genügt, z. B. aus dem Browser kopiert.'),
    field('Name der Schule in WebUntis', school, 'Nur nötig, wenn er nicht dem Anfang der Adresse entspricht.'),
    field('Benutzername', username),
    field('Passwort', password, secrets.UNTIS_PASSWORD ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
    loginTest('/api/server-settings/test-untis',
      () => ({
        server: server.value.trim(), username: username.value.trim(),
        password: password.value || undefined, school: school.value.trim() || undefined,
      }),
      (res) => (res.className ? `Anmeldung bei WebUntis erfolgreich, Klasse ${res.className}.` : 'Anmeldung bei WebUntis erfolgreich.'))));
  return [
    partLabel('WebUntis', 'webuntis'),
    h('p', { class: 'hint' },
      'Ergänzt die Vertretungen um Änderungen aus WebUntis, die im Schulportal (noch) fehlen – zum Beispiel für spätere Tage. Diese Einträge sind gekennzeichnet. Nur lesend; ein Klassenzugang genügt.'),
    enabled.el,
    fields,
  ];
}

// --- Schulessen (Caseda) ----------------------------------------------------------------

export function mealsGroup({ form, v, secrets }) {
  const enabled = bindCheck(form, 'CASEDA_ENABLED',
    checkbox('Schulessen von Caseda anzeigen (Guthaben und eigene Bestellungen)', v.CASEDA_ENABLED));
  const username = bindText(form, 'CASEDA_USERNAME', input({ type: 'email', value: v.CASEDA_USERNAME ?? '', autocomplete: 'off' }));
  const password = bindText(form, 'CASEDA_PASSWORD', input({
    type: 'password', autocomplete: 'off', placeholder: secrets.CASEDA_PASSWORD ? 'unverändert' : '',
  }), { secret: true });
  const warning = bindText(form, 'CASEDA_BALANCE_WARNING', input({
    type: 'text', inputmode: 'decimal', value: v.CASEDA_BALANCE_WARNING ?? '10,00',
    class: 'input narrow', pattern: '[0-9]+([,.][0-9]{1,2})?',
  }));
  const url = bindText(form, 'CASEDA_URL', input({ type: 'url', value: v.CASEDA_URL ?? 'https://www.caseda-schulmenue.de' }));
  const fields = showWhenOn(enabled, h('div', { class: 'stack' },
    field('E-Mail (Caseda-Konto)', username),
    field('Passwort', password, secrets.CASEDA_PASSWORD ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
    field('Hinweis bei Guthaben unter … €', warning),
    field('Adresse des Bestellsystems', url, 'Andere Caterer mit schulmenueplaner.de funktionieren ebenso.'),
    loginTest('/api/server-settings/test-caseda',
      () => ({ username: username.value.trim(), password: password.value || undefined, url: url.value.trim() }),
      () => 'Anmeldung bei Caseda erfolgreich.')));
  return group('schulessen', 'Schulessen',
    'Zeigt unter Schulessen die eigenen Bestellungen und das Guthaben, auf der Seite Heute das bestellte Essen – nur lesend; bestellt wird weiterhin bei Caseda.',
    enabled.el, fields);
}

// --- Fächer & Farben -----------------------------------------------------------------------

/** Subject colors and the course ↔ timetable subject assignment (staged until saved). */
export function colorsGroup({ form }) {
  const local = { subjectColors: getSubjectColors(), courseSubjects: getCourseOverrides() };
  form.add('personal', 'subjectColors', () => stable(local.subjectColors));
  form.add('personal', 'courseSubjects', () => stable(local.courseSubjects));

  const subjectOf = (c) => (c.id in local.courseSubjects ? local.courseSubjects[c.id] || null : autoSubjectOf(c.id));
  const keyOf = (c) => subjectOf(c) ?? c.name.trim();
  const colorOf = (key) => local.subjectColors[key] ?? autoColor(key);

  const list = h('ul', { class: 'color-list' });
  const resetAll = h('button', { class: 'button small', type: 'button' }, 'Alles automatisch');
  let counter = 0;

  const change = (fn) => {
    fn();
    renderList();
    form.touch();
  };

  const colorInput = (key, label) => {
    const id = `color-${++counter}`;
    return [id, h('input', {
      type: 'color', id, value: colorOf(key), 'aria-label': `Farbe für ${label}`,
      onchange: (e) => change(() => {
        local.subjectColors[key] = e.target.value;
      }),
    })];
  };
  const resetButton = (key) => (key in local.subjectColors
    ? h('button', {
      class: 'button small', type: 'button', title: `Automatische Farbe (${autoColor(key)})`,
      onclick: () => change(() => {
        delete local.subjectColors[key];
      }),
    }, 'Zurücksetzen')
    : h('span', { class: 'muted color-mode' }, 'automatisch'));

  const subjectSelect = (course) => {
    const auto = autoSubjectOf(course.id);
    const current = course.id in local.courseSubjects ? local.courseSubjects[course.id] : '__auto';
    const options = [
      ['__auto', `automatisch${auto ? ` (${auto})` : ' (keins gefunden)'}`],
      ...getSubjects().sort(byName).map((s) => [s, s]),
      ['', 'kein Stundenplan-Fach'],
    ];
    return h('select', {
      class: 'subject-select', 'aria-label': `Stundenplan-Fach für ${course.name}`,
      onchange: (e) => change(() => {
        if (e.target.value === '__auto') delete local.courseSubjects[course.id];
        else local.courseSubjects[course.id] = e.target.value;
      }),
    }, options.map(([value, label]) => h('option', { value, selected: value === current }, label)));
  };

  function renderList() {
    const courses = getCourses().sort((a, b) => byName(a.name, b.name));
    const mapped = new Set(courses.map(subjectOf).filter(Boolean));
    const unmapped = getSubjects().filter((s) => !mapped.has(s)).sort(byName);
    resetAll.hidden = Object.keys(local.subjectColors).length === 0 && Object.keys(local.courseSubjects).length === 0;

    const rows = courses.map((c) => {
      const key = keyOf(c);
      const [id, picker] = colorInput(key, c.name);
      return h('li', { class: 'color-row', style: { '--subject': colorOf(key) } },
        picker,
        h('div', { class: 'color-name' },
          h('label', { for: id }, c.name),
          h('div', { class: 'color-sub' }, 'Stundenplan: ', subjectSelect(c))),
        resetButton(key));
    });
    for (const s of unmapped) {
      const [id, picker] = colorInput(s, s);
      rows.push(h('li', { class: 'color-row', style: { '--subject': colorOf(s) } },
        picker,
        h('div', { class: 'color-name' },
          h('label', { for: id }, s),
          h('div', { class: 'color-sub muted' }, 'nur im Stundenplan, keinem Kurs zugeordnet')),
        resetButton(s)));
    }
    list.replaceChildren(...rows);
  }
  resetAll.addEventListener('click', () => change(() => {
    local.subjectColors = {};
    local.courseSubjects = {};
  }));
  renderList();

  const hasData = getCourses().length > 0 || getSubjects().length > 0;
  return group('farben', 'Fächer & Farben',
    'Jeder Kurs nutzt die Farbe seines Stundenplan-Fachs, damit Stundenplan, Fächer, Hausaufgaben und Noten gleich aussehen. Die Zuordnung zum Stundenplan-Kürzel wird automatisch erkannt und kann hier korrigiert werden. Gilt auf allen Geräten.',
    hasData ? [h('div', { class: 'button-row' }, resetAll), list] : empty('Keine Fächer gefunden.'));
}

// --- Benachrichtigungen (ntfy) -------------------------------------------------------------

export function notifyGroup({ form, v, secrets }) {
  const kinds = new Set(String(v.NOTIFY).split(',').filter(Boolean));
  const url = bindText(form, 'NTFY_URL', input({ type: 'url', value: v.NTFY_URL ?? 'https://ntfy.sh' }));
  const topic = bindText(form, 'NTFY_TOPIC', input({
    id: 'ntfy-topic', value: v.NTFY_TOPIC ?? '', pattern: '[-_A-Za-z0-9]{1,64}', placeholder: 'leer = keine Benachrichtigungen',
  }));
  const token = bindText(form, 'NTFY_TOKEN', input({
    type: 'password', autocomplete: 'off', placeholder: secrets.NTFY_TOKEN ? 'unverändert' : 'optional',
  }), { secret: true });
  const appUrl = bindText(form, 'APP_URL', input({ type: 'url', value: v.APP_URL ?? '', placeholder: 'z. B. http://192.168.1.50:8080' }));
  const checks = {
    substitutions: checkbox('Vertretungen', kinds.has('substitutions')),
    homework: checkbox('Hausaufgaben', kinds.has('homework')),
    grades: checkbox('Noten', kinds.has('grades')),
  };
  form.add('server', 'NOTIFY', () => Object.entries(checks).filter(([, c]) => c.box.checked).map(([k]) => k).join(','));
  const values = bindCheck(form, 'NOTIFY_GRADE_VALUES', checkbox('Note in der Benachrichtigung anzeigen', v.NOTIFY_GRADE_VALUES));
  const generate = h('button', {
    type: 'button', class: 'button small',
    onclick: () => {
      topic.value = randomTopic();
      form.touch();
    },
  }, 'Zufälliges Thema');

  return group('benachrichtigungen', 'Benachrichtigungen',
    'Push-Nachrichten aufs Handy mit der App ntfy: dort das gleiche Thema abonnieren. Auf ntfy.sh kann jeder mitlesen, der das Thema kennt – daher einen langen Zufallsnamen verwenden.',
    field('Server', url),
    h('div', { class: 'field' },
      h('label', { for: 'ntfy-topic' }, 'Thema'),
      h('div', { class: 'inline-fields' }, topic, generate)),
    field('Zugangstoken', token, secrets.NTFY_TOKEN ? 'Leer lassen, um das gespeicherte Token zu behalten.' : 'Nur für geschützte Themen nötig.'),
    h('div', { class: 'field' }, h('span', { class: 'field-label' }, 'Benachrichtigen bei'),
      h('div', { class: 'inline-fields' }, Object.values(checks).map((c) => c.el))),
    values.el,
    field('Adresse der Web-Oberfläche', appUrl, 'Für Links in den Benachrichtigungen.'),
    h('p', { class: 'muted' }, h('a', { href: '/benachrichtigungen' }, 'Status und Testnachricht')));
}

// --- Abgleich -------------------------------------------------------------------------------

const TASKS = {
  substitutions: 'Vertretungen',
  homework: 'Hausaufgaben',
  lessons: 'Noten & Kursseiten',
  calendar: 'Kalender',
  timetable: 'Stundenplan',
  account: 'Konto',
  untis: 'WebUntis',
  meals: 'Schulessen',
};

export function syncGroup({ form, v, sync }) {
  const enabled = bindCheck(form, 'SYNC', checkbox('Daten im Hintergrund aktuell halten', v.SYNC));
  const fast = bindText(form, 'POLL_INTERVAL_MINUTES', input({ type: 'number', min: '5', max: '1440', value: v.POLL_INTERVAL_MINUTES, class: 'input narrow' }));
  const slow = bindText(form, 'GRADES_INTERVAL_MINUTES', input({ type: 'number', min: '30', max: '1440', value: v.GRADES_INTERVAL_MINUTES, class: 'input narrow' }));
  const [fromHour, toHour] = String(v.ACTIVE_HOURS).split('-');
  const from = input({ type: 'number', min: '0', max: '23', value: fromHour, class: 'input narrow', 'aria-label': 'Von (Uhr)' });
  const to = input({ type: 'number', min: '1', max: '24', value: toHour, class: 'input narrow', 'aria-label': 'Bis (Uhr)' });
  form.add('server', 'ACTIVE_HOURS', () => `${from.value}-${to.value}`);

  const status = sync?.tasks ? h('dl', { class: 'facts sync-status' },
    Object.entries(TASKS).filter(([key]) => key in sync.tasks).map(([key, label]) => {
      const t = sync.tasks[key] ?? {};
      return [h('dt', null, label), h('dd', null,
        t.lastError ? h('span', { class: 'error-text' }, t.lastError, t.lastSuccess ? ` (zuletzt erfolgreich ${age(t.lastSuccess)})` : '')
          : t.lastSuccess ? `aktualisiert ${age(t.lastSuccess)}` : h('span', { class: 'muted' }, 'noch nicht'))];
    })) : null;

  return group('abgleich', 'Abgleich',
    'Der Server lädt die Daten regelmäßig, damit die Seiten sofort angezeigt werden. Kursseiten (Noten, alle Hausaufgaben) brauchen eine Anfrage pro Kurs und werden seltener geladen.',
    enabled.el,
    field('Vertretungen und Hausaufgaben alle … Minuten', fast),
    field('Noten und Kursseiten alle … Minuten', slow),
    h('div', { class: 'field' },
      h('span', { class: 'field-label' }, 'Nur zwischen'),
      h('div', { class: 'inline-fields' }, from, h('span', null, 'und'), to, h('span', null, 'Uhr'))),
    status ? h('div', { class: 'field' }, h('span', { class: 'field-label' }, 'Stand'), status) : null);
}

// --- Web-Oberfläche: Passwort, Netzwerk ------------------------------------------------------

export function accessGroup({ form, v, desktop }) {
  // New password: only used when something is typed.
  const current = input({ type: 'password', autocomplete: 'current-password' });
  const next = input({ type: 'password', autocomplete: 'new-password', minlength: '8' });
  const repeat = input({ type: 'password', autocomplete: 'new-password', minlength: '8' });
  form.add('password', 'appPassword', () => (current.value || next.value || repeat.value ? 'typed' : ''), { secret: true });
  form.validate(() => {
    if (!(current.value || next.value || repeat.value)) return null;
    if (!current.value) return 'Zum Ändern des Passworts bitte das aktuelle Passwort eingeben.';
    if (next.value.length < 8) return 'Das neue Passwort muss mindestens 8 Zeichen haben.';
    if (next.value !== repeat.value) return 'Die beiden neuen Passwörter stimmen nicht überein.';
    return null;
  });
  form.extra(() => (next.value ? { appPassword: next.value, currentPassword: current.value } : {}));
  form.onSaved(() => {
    for (const i of [current, next, repeat]) i.value = '';
  });

  const ttl = bindText(form, 'SESSION_TTL_DAYS', input({ type: 'number', min: '1', max: '3650', value: v.SESSION_TTL_DAYS, class: 'input narrow' }));

  const local = v.HOST === '127.0.0.1' || v.HOST === 'localhost' || v.HOST === '::1';
  const name = 'host-mode';
  const onlyHere = h('input', { type: 'radio', name, value: 'local', checked: local });
  const lan = h('input', { type: 'radio', name, value: 'lan', checked: !local });
  form.add('server', 'HOST', () => (onlyHere.checked ? '127.0.0.1' : '0.0.0.0'));
  const port = bindText(form, 'PORT', input({ type: 'number', min: '1', max: '65535', value: v.PORT, class: 'input narrow' }));
  const secure = bindCheck(form, 'COOKIE_SECURE', checkbox('Nur über HTTPS (hinter einem Reverse-Proxy mit HTTPS)', v.COOKIE_SECURE));
  const proxy = bindCheck(form, 'TRUST_PROXY', checkbox('Hinter einem Reverse-Proxy (X-Forwarded-For auswerten)', v.TRUST_PROXY));
  const open = desktop ? bindCheck(form, 'OPEN_BROWSER', checkbox('Beim Start im Browser öffnen', v.OPEN_BROWSER)) : null;

  return group('netzwerk', 'Web-Oberfläche',
    'Passwort, Anmeldedauer und Erreichbarkeit. Netzwerk-Einstellungen gelten erst nach einem Neustart des Servers.',
    partLabel('Passwort ändern', 'passwort'),
    field('Aktuelles Passwort', current),
    field('Neues Passwort', next, 'Mindestens 8 Zeichen. Danach werden alle anderen Geräte abgemeldet.'),
    field('Neues Passwort wiederholen', repeat),
    partLabel('Zugang'),
    field('Anmeldung gültig für … Tage', ttl),
    h('div', { class: 'field' }, h('span', { class: 'field-label' }, 'Erreichbar'),
      h('label', { class: 'check' }, onlyHere, 'Nur auf diesem Gerät'),
      h('label', { class: 'check' }, lan, 'Auch von anderen Geräten im Netzwerk (z. B. Handy)')),
    field('Port', port),
    secure.el,
    proxy.el,
    open?.el);
}

// --- Update ---------------------------------------------------------------------------------

/** Version, release notes and installing an update; [form] disables installing with unsaved changes. */
export function updateGroup({ form, v, status }) {
  const body = h('div', { class: 'stack' });
  const msg = messageArea();
  const check = h('button', { type: 'button', class: 'button' }, 'Nach Updates suchen');
  const install = h('button', { type: 'button', class: 'button primary' }, 'Jetzt aktualisieren');
  const auto = bindCheck(form, 'UPDATE_CHECK', checkbox('Automatisch nach Updates suchen (alle 12 Stunden)', v.UPDATE_CHECK));
  const unsavedHint = h('p', { class: 'hint', hidden: true }, 'Bitte zuerst die Änderungen speichern: nach dem Update wird die Seite neu geladen.');
  let canInstall = false;

  const version = (tag) => (tag ? tag.replace(/^v/, '') : '–');
  const sync = () => {
    const dirty = form.dirty();
    install.disabled = dirty;
    unsavedHint.hidden = !(dirty && canInstall);
  };
  form.onChange(sync);

  const show = (s) => {
    const facts = h('dl', { class: 'facts' },
      h('dt', null, 'Installiert'), h('dd', null, s.current ? version(s.current) : 'Entwicklungsversion'),
      h('dt', null, 'Aktuell'), h('dd', null, s.latest
        ? [version(s.latest), s.url ? [' · ', h('a', { href: s.url, target: '_blank', rel: 'noopener' }, 'Release auf GitHub')] : '']
        : 'unbekannt'),
      h('dt', null, 'Geprüft'), h('dd', null, s.checkedAt ? age(s.checkedAt) : 'noch nicht',
        s.checkError ? h('span', { class: 'error-text' }, ` – ${s.checkError}`) : ''));
    const parts = [facts];
    if (s.available) {
      parts.push(h('div', { class: 'notice' }, h('strong', null, `Version ${version(s.latest)} ist verfügbar`),
        releaseNotes(s.notes)));
      if (s.mode === 'manual') {
        parts.push(h('p', { class: 'hint' },
          'Diese Installation kann nicht aus der Web-Oberfläche aktualisiert werden. Auf dem Server: ',
          h('code', null, 'bash /opt/gong/deploy/install.sh'),
          ' – oder die neue Version von GitHub laden.'));
      } else if (s.mode === 'systemd') {
        parts.push(h('p', { class: 'hint' },
          'Der Server lädt die neue Version, prüft sie und startet neu (etwa eine Minute). Die vorige Version bleibt für ',
          h('code', null, 'install.sh --rollback'), ' erhalten.'));
      } else {
        parts.push(h('p', { class: 'hint' }, 'Die App lädt die neue Version, prüft sie und startet neu.'));
      }
    } else if (s.latest && s.current) {
      parts.push(h('p', { class: 'muted' }, 'Diese Version ist aktuell.'));
    }
    if (s.phase === 'failed' && s.error) parts.push(h('div', { class: 'error' }, s.error));
    body.replaceChildren(...parts);
    canInstall = Boolean(s.canInstall);
    install.hidden = !canInstall;
    sync();
  };
  show(status);

  check.addEventListener('click', async () => {
    check.disabled = true;
    msg.clear();
    try {
      show(await api('/api/update/check', { method: 'POST' }));
    } catch (err) {
      msg.error(err);
    } finally {
      check.disabled = false;
    }
  });

  install.addEventListener('click', async () => {
    install.disabled = check.disabled = true;
    msg.ok('Update wird geladen …');
    try {
      await api('/api/update/install', { method: 'POST' });
      await waitForNewVersion(status.current, (text) => msg.ok(text));
    } catch (err) {
      msg.error(err instanceof ApiError ? err : new ApiError(0, 'update_failed', err.message));
      install.disabled = check.disabled = false;
      try {
        show(await api('/api/update'));
      } catch {
        // server not reachable
      }
    }
  });

  return group('update', status.available ? 'Update verfügbar' : 'Update', null,
    body, unsavedHint, auto.el, msg.el,
    h('div', { class: 'button-row' }, install, check));
}
