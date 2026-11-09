// Date helpers (German locale, local time).

const WEEKDAYS = ['Sonntag', 'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag'];
export const WEEKDAYS_SHORT = ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa'];

/** "YYYY-MM-DD" → local Date at midnight. */
export function parseYmd(s) {
  const [y, m, d] = String(s).split('-').map(Number);
  return new Date(y, m - 1, d);
}

/** Date → "YYYY-MM-DD" (local). */
export function ymd(date) {
  const p = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}

export function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

export function addDays(date, days) {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d;
}

export function sameDay(a, b) {
  return ymd(a) === ymd(b);
}

/** 1 = Monday … 7 = Sunday */
export function isoWeekday(date) {
  return date.getDay() === 0 ? 7 : date.getDay();
}

/** Monday of the week containing [date]. */
export function startOfWeek(date) {
  return addDays(startOfDay(date), 1 - isoWeekday(date));
}

/** "Montag, 9. November" */
export function longDate(date) {
  return `${WEEKDAYS[date.getDay()]}, ${date.toLocaleDateString('de-DE', { day: 'numeric', month: 'long' })}`;
}

/** "Mo, 09.11." */
export function shortDate(date) {
  return `${WEEKDAYS_SHORT[date.getDay()]}, ${date.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' })}`;
}

/** "09.11.2026" */
export function numericDate(date) {
  return date.toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

/** "19:00" */
export function time(date) {
  return date.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
}

/** "Heute", "Morgen", "Gestern" or weekday + date. */
export function relativeDay(date, now = new Date()) {
  const diff = Math.round((startOfDay(date) - startOfDay(now)) / 86400000);
  if (diff === 0) return 'Heute';
  if (diff === 1) return 'Morgen';
  if (diff === -1) return 'Gestern';
  return longDate(date);
}

/** "November 2026" */
export function monthTitle(date) {
  return date.toLocaleDateString('de-DE', { month: 'long', year: 'numeric' });
}

/** Human description of how old data is: "gerade eben", "vor 5 Min.", "um 07:12". */
export function age(isoString, now = new Date()) {
  const d = new Date(isoString);
  const minutes = Math.round((now - d) / 60000);
  if (minutes < 1) return 'gerade eben';
  if (minutes < 60) return `vor ${minutes} Min.`;
  return sameDay(d, now) ? `um ${time(d)}` : `${numericDate(d)} ${time(d)}`;
}

/** "HH:MM" → minutes since midnight. */
export function minutesOf(hhmm) {
  const [h, m] = String(hhmm).split(':').map(Number);
  return h * 60 + m;
}
