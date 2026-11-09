// Setup page: shown instead of the login while the server is not set up.
// Authorized by the one-time token from the setup link (?token=…).

import { api, ApiError } from '../api.js';
import { h } from '../dom.js';
import { field, input, messageArea, schoolPicker } from './forms.js';

export const title = 'Einrichtung';

const TOKEN_KEY = 'setupToken';

/** Takes the token from the address bar (and hides it there). */
export function takeToken() {
  const params = new URLSearchParams(location.search);
  const token = params.get('token');
  if (token) {
    try {
      sessionStorage.setItem(TOKEN_KEY, token);
    } catch {
      // storage unavailable: token only lives in this page
    }
    history.replaceState(null, '', '/einrichtung');
    return token;
  }
  try {
    return sessionStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

function forgetToken() {
  try {
    sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    // ignore
  }
}

/**
 * @param {{token: string | null, onDone: () => void}} options
 */
export function render({ token, onDone }) {
  document.title = 'Einrichtung – Schulportal';
  if (!token) return noToken();
  const headers = { 'x-setup-token': token };

  const school = schoolPicker({ headers });
  const username = input({ name: 'username', autocomplete: 'off', required: true, placeholder: 'vorname.nachname' });
  const sphPassword = input({ type: 'password', name: 'sph-password', autocomplete: 'off', required: true });
  const checkMsg = messageArea();
  const check = h('button', { type: 'button', class: 'button small' }, 'Anmeldung prüfen');

  const appPassword = input({ type: 'password', autocomplete: 'new-password', required: true, minlength: '8' });
  const appPassword2 = input({ type: 'password', autocomplete: 'new-password', required: true, minlength: '8' });

  const message = messageArea();
  const submit = h('button', { type: 'submit', class: 'button primary' }, 'Einrichtung abschließen');

  check.addEventListener('click', async () => {
    if (school.value == null || !username.value.trim() || !sphPassword.value) {
      checkMsg.error(new ApiError(400, 'bad_request', 'Bitte Schule, Benutzername und Passwort angeben.'));
      return;
    }
    check.disabled = true;
    checkMsg.ok('Anmeldung wird geprüft …');
    try {
      await api('/api/server-settings/test-login', {
        method: 'POST', headers,
        body: { schoolId: school.value, username: username.value.trim(), password: sphPassword.value },
      });
      checkMsg.ok('Anmeldung beim Schulportal erfolgreich.');
    } catch (err) {
      checkMsg.error(err);
    } finally {
      check.disabled = false;
    }
  });

  const form = h('form', { class: 'setup-card card' },
    h('img', { src: '/icon.svg', alt: '', class: 'login-logo' }),
    h('h1', null, 'Schulportal-Client einrichten'),
    h('p', { class: 'muted' },
      'Der Server meldet sich mit diesen Zugangsdaten beim Schulportal Hessen an und hält die Daten aktuell. ',
      'Alles lässt sich später unter Einstellungen → Server ändern.'),

    h('fieldset', null,
      h('legend', null, '1. Schule'),
      school.el),

    h('fieldset', null,
      h('legend', null, '2. Zugang zum Schulportal'),
      field('Benutzername', username),
      field('Passwort', sphPassword),
      h('div', { class: 'button-row' }, check),
      checkMsg.el),

    h('fieldset', null,
      h('legend', null, '3. Passwort für diese Web-Oberfläche'),
      field('Neues Passwort', appPassword,
        'Für die Anmeldung an dieser Web-Oberfläche (mindestens 8 Zeichen). Bitte nicht das Schulportal-Passwort verwenden.'),
      field('Passwort wiederholen', appPassword2)),

    message.el,
    submit,
  );

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    message.clear();
    if (school.value == null) {
      message.error(new ApiError(400, 'bad_request', 'Bitte eine Schule auswählen.'));
      return;
    }
    if (appPassword.value !== appPassword2.value) {
      message.error(new ApiError(400, 'bad_request', 'Die beiden Passwörter stimmen nicht überein.'));
      appPassword2.focus();
      return;
    }
    submit.disabled = true;
    submit.textContent = 'Wird eingerichtet …';
    try {
      await api('/api/server-settings', {
        method: 'PUT', headers,
        body: {
          settings: {
            SPH_SCHOOL_ID: String(school.value),
            SPH_USERNAME: username.value.trim(),
            SPH_PASSWORD: sphPassword.value,
          },
          appPassword: appPassword.value,
        },
      });
      forgetToken();
      history.replaceState(null, '', '/');
      onDone(); // the server has logged us in
    } catch (err) {
      message.error(err);
      submit.disabled = false;
      submit.textContent = 'Einrichtung abschließen';
    }
  });

  return h('main', { class: 'login' }, form);
}

/** Opened without the setup link: explain where to find it. */
function noToken() {
  return h('main', { class: 'login' },
    h('div', { class: 'setup-card card' },
      h('img', { src: '/icon.svg', alt: '', class: 'login-logo' }),
      h('h1', null, 'Einrichtung'),
      h('p', null, 'Dieser Server ist noch nicht eingerichtet. Zum Schutz funktioniert die Einrichtung nur über den Einrichtungslink:'),
      h('ul', { class: 'plain-list' },
        h('li', null, h('strong', null, 'Windows / macOS: '), 'Der Link öffnet sich beim Start des Schulportal-Clients automatisch im Browser.'),
        h('li', null, h('strong', null, 'Server (LXC): '), 'Der Link steht im Protokoll (',
          h('code', null, 'journalctl -u schulportal-client'), ') und wird von ',
          h('code', null, 'install.sh'), ' angezeigt.'))));
}
