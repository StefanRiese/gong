// Settings: the accounts (children). Every account has the same form: name,
// Schulportal login, optionally Caseda (school meals) and WebUntis. On the
// settings page the form of the shown account is saved with the page's save
// button; a new child is added with its own button on the "+ Kind" tab.

import { api, ApiError } from '../api.js';
import { h } from '../dom.js';
import { accounts, loadAccounts } from '../accounts.js';
import { checkbox, field, input, messageArea, schoolPicker } from './forms.js';
import { group } from './settings-groups.js';
import { stable } from './settings-form.js';

const DEFAULT_CASEDA = 'https://www.caseda-schulmenue.de';

const changed = (detail = {}) => window.dispatchEvent(new CustomEvent('lumo:accounts-changed', { detail }));

/**
 * The fields of an account. [account] = the stored values when editing (a password
 * left empty stays as it is on the server); null for a new account.
 */
function accountFields({ account = null, defaultSchool, onChange = () => {} }) {
  const name = input({ value: account?.name ?? '', maxlength: 40, placeholder: 'Standard: der Benutzername' });
  const school = schoolPicker({ value: account?.schoolId ?? defaultSchool, onChange });
  const username = input({ value: account?.username ?? '', autocapitalize: 'none', spellcheck: false });
  const password = input({
    type: 'password', autocomplete: 'off', placeholder: account ? 'unverändert' : '',
  });

  const caseda = checkbox('Schulessen von Caseda anzeigen (Guthaben und eigene Bestellungen)', account?.caseda);
  const casedaUser = input({ type: 'email', value: account?.caseda?.username ?? '' });
  const casedaPassword = input({
    type: 'password', autocomplete: 'off', placeholder: account?.caseda ? 'unverändert' : '',
  });
  const casedaUrl = input({ type: 'url', value: account?.caseda?.url ?? DEFAULT_CASEDA });
  const casedaFields = h('div', { class: 'stack' },
    field('E-Mail (Caseda-Konto)', casedaUser),
    field('Passwort', casedaPassword, account?.caseda ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
    field('Adresse des Bestellsystems', casedaUrl, 'Andere Caterer mit schulmenueplaner.de funktionieren ebenso.'));

  const untis = checkbox('WebUntis als zweite Quelle für Vertretungen nutzen', account?.untis);
  const untisServer = input({
    value: account?.untis?.server ?? '', placeholder: 'meineschule.webuntis.com', autocapitalize: 'none', spellcheck: false,
  });
  const untisSchool = input({ value: account?.untis?.school ?? '', placeholder: 'wie vor „.webuntis.com“' });
  const untisUser = input({ value: account?.untis?.username ?? '' });
  const untisPassword = input({
    type: 'password', autocomplete: 'off', placeholder: account?.untis ? 'unverändert' : '',
  });
  const untisFields = h('div', { class: 'stack' },
    field('Adresse von WebUntis', untisServer, 'Die Adresse der Webseite genügt, z. B. aus dem Browser kopiert.'),
    field('Name der Schule in WebUntis', untisSchool, 'Nur nötig, wenn er nicht dem Anfang der Adresse entspricht.'),
    field('Benutzername', untisUser),
    field('Passwort', untisPassword, account?.untis ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined));

  const showWhenOn = (box, fields) => {
    const update = () => {
      fields.hidden = !box.box.checked;
    };
    box.box.addEventListener('change', update);
    update();
  };
  showWhenOn(caseda, casedaFields);
  showWhenOn(untis, untisFields);

  const passwords = [password, casedaPassword, untisPassword];
  return {
    el: h('div', { class: 'stack' },
      field('Name', name, 'So heißt das Kind in der Auswahl oben und in Benachrichtigungen.'),
      field('Schule', school.el),
      field('Benutzername im Schulportal', username),
      field('Passwort', password, account ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
      h('div', { class: 'part-label', id: 'schulessen' }, 'Schulessen (optional)'),
      caseda.el, casedaFields,
      h('div', { class: 'part-label', id: 'webuntis' }, 'WebUntis (optional)'),
      untis.el, untisFields),

    /** German problem text, or null if the input is complete. */
    problem() {
      if (school.value == null) return 'Bitte die Schule wählen.';
      if (!username.value.trim()) return 'Bitte den Benutzernamen eingeben.';
      if (!account && !password.value) return 'Bitte das Passwort eingeben.';
      if (account && !password.value
        && (username.value.trim() !== account.username || school.value !== account.schoolId)) {
        return 'Bei einer anderen Schule oder einem anderen Benutzernamen bitte auch das Passwort eingeben.';
      }
      if (caseda.box.checked && (!casedaUser.value.trim() || (!account?.caseda && !casedaPassword.value))) {
        return 'Für das Schulessen werden E-Mail und Passwort des Caseda-Kontos gebraucht.';
      }
      if (untis.box.checked && (!untisServer.value.trim() || !untisUser.value.trim() || (!account?.untis && !untisPassword.value))) {
        return 'Für WebUntis werden Adresse, Benutzername und Passwort gebraucht.';
      }
      return null;
    },

    /** Request body; empty passwords are left out (the server keeps the stored ones). */
    body() {
      const body = {
        name: name.value.trim(), schoolId: school.value, username: username.value.trim(),
        ...(password.value ? { password: password.value } : {}),
      };
      body.caseda = caseda.box.checked
        ? {
          username: casedaUser.value.trim(), url: casedaUrl.value.trim() || DEFAULT_CASEDA,
          ...(casedaPassword.value ? { password: casedaPassword.value } : {}),
        }
        : null;
      body.untis = untis.box.checked
        ? {
          server: untisServer.value.trim(), username: untisUser.value.trim(),
          ...(untisSchool.value.trim() ? { school: untisSchool.value.trim() } : {}),
          ...(untisPassword.value ? { password: untisPassword.value } : {}),
        }
        : null;
      return body;
    },

    /** Lets the settings page's save button handle these fields. */
    register(form) {
      form.add('account', 'fields', () => stable({
        name: name.value.trim(), schoolId: school.value, username: username.value.trim(),
        caseda: caseda.box.checked ? { user: casedaUser.value.trim(), url: casedaUrl.value.trim() } : null,
        untis: untis.box.checked
          ? { server: untisServer.value.trim(), school: untisSchool.value.trim(), user: untisUser.value.trim() }
          : null,
      }));
      form.add('account', 'passwords', () => passwords.map((i) => i.value).join(''), { secret: true });
      form.validate(() => this.problem());
      form.onSaved(() => {
        for (const i of passwords) i.value = '';
      });
    },
  };
}

/**
 * The shown account: its logins (saved with the page's save button) and, if there are
 * several accounts, removing it.
 * @returns {{el: HTMLElement, body: () => object}}
 */
export function accountGroup({ form, account }) {
  const fields = accountFields({ account, onChange: () => form.touch() });
  fields.register(form);
  const msg = messageArea();
  const remove = h('button', { type: 'button', class: 'button danger' }, 'Kind entfernen');
  remove.addEventListener('click', async () => {
    if (!confirm(`„${account.name}“ entfernen? Die gespeicherten Daten, Filter und Farben dieses Kindes werden gelöscht. Das Schulportal-Konto selbst bleibt unberührt.`)) return;
    remove.disabled = true;
    try {
      await api(`/api/accounts/${encodeURIComponent(account.id)}`, { method: 'DELETE' });
      await loadAccounts();
      changed();
    } catch (err) {
      remove.disabled = false;
      msg.error(err);
    }
  });
  return {
    el: group('konto', 'Schulportal',
      'Mit diesen Daten meldet sich der Server für dieses Kind an. Bei einem anderen Schulportal-Konto werden die gespeicherten Daten dieses Kindes verworfen.',
      fields.el,
      accounts.length > 1 ? h('div', { class: 'button-row' }, remove) : null,
      msg.el),
    body: () => fields.body(),
  };
}

/** Adding a child (own tab on the settings page). */
export function addChildGroup({ defaultSchool }) {
  const msg = messageArea();
  const form = accountFields({ defaultSchool });
  const add = h('button', { type: 'button', class: 'button primary' }, 'Kind hinzufügen');
  add.addEventListener('click', async () => {
    msg.ok('Anmeldung wird geprüft …');
    add.disabled = true;
    try {
      const problem = form.problem();
      if (problem) throw new ApiError(400, 'bad_request', problem);
      const created = await api('/api/accounts', { method: 'POST', body: form.body() });
      await loadAccounts();
      // Show the new child's own tab, not this one, after the reload.
      const url = new URL(location.href);
      url.searchParams.delete('tab');
      history.replaceState(null, '', `${url.pathname}${url.search}`);
      changed({ switchTo: created.id });
    } catch (err) {
      msg.error(err);
    } finally {
      add.disabled = false;
    }
  });
  return group('kinder', 'Kind hinzufügen',
    'Jedes Kind hat eigene Zugangsdaten, eigene Daten, Filter und Farben. Oben in der Leiste wird zwischen den Kindern gewechselt. Benachrichtigungen kommen im selben ntfy-Thema mit dem Namen davor.',
    form.el,
    h('div', { class: 'button-row' }, add),
    msg.el);
}
