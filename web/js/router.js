// Minimal history-based router.

/** @type {{pattern: RegExp, keys: string[], view: any}[]} */
const routes = [];
let onChange = () => {};

/**
 * Registers a route like "/kurse/:id".
 * @param {string} path
 * @param {any} view
 */
export function route(path, view) {
  const keys = [];
  const source = path.replace(/:([a-zA-Z]+)/g, (_, key) => {
    keys.push(key);
    return '([^/]+)';
  });
  routes.push({ pattern: new RegExp(`^${source}/?$`), keys, view });
}

/** Finds the view for a pathname. */
export function match(pathname) {
  for (const r of routes) {
    const m = r.pattern.exec(pathname);
    if (m) {
      const params = {};
      r.keys.forEach((k, i) => (params[k] = decodeURIComponent(m[i + 1])));
      return { view: r.view, params };
    }
  }
  return null;
}

export function navigate(path, { replace = false } = {}) {
  if (path !== location.pathname + location.search) {
    history[replace ? 'replaceState' : 'pushState'](null, '', path);
  }
  onChange();
}

/** Starts listening for link clicks and back/forward navigation. */
export function startRouter(callback) {
  onChange = callback;
  window.addEventListener('popstate', () => onChange());
  document.addEventListener('click', (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) {
      return;
    }
    const a = e.target instanceof Element ? e.target.closest('a[href]') : null;
    if (!a || a.target || a.hasAttribute('download')) return;
    const url = new URL(a.href);
    if (url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
    e.preventDefault();
    navigate(url.pathname + url.search);
  });
}
