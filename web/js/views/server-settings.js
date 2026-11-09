// Einstellungen → Server: Schulportal login, web UI password, sync,
// notifications, network. Stored on the server (database).

import { api, ApiError } from '../api.js';
import { h, icon } from '../dom.js';
import { age } from '../format.js';
import { pageHeader } from './common.js';
import { checkbox, field, input, messageArea, randomTopic, schoolPicker } from './forms.js';
import { releaseNotes, waitForNewVersion } from '../update.js';

export const title = 'Server-Einstellungen';

/** Forms: no live re-rendering (would discard unsaved input). */
export const live = false;

const TASKS = {
  substitutions: 'Vertretungen',
  homework: 'Hausaufgaben',
  lessons: 'Noten & Kursseiten',
  calendar: 'Kalender',
  timetable: 'Stundenplan',
  account: 'Konto',
};

export async function render() {
  const [settings, sync, update] = await Promise.all([
    api('/api/server-settings'),
    api('/api/sync').catch(() => null),
    api('/api/update').catch(() => null),
  ]);
  const v = settings.values;
  const restartNotice = h('div');

  const showRestart = (keys) => {
    restartNotice.replaceChildren(keys.length === 0 ? '' : h('div', { class: 'notice' },
      h('strong', null, 'Neustart nötig: '),
      'Die Netzwerk-Einstellungen gelten erst nach einem Neustart des Servers (',
      settings.desktop ? 'Symbol im Infobereich bzw. in der Menüleiste → „Neu starten“' :
        h('code', null, 'systemctl restart schulportal-client'),
      ').'));
  };
  showRestart(settings.restartRequired ?? []);

  /** Saves settings of one section; returns the server's answer. */
  const save = async (msg, button, body) => {
    msg.clear();
    button.disabled = true;
    try {
      const res = await api('/api/server-settings', { method: 'PUT', body });
      showRestart(res.restartRequired ?? []);
      msg.ok(res.accountChanged
        ? 'Gespeichert. Die Daten des neuen Kontos werden jetzt geladen.'
        : 'Gespeichert.');
      return res;
    } catch (err) {
      msg.error(err);
      return null;
    } finally {
      button.disabled = false;
    }
  };

  return h('div', null,
    h('a', { href: '/einstellungen', class: 'back-link' }, icon('back'), 'Einstellungen'),
    pageHeader('Server-Einstellungen'),
    h('p', { class: 'hint' }, 'Gelten für alle Geräte. Gespeichert auf dem Server.'),
    restartNotice,
    update ? updateSection(update, v, save) : null,
    portalSection(v, settings.secrets, save),
    passwordSection(save),
    syncSection(v, sync, save),
    notifySection(v, settings.secrets, save),
    networkSection(v, settings.desktop, save),
  );
}

function card(titleText, intro, ...content) {
  return h('section', { class: 'section' },
    h('h2', null, titleText),
    intro ? h('p', { class: 'hint' }, intro) : null,
    h('form', { class: 'card settings-form' }, content));
}

function onSubmit(form, handler) {
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    handler();
  });
  return form;
}

// --- Schulportal --------------------------------------------------------------

function portalSection(v, secrets, save) {
  const school = schoolPicker({ value: v.SPH_SCHOOL_ID });
  const username = input({ value: v.SPH_USERNAME ?? '', required: true });
  const password = input({
    type: 'password', autocomplete: 'off',
    placeholder: secrets.SPH_PASSWORD ? 'unverändert' : '',
  });
  const msg = messageArea();
  const check = h('button', { type: 'button', class: 'button' }, 'Anmeldung prüfen');
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Speichern');

  check.addEventListener('click', async () => {
    msg.ok('Anmeldung wird geprüft …');
    check.disabled = true;
    try {
      await api('/api/server-settings/test-login', {
        method: 'POST',
        body: { schoolId: school.value, username: username.value.trim(), password: password.value || undefined },
      });
      msg.ok('Anmeldung beim Schulportal erfolgreich.');
    } catch (err) {
      msg.error(err);
    } finally {
      check.disabled = false;
    }
  });

  const section = card('Schulportal-Zugang',
    'Mit diesen Daten meldet sich der Server beim Schulportal an. Bei einem anderen Konto werden die gespeicherten Daten verworfen.',
    field('Schule', school.el),
    field('Benutzername', username),
    field('Passwort', password, secrets.SPH_PASSWORD ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
    msg.el,
    h('div', { class: 'button-row' }, submit, check));
  onSubmit(section.querySelector('form'), async () => {
    const settings = { SPH_SCHOOL_ID: String(school.value), SPH_USERNAME: username.value.trim() };
    if (password.value) settings.SPH_PASSWORD = password.value;
    msg.ok('Anmeldung wird geprüft …');
    if (await save(msg, submit, { settings })) password.value = '';
  });
  return section;
}

// --- web UI password ------------------------------------------------------------

function passwordSection(save) {
  const current = input({ type: 'password', autocomplete: 'current-password', required: true });
  const next = input({ type: 'password', autocomplete: 'new-password', required: true, minlength: '8' });
  const repeat = input({ type: 'password', autocomplete: 'new-password', required: true, minlength: '8' });
  const msg = messageArea();
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Passwort ändern');
  const section = card('Passwort der Web-Oberfläche',
    'Nach der Änderung werden alle anderen Geräte abgemeldet.',
    field('Aktuelles Passwort', current),
    field('Neues Passwort', next, 'Mindestens 8 Zeichen.'),
    field('Neues Passwort wiederholen', repeat),
    msg.el,
    h('div', { class: 'button-row' }, submit));
  onSubmit(section.querySelector('form'), async () => {
    if (next.value !== repeat.value) {
      msg.error(new ApiError(400, 'bad_request', 'Die beiden neuen Passwörter stimmen nicht überein.'));
      return;
    }
    const res = await save(msg, submit, { appPassword: next.value, currentPassword: current.value });
    if (res) {
      for (const i of [current, next, repeat]) i.value = '';
      msg.ok('Passwort geändert. Andere Geräte wurden abgemeldet.');
    }
  });
  return section;
}

// --- sync -------------------------------------------------------------------------

function syncSection(v, sync, save) {
  const enabled = checkbox('Daten im Hintergrund aktuell halten', v.SYNC);
  const fast = input({ type: 'number', min: '5', max: '1440', value: v.POLL_INTERVAL_MINUTES, class: 'input narrow' });
  const slow = input({ type: 'number', min: '30', max: '1440', value: v.GRADES_INTERVAL_MINUTES, class: 'input narrow' });
  const [fromHour, toHour] = String(v.ACTIVE_HOURS).split('-');
  const from = input({ type: 'number', min: '0', max: '23', value: fromHour, class: 'input narrow', 'aria-label': 'Von (Uhr)' });
  const to = input({ type: 'number', min: '1', max: '24', value: toHour, class: 'input narrow', 'aria-label': 'Bis (Uhr)' });
  const msg = messageArea();
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Speichern');

  const status = sync?.tasks ? h('dl', { class: 'facts sync-status' },
    Object.entries(TASKS).map(([key, label]) => {
      const t = sync.tasks[key] ?? {};
      return [h('dt', null, label), h('dd', null,
        t.lastError ? h('span', { class: 'error-text' }, t.lastError, t.lastSuccess ? ` (zuletzt erfolgreich ${age(t.lastSuccess)})` : '')
          : t.lastSuccess ? `aktualisiert ${age(t.lastSuccess)}` : h('span', { class: 'muted' }, 'noch nicht'))];
    })) : null;

  const section = card('Abgleich mit dem Schulportal',
    'Der Server lädt die Daten regelmäßig, damit die Seiten sofort angezeigt werden. Kursseiten (Noten, alle Hausaufgaben) brauchen eine Anfrage pro Kurs und werden seltener geladen.',
    enabled.el,
    field('Vertretungen und Hausaufgaben alle … Minuten', fast),
    field('Noten und Kursseiten alle … Minuten', slow),
    h('div', { class: 'field' },
      h('span', { class: 'field-label' }, 'Nur zwischen'),
      h('div', { class: 'inline-fields' }, from, h('span', null, 'und'), to, h('span', null, 'Uhr'))),
    status ? h('div', { class: 'field' }, h('span', { class: 'field-label' }, 'Stand'), status) : null,
    msg.el,
    h('div', { class: 'button-row' }, submit));
  onSubmit(section.querySelector('form'), () => save(msg, submit, {
    settings: {
      SYNC: String(enabled.box.checked),
      POLL_INTERVAL_MINUTES: fast.value,
      GRADES_INTERVAL_MINUTES: slow.value,
      ACTIVE_HOURS: `${from.value}-${to.value}`,
    },
  }));
  return section;
}

// --- notifications ------------------------------------------------------------------

function notifySection(v, secrets, save) {
  const kinds = new Set(String(v.NOTIFY).split(',').filter(Boolean));
  const url = input({ type: 'url', value: v.NTFY_URL ?? 'https://ntfy.sh' });
  const topic = input({ value: v.NTFY_TOPIC ?? '', pattern: '[-_A-Za-z0-9]{1,64}', placeholder: 'leer = keine Benachrichtigungen' });
  const token = input({ type: 'password', autocomplete: 'off', placeholder: secrets.NTFY_TOKEN ? 'unverändert' : 'optional' });
  const appUrl = input({ type: 'url', value: v.APP_URL ?? '', placeholder: 'z. B. http://192.168.1.50:8080' });
  const checks = {
    substitutions: checkbox('Vertretungen', kinds.has('substitutions')),
    homework: checkbox('Hausaufgaben', kinds.has('homework')),
    grades: checkbox('Noten', kinds.has('grades')),
  };
  const values = checkbox('Note in der Benachrichtigung anzeigen', v.NOTIFY_GRADE_VALUES);
  const msg = messageArea();
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Speichern');
  const generate = h('button', {
    type: 'button', class: 'button small',
    onclick: () => {
      topic.value = randomTopic();
    },
  }, 'Zufälliges Thema');

  const section = card('Benachrichtigungen (ntfy)',
    'Push-Nachrichten aufs Handy mit der App ntfy: dort das gleiche Thema abonnieren. Auf ntfy.sh kann jeder mitlesen, der das Thema kennt – daher einen langen Zufallsnamen verwenden.',
    field('Server', url),
    h('div', { class: 'field' },
      h('label', { for: topic.id || (topic.id = 'ntfy-topic') }, 'Thema'),
      h('div', { class: 'inline-fields' }, topic, generate)),
    field('Zugangstoken', token, secrets.NTFY_TOKEN ? 'Leer lassen, um das gespeicherte Token zu behalten.' : 'Nur für geschützte Themen nötig.'),
    h('div', { class: 'field' }, h('span', { class: 'field-label' }, 'Benachrichtigen bei'),
      h('div', { class: 'inline-fields' }, Object.values(checks).map((c) => c.el))),
    values.el,
    field('Adresse der Web-Oberfläche', appUrl, 'Für Links in den Benachrichtigungen.'),
    h('p', { class: 'muted' }, h('a', { href: '/benachrichtigungen' }, 'Status und Testnachricht')),
    msg.el,
    h('div', { class: 'button-row' }, submit));
  onSubmit(section.querySelector('form'), () => {
    const settings = {
      NTFY_URL: url.value.trim(),
      NTFY_TOPIC: topic.value.trim(),
      NOTIFY: Object.entries(checks).filter(([, c]) => c.box.checked).map(([k]) => k).join(','),
      NOTIFY_GRADE_VALUES: String(values.box.checked),
      APP_URL: appUrl.value.trim(),
    };
    if (token.value) settings.NTFY_TOKEN = token.value;
    return save(msg, submit, { settings });
  });
  return section;
}

// --- network ----------------------------------------------------------------------------

function networkSection(v, desktop, save) {
  const local = v.HOST === '127.0.0.1' || v.HOST === 'localhost' || v.HOST === '::1';
  const name = 'host-mode';
  const onlyHere = h('input', { type: 'radio', name, value: 'local', checked: local });
  const lan = h('input', { type: 'radio', name, value: 'lan', checked: !local });
  const port = input({ type: 'number', min: '1', max: '65535', value: v.PORT, class: 'input narrow' });
  const ttl = input({ type: 'number', min: '1', max: '3650', value: v.SESSION_TTL_DAYS, class: 'input narrow' });
  const open = checkbox('Beim Start im Browser öffnen', v.OPEN_BROWSER);
  const secure = checkbox('Nur über HTTPS (hinter einem Reverse-Proxy mit HTTPS)', v.COOKIE_SECURE);
  const proxy = checkbox('Hinter einem Reverse-Proxy (X-Forwarded-For auswerten)', v.TRUST_PROXY);
  const msg = messageArea();
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Speichern');

  const section = card('Netzwerk',
    'Änderungen gelten erst nach einem Neustart des Servers.',
    h('div', { class: 'field' }, h('span', { class: 'field-label' }, 'Erreichbar'),
      h('label', { class: 'check' }, onlyHere, 'Nur auf diesem Gerät'),
      h('label', { class: 'check' }, lan, 'Auch von anderen Geräten im Netzwerk (z. B. Handy)')),
    field('Port', port),
    field('Anmeldung gültig für … Tage', ttl),
    desktop ? open.el : null,
    h('details', null, h('summary', null, 'Erweitert'), secure.el, proxy.el),
    msg.el,
    h('div', { class: 'button-row' }, submit));
  onSubmit(section.querySelector('form'), () => {
    const settings = {
      HOST: onlyHere.checked ? '127.0.0.1' : '0.0.0.0',
      PORT: port.value,
      SESSION_TTL_DAYS: ttl.value,
      COOKIE_SECURE: String(secure.box.checked),
      TRUST_PROXY: String(proxy.box.checked),
    };
    if (desktop) settings.OPEN_BROWSER = String(open.box.checked);
    return save(msg, submit, { settings });
  });
  return section;
}

// --- update ---------------------------------------------------------------------------

function updateSection(status, v, save) {
  const body = h('div', { class: 'stack' });
  const msg = messageArea();
  const check = h('button', { type: 'button', class: 'button' }, 'Nach Updates suchen');
  const install = h('button', { type: 'button', class: 'button primary' }, 'Jetzt aktualisieren');
  const auto = checkbox('Automatisch nach Updates suchen (alle 12 Stunden)', v.UPDATE_CHECK);

  const version = (tag) => (tag ? tag.replace(/^v/, '') : '–');

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
          h('code', null, 'bash /opt/schulportal-client/deploy/install.sh'),
          ' – oder die neue Version von GitHub laden.'));
      } else if (s.mode === 'systemd') {
        parts.push(h('p', { class: 'hint' },
          'Der Server lädt die neue Version, prüft sie und startet neu (etwa eine Minute). Die vorige Version bleibt für ',
          h('code', null, 'install.sh --rollback'), ' erhalten.'));
      } else {
        parts.push(h('p', { class: 'hint' },
          'Die App lädt die neue Version, prüft sie und startet neu.'));
      }
    } else if (s.latest && s.current) {
      parts.push(h('p', { class: 'muted' }, 'Diese Version ist aktuell.'));
    }
    if (s.phase === 'failed' && s.error) parts.push(h('div', { class: 'error' }, s.error));
    body.replaceChildren(...parts);
    install.hidden = !s.canInstall;
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

  auto.box.addEventListener('change', () => save(msg, check, { settings: { UPDATE_CHECK: String(auto.box.checked) } }));

  return h('section', { class: 'section', id: 'update' },
    h('h2', null, 'Update'),
    h('div', { class: 'card settings-form' },
      body, auto.el, msg.el,
      h('div', { class: 'button-row' }, install, check)));
}
