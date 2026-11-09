// Subject colors: user-defined (server settings) or derived from the name.

/** Distinct colors that work as accents in light and dark mode. */
const PALETTE = [
  '#3b6fd8', // blue
  '#e03131', // red
  '#2f9e44', // green
  '#f08c00', // orange
  '#9c36b5', // purple
  '#0c8599', // teal
  '#d6336c', // pink
  '#5c4fd6', // indigo
  '#74b816', // lime
  '#a0522d', // brown
  '#1098ad', // cyan
  '#e8590c', // vermilion
  '#fab005', // yellow
  '#087f5b', // dark green
  '#364fc7', // dark indigo
  '#be4bdb', // grape
];

let custom = {};
let assigned = {};

function hashOf(name) {
  let hash = 0;
  for (const ch of String(name).trim().toLowerCase()) {
    hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
  }
  return hash;
}

/**
 * Gives the known subjects distinct automatic colors (as long as there are no
 * more subjects than palette colors). Each subject starts at its hash slot and
 * takes the next free one, so the result only depends on the set of subjects.
 */
export function assignAutoColors(names) {
  const unique = [...new Set(names.map((n) => n?.trim()).filter(Boolean))]
    .sort((a, b) => a.localeCompare(b, 'de'));
  const used = new Set();
  assigned = {};
  for (const name of unique) {
    let slot = hashOf(name) % PALETTE.length;
    for (let i = 0; i < PALETTE.length && used.has(slot); i++) {
      slot = (slot + 1) % PALETTE.length;
    }
    if (used.size >= PALETTE.length) used.clear(); // more subjects than colors
    used.add(slot);
    assigned[name] = PALETTE[slot];
  }
}

/** Replaces the user-defined colors (subject → "#rrggbb"). */
export function setSubjectColors(map) {
  custom = { ...(map ?? {}) };
}

export function getSubjectColors() {
  return { ...custom };
}

/** Automatic color: distinct per known subject, otherwise from the name. */
export function autoColor(name) {
  const key = String(name).trim();
  return assigned[key] ?? PALETTE[hashOf(key) % PALETTE.length];
}

/** Color for a subject, or null without a name. */
export function subjectColor(name) {
  const key = name?.trim();
  if (!key) return null;
  return custom[key] ?? autoColor(key);
}

/** Inline style for h(): sets the CSS variable --subject (CSP-safe via CSSOM). */
export function subjectStyle(name) {
  const color = subjectColor(name);
  return color ? { '--subject': color } : null;
}
