// Color scheme of the web UI (per device): "blau" (default) or "lumo" (indigo,
// like the app icon). Light and dark mode follow the device in both.

const KEY = 'lumo-scheme';

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

/** Sets the scheme on the page; [save] remembers it on this device. */
export function setScheme(id, save = true) {
  const scheme = SCHEMES.some((s) => s.id === id) ? id : 'blau';
  if (scheme === 'blau') delete document.documentElement.dataset.scheme;
  else document.documentElement.dataset.scheme = scheme;
  const [light, dark] = BAR[scheme];
  const metas = document.querySelectorAll('meta[name="theme-color"]');
  for (const m of metas) {
    m.setAttribute('content', m.media.includes('dark') ? dark : light);
  }
  if (save) {
    try {
      if (scheme === 'blau') localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, scheme);
    } catch {
      // Private mode: only for this visit.
    }
  }
}

export function initScheme() {
  setScheme(getScheme(), false);
}
