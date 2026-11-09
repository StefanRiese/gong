// Shared building blocks for views.

import { errorMessage } from '../api.js';
import { h, errorBox } from '../dom.js';
import { minutesOf, startOfWeek } from '../format.js';

/** Awaits a promise without throwing: {ok, value} or {ok: false, error}. */
export async function settle(promise) {
  try {
    return { ok: true, value: await promise };
  } catch (error) {
    if (error?.isUnauthorized) throw error;
    return { ok: false, error };
  }
}

/** Loads [path] only if [feature] is enabled; null otherwise. */
export function load(ctx, feature, path) {
  return ctx.features.has(feature) ? settle(ctx.get(path)) : Promise.resolve(null);
}

/** Section with heading; shows an error box if [result] failed. */
export function section(title, result, renderOk, extraHeader) {
  if (result == null) return null;
  return h('section', { class: 'section' },
    h('div', { class: 'section-head' }, h('h2', null, title), extraHeader ?? null),
    result.ok ? renderOk(result.value) : errorBox(errorMessage(result.error)),
  );
}

export function pageHeader(title, ...extra) {
  return h('div', { class: 'page-head' }, h('h1', null, title), ...extra);
}

/** Small label like "Entfall" or "erledigt". */
export function badge(text, kind = '') {
  return h('span', { class: ['badge', kind && `badge-${kind}`] }, text);
}

/**
 * Week marker ("A"/"B") for [date], given the current week's marker.
 * Alternates per calendar week relative to today.
 */
export function weekFor(date, currentWeek, now = new Date()) {
  if (currentWeek !== 'A' && currentWeek !== 'B') return currentWeek ?? null;
  const weeks = Math.round((startOfWeek(date) - startOfWeek(now)) / (7 * 86400000));
  if (weeks % 2 === 0) return currentWeek;
  return currentWeek === 'A' ? 'B' : 'A';
}

/** Lessons of a weekday (1–5) for a given week marker, sorted by start. */
export function lessonsOn(timetable, weekday, week) {
  return timetable.lessons
    .filter((l) => l.weekday === weekday && (!l.week || !week || l.week === week))
    .sort((a, b) => minutesOf(a.start) - minutesOf(b.start));
}

/** Parses a substitution period like "3", "3 - 4", "3.-4." into [from, to]. */
export function periodRange(text) {
  const nums = String(text ?? '').match(/\d+/g)?.map(Number) ?? [];
  if (nums.length === 0) return null;
  return [Math.min(...nums), Math.max(...nums)];
}

/** True if a substitution type means the lesson does not take place. */
export function isCancellation(sub) {
  return /entfall|fällt aus|ausfall|frei/i.test(`${sub.type ?? ''} ${sub.note ?? ''}`);
}

/** One substitution as a card. */
export function substitutionCard(s) {
  const cancelled = isCancellation(s);
  const changes = [];
  if (s.substitute) changes.push(['Vertretung', s.substitute]);
  if (s.teacher) changes.push(['Lehrkraft', s.teacher]);
  if (s.room) changes.push(['Raum', s.previousRoom && s.previousRoom !== s.room ? `${s.room} (statt ${s.previousRoom})` : s.room]);
  else if (s.previousRoom) changes.push(['Raum', s.previousRoom]);
  if (s.previousSubject && s.previousSubject !== s.subject) changes.push(['statt', s.previousSubject]);
  if (s.className) changes.push(['Klasse', s.className]);

  return h('article', { class: ['card', 'sub-card', cancelled && 'cancelled'] },
    h('div', { class: 'sub-period' }, s.period.replace(/\s*-\s*/, '–'), h('small', null, 'Std.')),
    h('div', { class: 'sub-body' },
      h('div', { class: 'sub-title' },
        h('strong', null, s.subject ?? s.previousSubject ?? 'Unterricht'),
        s.type ? badge(s.type, cancelled ? 'danger' : 'warn') : null),
      changes.length
        ? h('dl', { class: 'facts' }, changes.map(([k, v]) => [h('dt', null, k), h('dd', null, v)]))
        : null,
      s.note ? h('p', { class: 'note' }, s.note) : null,
    ),
  );
}
