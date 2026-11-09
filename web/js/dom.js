// DOM helpers. All text goes through text nodes — never innerHTML — so data
// from Schulportal cannot inject markup or scripts.

const SVG_NS = 'http://www.w3.org/2000/svg';
const SAFE_URL = /^(\/(?!\/)|https?:\/\/|mailto:)/i;

/**
 * Creates an element.
 * @param {string} tag
 * @param {Record<string, any> | null} [props] class, on<event>, dataset, style, attributes
 * @param {...any} children strings, numbers, nodes, arrays; null/false are skipped
 * @returns {HTMLElement}
 */
export function h(tag, props, ...children) {
  const el = document.createElement(tag);
  applyProps(el, props);
  append(el, children);
  return el;
}

/** Appends children (strings become text nodes). */
export function append(el, children) {
  for (const c of [children].flat(Infinity)) {
    if (c == null || c === false || c === '') continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function applyProps(el, props) {
  if (!props) return;
  for (const [key, value] of Object.entries(props)) {
    if (value == null || value === false) continue;
    if (key === 'class') {
      el.className = Array.isArray(value) ? value.filter(Boolean).join(' ') : value;
    } else if (key.startsWith('on') && typeof value === 'function') {
      el.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (key === 'dataset') {
      Object.assign(el.dataset, value);
    } else if (key === 'style') {
      for (const [prop, v] of Object.entries(value)) el.style.setProperty(prop, String(v));
    } else if (key === 'href' || key === 'src') {
      const url = String(value);
      if (SAFE_URL.test(url)) el.setAttribute(key, url);
    } else if (value === true) {
      el.setAttribute(key, '');
    } else {
      el.setAttribute(key, String(value));
    }
  }
}

/**
 * Converts an HTML fragment from Schulportal to plain text, keeping line
 * breaks. DOMParser does not execute scripts or load resources.
 */
export function htmlToText(html) {
  if (html == null) return '';
  const withBreaks = String(html)
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|tr)>/gi, '\n');
  const doc = new DOMParser().parseFromString(withBreaks, 'text/html');
  return (doc.body.textContent ?? '')
    .split('\n')
    .map((line) => line.replace(/[ \t ]+/g, ' ').trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** Multi-line text block (keeps line breaks via CSS). */
export function textBlock(text, cls = 'text') {
  const t = htmlToText(text);
  return t ? h('p', { class: cls }, t) : null;
}

const ICONS = {
  today: 'M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z',
  timetable: 'M4 5h16v15H4zM4 10h16M9 10v10M15 10v10M8 3v4M16 3v4',
  substitutions: 'M4 7h13l-3-3M20 17H7l3 3',
  homework: 'M6 3h9l4 4v14H6zM14 3v5h5M9 13h7M9 17h5',
  grades: 'M12 3l2.6 5.6 6 .6-4.5 4 1.3 6L12 16.2 6.6 19.2l1.3-6-4.5-4 6-.6z',
  calendar: 'M4 6h16v14H4zM4 10h16M8 3v5M16 3v5M8 14h2M12 14h2M16 14h0',
  refresh: 'M20 11a8 8 0 0 0-14.6-4.5L4 8M4 4v4h4M4 13a8 8 0 0 0 14.6 4.5L20 16M20 20v-4h-4',
  logout: 'M15 4h4v16h-4M10 8l-4 4 4 4M6 12h10',
  back: 'M15 5l-7 7 7 7',
  prev: 'M15 5l-7 7 7 7',
  next: 'M9 5l7 7-7 7',
};

/** Inline SVG icon (stroke style). */
export function icon(name) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('class', 'icon');
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', ICONS[name] ?? '');
  svg.append(path);
  return svg;
}

/** Empty-state message. */
export function empty(text) {
  return h('p', { class: 'empty' }, text);
}

/** Error message box. */
export function errorBox(message) {
  return h('div', { class: 'error', role: 'alert' }, message);
}
