// Several children: the accounts of the server and the one shown right now.
// The choice is remembered per browser; links from notifications carry it
// as ?konto=<id>.

import { api, setAccount } from './api.js';
import { h } from './dom.js';

const KEY = 'lumo.account';

/** @type {{id: string, name: string, schoolId?: number, username?: string, caseda?: any, untis?: any}[]} */
export let accounts = [];

/** Id of the account shown right now. */
export let current = '';

function saved() {
  try {
    return localStorage.getItem(KEY);
  } catch {
    return null;
  }
}

function remember(id) {
  try {
    localStorage.setItem(KEY, id);
  } catch {
    // storage unavailable
  }
}

/** Loads the account list of the server. */
export async function loadAccounts() {
  accounts = (await api('/api/accounts')).accounts;
  return accounts;
}

/** Name of an account for texts. */
export function nameOf(id) {
  return accounts.find((a) => a.id === id)?.name ?? '';
}

/**
 * Selects the account to show: the one of a ?konto= link, else the one used
 * last in this browser, else the first. Call after [loadAccounts].
 */
export function pickAccount() {
  const params = new URLSearchParams(location.search);
  const linked = params.get('konto');
  if (linked !== null) {
    params.delete('konto');
    const query = params.toString();
    history.replaceState(null, '', `${location.pathname}${query ? `?${query}` : ''}${location.hash}`);
  }
  const id = [linked, saved(), current].find((c) => c && accounts.some((a) => a.id === c)) ?? accounts[0]?.id ?? '';
  use(id);
  return id;
}

function use(id) {
  current = id;
  setAccount(id || null);
  if (id) remember(id);
}

/** Switches to [id] (the caller reloads the page content). */
export function switchTo(id) {
  if (accounts.some((a) => a.id === id)) use(id);
}

/** Drop-down in the top bar; null while there is only one account. */
export function accountSwitcher(onSwitch) {
  if (accounts.length < 2) return null;
  return h('select', {
    class: 'account-switch', 'aria-label': 'Kind wählen', title: 'Kind wählen',
    onchange: (e) => onSwitch(e.target.value),
  }, accounts.map((a) => h('option', { value: a.id, selected: a.id === current }, a.name)));
}
