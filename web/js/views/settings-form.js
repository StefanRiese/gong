// Registry of everything the settings page can save: one form, one save
// button. Every control registers how to read its value; the page compares
// the current values with the ones at load (or at the last save) and sends
// only what changed – so settings that come from config.env are not pinned
// into the database by an unrelated save.

/**
 * @typedef {'server' | 'personal' | 'password'} Scope
 *  server: PUT /api/server-settings (values are strings),
 *  personal: PUT /api/settings (values are JSON strings),
 *  password: new web UI password (only used to detect typing).
 */

export function createForm() {
  /** @type {{scope: Scope, key: string, read: () => string, secret: boolean, initial: string}[]} */
  const entries = [];
  const listeners = [];
  const validators = [];
  const extras = [];
  const afterSave = [];

  return {
    /** Called whenever a value may have changed. */
    onChange(fn) {
      listeners.push(fn);
    },
    touch() {
      for (const fn of listeners) fn();
    },

    /**
     * Registers a setting. [read] returns its current value as a string;
     * a [secret] (password, token) is never prefilled and counts as changed
     * as soon as something is typed.
     * @param {Scope} scope
     */
    add(scope, key, read, { secret = false } = {}) {
      entries.push({ scope, key, read, secret, initial: secret ? '' : read() });
    },

    /** Changed values of [scope] (all scopes without argument): {key: value}. */
    changed(scope) {
      const out = {};
      for (const e of entries) {
        if (scope && e.scope !== scope) continue;
        const now = e.read();
        if (now !== e.initial) out[e.key] = now;
      }
      return out;
    },
    dirty() {
      return entries.some((e) => e.read() !== e.initial);
    },
    /** Takes the current values as the saved ones. */
    commit() {
      for (const e of entries) e.initial = e.secret ? '' : e.read();
      for (const fn of afterSave) fn();
    },

    /** [fn] returns a German problem text, or null if the input is fine. */
    validate(fn) {
      validators.push(fn);
    },
    firstProblem() {
      for (const fn of validators) {
        const problem = fn();
        if (problem) return problem;
      }
      return null;
    },

    /** [fn] returns extra fields for the server settings request. */
    extra(fn) {
      extras.push(fn);
    },
    extraBody() {
      return Object.assign({}, ...extras.map((fn) => fn()));
    },

    /** [fn] runs after a successful save (e.g. clears password fields). */
    onSaved(fn) {
      afterSave.push(fn);
    },
  };
}

/** Registers a text input as server setting [key]; returns the input. */
export function bindText(form, key, el, { secret = false } = {}) {
  form.add('server', key, () => (secret ? el.value : el.value.trim()), { secret });
  return el;
}

/** Registers a checkbox ({box, el} from forms.js) as boolean server setting. */
export function bindCheck(form, key, c) {
  form.add('server', key, () => String(c.box.checked));
  return c;
}

/** Stable JSON of an object (sorted keys, sorted arrays) to compare values. */
export function stable(value) {
  const norm = (x) => {
    if (Array.isArray(x)) return x.map(norm).sort();
    if (x && typeof x === 'object') {
      return Object.fromEntries(Object.entries(x).sort(([a], [b]) => a.localeCompare(b)).map(([k, val]) => [k, norm(val)]));
    }
    return x;
  };
  return JSON.stringify(norm(value));
}
