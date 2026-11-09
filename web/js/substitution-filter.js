// Helpers for filtering the substitution plan (same rules as the server's
// SubstitutionFilter in server/lib/src/storage/settings_store.dart).

/** Classes of an entry: "05aG, 05bG" / "05kF?05aG" → ["05aG", "05bG"]. */
export function classesOf(className) {
  return (className ?? '').split(/[,;?/]+/).map((c) => c.trim()).filter(Boolean);
}

/** All classes, types and notice headings that occur in a plan. */
export function planValues(days) {
  const classes = new Set();
  const types = new Set();
  const notices = new Set();
  for (const d of days) {
    for (const e of d.entries) {
      for (const c of classesOf(e.className)) classes.add(c);
      if (e.type?.trim()) types.add(e.type.trim());
    }
    for (const n of d.notices) if (n.title?.trim()) notices.add(n.title.trim());
  }
  const byName = (a, b) => a.localeCompare(b, 'de');
  return {
    classes: sortClasses([...classes]),
    types: [...types].sort(byName),
    notices: [...notices].sort(byName),
  };
}

/** "05aG" < "05bG" < "10aG" < "Ea" < "Q12": numbers first, numerically. */
export function sortClasses(list) {
  return [...list].sort((a, b) => a.localeCompare(b, 'de', { numeric: true, sensitivity: 'base' }));
}

const lower = (s) => (s ?? '').toLocaleLowerCase('de');

/** Same matching as the server: own classes, entries without class, hidden types. */
export function matchesFilter(entry, { classes = [], showUnassigned = false, hiddenTypes = [] }) {
  const type = lower(entry.type?.trim());
  if (type && hiddenTypes.some((t) => lower(t) === type)) return false;
  if (classes.length === 0) return true;
  const own = classesOf(entry.className);
  if (own.length === 0) return showUnassigned;
  const wanted = new Set(classes.map(lower));
  return own.some((c) => wanted.has(lower(c)));
}

/** Free-text search over the visible fields of an entry. */
export function matchesText(entry, query) {
  const q = lower(query.trim());
  if (!q) return true;
  return [entry.period, entry.type, entry.subject, entry.previousSubject, entry.teacher,
    entry.substitute, entry.room, entry.previousRoom, entry.className, entry.note]
    .some((f) => f && lower(f).includes(q));
}
