// Color scheme of the web UI (per device): "blau" (default) or "lumo" (indigo,
// like the app icon). Light or dark follows the device until it is switched by hand
// (button in the top bar).

const KEY = 'lumo-scheme';
const MODE_KEY = 'lumo-mode';

export const SCHEMES = [
  { id: 'blau', label: 'Blau' },
  { id: 'lumo', label: 'Lumo (Indigo)' },
];

/** Browser bar colors (light, dark) per scheme. */
const BAR = {
  blau: ['#1d5bb8', '#14181f'],
  lumo: ['#2b3a8c', '#0e0f13'],
};

export function getScheme() {
  try {
    const v = localStorage.getItem(KEY);
    return SCHEMES.some((s) => s.id === v) ? v : 'blau';
  } catch {
    return 'blau';
  }
}

function read(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function write(key, value) {
  try {
    if (value == null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Private mode: only for this visit.
  }
}

/** "light", "dark" (switched by hand) or null (follows the device). */
export function getMode() {
  const v = read(MODE_KEY);
  return v === 'light' || v === 'dark' ? v : null;
}

const darkQuery = window.matchMedia?.('(prefers-color-scheme: dark)');

/** True if the page is shown dark right now. */
export function isDark() {
  return (getMode() ?? (darkQuery?.matches ? 'dark' : 'light')) === 'dark';
}

function apply() {
  const root = document.documentElement;
  const scheme = getScheme();
  const mode = getMode();
  if (scheme === 'blau') delete root.dataset.scheme;
  else root.dataset.scheme = scheme;
  if (mode) root.dataset.theme = mode;
  else delete root.dataset.theme;
  const [light, dark] = BAR[scheme];
  for (const m of document.querySelectorAll('meta[name="theme-color"]')) {
    const forDark = mode ? mode === 'dark' : m.media.includes('dark');
    m.setAttribute('content', forDark ? dark : light);
  }
  window.dispatchEvent(new Event('lumo:theme'));
}

/** Sets the scheme on the page and remembers it on this device. */
export function setScheme(id) {
  const scheme = SCHEMES.some((s) => s.id === id) ? id : 'blau';
  write(KEY, scheme === 'blau' ? null : scheme);
  apply();
}

/** Switches between light and dark by hand and remembers it. */
export function toggleMode() {
  write(MODE_KEY, isDark() ? 'light' : 'dark');
  apply();
}

export function initScheme() {
  apply();
  darkQuery?.addEventListener?.('change', () => {
    if (!getMode()) apply();
  });
}
