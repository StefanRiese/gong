// Settings: the children (accounts) of this server. A child has its own
// Schulportal login (and optionally Caseda and WebUntis); everything else on
// the settings page (filter, colors, notifications) belongs to the child
// that is selected in the top bar.

import { api, ApiError } from '../api.js';
import { h } from '../dom.js';
import { loadAccounts } from '../accounts.js';
import { checkbox, field, input, messageArea, schoolPicker } from './forms.js';
import { group } from './settings-groups.js';

const changed = (detail = {}) => window.dispatchEvent(new CustomEvent('lumo:accounts-changed', { detail }));

/**
 * Fields of an account: name, Schulportal login, optional Caseda and WebUntis.
 * [account] = the stored values when editing (passwords stay unchanged when left empty).
 */
function accountFields({ account = null, defaultSchool }) {
  const name = input({ value: account?.name ?? '', maxlength: 40, placeholder: 'z. B. Vorname des Kindes' });
  const school = schoolPicker({ value: account?.schoolId ?? defaultSchool });
  const username = input({ value: account?.username ?? '', autocapitalize: 'none', spellcheck: false });
  const password = input({
    type: 'password', autocomplete: 'off', placeholder: account ? 'unverändert' : '',
  });

  const caseda = checkbox('Schulessen von Caseda anzeigen', account?.caseda);
  const casedaUser = input({ type: 'email', value: account?.caseda?.username ?? '' });
  const casedaPassword = input({
    type: 'password', autocomplete: 'off', placeholder: account?.caseda ? 'unverändert' : '',
  });
  const casedaFields = h('div', { class: 'stack' },
    field('E-Mail (Caseda-Konto)', casedaUser), field('Passwort', casedaPassword));

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
    field('Adresse von WebUntis', untisServer),
    field('Name der Schule in WebUntis', untisSchool, 'Nur nötig, wenn er nicht dem Anfang der Adresse entspricht.'),
    field('Benutzername', untisUser), field('Passwort', untisPassword));

  const toggle = (box, fields) => {
    const update = () => {
      fields.hidden = !box.box.checked;
    };
    box.box.addEventListener('change', update);
    update();
  };
  toggle(caseda, casedaFields);
  toggle(untis, untisFields);

  return {
    el: h('div', { class: 'stack' },
      field('Name', name, 'So heißt das Kind in der Auswahl oben und in Benachrichtigungen.'),
      field('Schule', school.el),
      field('Benutzername im Schulportal', username),
      field('Passwort', password, account ? 'Leer lassen, um das gespeicherte Passwort zu behalten.' : undefined),
      h('div', { class: 'part-label' }, 'Schulessen (optional)'),
      caseda.el, casedaFields,
      h('div', { class: 'part-label' }, 'WebUntis (optional)'),
      untis.el, untisFields),
    /** German problem text, or null if the input is complete. */
    problem() {
      if (!name.value.trim()) return 'Bitte einen Namen eingeben.';
      if (school.value == null) return 'Bitte die Schule wählen.';
      if (!username.value.trim()) return 'Bitte den Benutzernamen eingeben.';
      if (!account && !password.value) return 'Bitte das Passwort eingeben.';
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
          username: casedaUser.value.trim(),
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
  };
}

/** Runs [action] with a message area; [busy] is shown while it runs. */
function runAction(button, msg, busy, action) {
  return async () => {
    msg.ok(busy);
    button.disabled = true;
    try {
      await action();
    } catch (err) {
      msg.error(err);
    } finally {
      button.disabled = false;
    }
  };
}

/** Adding a child (own tab on the settings page). */
export function addChildGroup({ defaultSchool }) {
  const msg = messageArea();
  const form = accountFields({ defaultSchool });
  const add = h('button', { type: 'button', class: 'button primary' }, 'Kind hinzufügen');
  add.addEventListener('click', runAction(add, msg, 'Anmeldung wird geprüft …', async () => {
    const problem = form.problem();
    if (problem) throw new ApiError(400, 'bad_request', problem);
    const created = await api('/api/accounts', { method: 'POST', body: form.body() });
    await loadAccounts();
    // Show the new child's own tab, not this one, after the reload.
    const url = new URL(location.href);
    url.searchParams.delete('tab');
    history.replaceState(null, '', `${url.pathname}${url.search}`);
    changed({ switchTo: created.id });
  }));
  return group('kinder', 'Kind hinzufügen',
    'Jedes Kind hat eigene Zugangsdaten, eigene Daten, Filter und Farben. Oben in der Leiste wird zwischen den Kindern gewechselt. Benachrichtigungen kommen im selben ntfy-Thema mit dem Namen davor.',
    form.el,
    h('div', { class: 'button-row' }, add),
    msg.el);
}

/** Login and removal of the child that is selected (not the first account). */
export function childGroup({ account }) {
  const msg = messageArea();
  const form = accountFields({ account });
  const save = h('button', { type: 'button', class: 'button primary' }, 'Speichern');
  save.addEventListener('click', runAction(save, msg, 'Anmeldung wird geprüft …', async () => {
    const problem = form.problem();
    if (problem) throw new ApiError(400, 'bad_request', problem);
    await api(`/api/accounts/${encodeURIComponent(account.id)}`, { method: 'PUT', body: form.body() });
    await loadAccounts();
    msg.ok('Gespeichert.');
    changed();
  }));
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
  return group('konto', `Konto von ${account.name}`,
    'Mit diesen Daten meldet sich der Server für dieses Kind an. Bei einem anderen Schulportal-Konto werden die gespeicherten Daten dieses Kindes verworfen.',
    form.el,
    h('div', { class: 'button-row' }, save, remove),
    msg.el);
}

