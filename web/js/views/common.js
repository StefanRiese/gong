// Shared building blocks for views.

import { api, errorMessage } from '../api.js';
import { h, errorBox } from '../dom.js';
import { minutesOf, startOfWeek } from '../format.js';
import { subjectStyle } from '../colors.js';

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

/**
 * Section that renders immediately with a loading note and fills in when
 * [load] resolves — for slow data that should not delay the whole page.
 * Returns null if [load] is null (feature disabled).
 */
export function lazySection(title, load, renderOk) {
  if (!load) return null;
  const body = h('div', { class: 'loading-inline' }, 'Laden …');
  const el = h('section', { class: 'section' },
    h('div', { class: 'section-head' }, h('h2', null, title)), body);
  settle(load()).then((result) => {
    body.replaceWith(result.ok
      ? h('div', null, renderOk(result.value))
      : errorBox(errorMessage(result.error)));
  }, () => body.replaceWith(errorBox('Bitte neu anmelden.')));
  return el;
}

export function pageHeader(title, ...extra) {
  return h('div', { class: 'page-head' }, h('h1', null, title), ...extra);
}

let toggleCounter = 0;

/** Saves the done state of a homework entry in Schulportal. */
export function saveHomeworkDone(courseId, entryId, done) {
  return api(
    `/api/courses/${encodeURIComponent(courseId)}/entries/${encodeURIComponent(entryId)}/homework`,
    { method: 'PUT', body: { done } },
  );
}

/**
 * "erledigt" checkbox for a homework entry. Saves to the portal immediately;
 * on failure the checkbox flips back and an error is shown below it.
 * @param {{courseId: string, entryId: string, done: boolean, card?: Element,
 *   onSaved?: (done: boolean) => void}} item
 *   card: element that gets the "done" class while the homework is done;
 *   onSaved: called after the portal confirmed the change
 */
export function homeworkToggle({ courseId, entryId, done, card, onSaved }) {
  const id = `hw-${++toggleCounter}`;
  const message = h('span', { class: 'hw-error', role: 'alert' });
  const input = h('input', { type: 'checkbox', id, checked: done });
  const label = h('label', { class: ['check', 'hw-toggle', done && 'is-done'], for: id }, input, 'erledigt');
  const apply = (value) => {
    input.checked = value;
    label.classList.toggle('is-done', value);
    card?.classList.toggle('done', value);
  };
  card?.classList.toggle('done', done);

  input.addEventListener('change', async () => {
    const value = input.checked;
    apply(value);
    input.disabled = true;
    label.classList.add('saving');
    message.textContent = '';
    try {
      await saveHomeworkDone(courseId, entryId, value);
      onSaved?.(value);
    } catch (err) {
      apply(!value);
      message.textContent = `Nicht gespeichert: ${errorMessage(err)}`;
    } finally {
      input.disabled = false;
      label.classList.remove('saving');
    }
  });
  return h('span', { class: 'hw-toggle-wrap' }, label, message);
}

/** Fades [el] out, then removes it; resolves when it is gone. */
export function removeAnimated(el) {
  return new Promise((resolve) => {
    const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (reduce) {
      el.remove();
      resolve();
      return;
    }
    el.classList.add('leaving');
    setTimeout(() => {
      el.remove();
      resolve();
    }, 250);
  });
}

let toastTimer = null;

/**
 * Short message at the bottom of the screen with an optional action
 * (e.g. "Rückgängig"). A new toast replaces the previous one.
 */
export function showToast(text, actionLabel, action, ms = 6000) {
  document.querySelector('.toast')?.remove();
  clearTimeout(toastTimer);
  const toast = h('div', { class: 'toast', role: 'status' }, h('span', null, text));
  if (actionLabel && action) {
    toast.append(h('button', {
      type: 'button', class: 'toast-action',
      onclick: async () => {
        toast.remove();
        clearTimeout(toastTimer);
        await action();
      },
    }, actionLabel));
  }
  document.body.append(toast);
  toastTimer = setTimeout(() => toast.remove(), ms);
}

/**
 * Toast with "Rückgängig" after homework was marked as done and hidden.
 * Undo saves "not done" and reloads the current page (cached data, fast).
 */
export function homeworkDoneToast(item, rerender) {
  showToast(`${item.courseName}: als erledigt markiert`, 'Rückgängig', async () => {
    try {
      await saveHomeworkDone(item.courseId, item.entryId, false);
      rerender();
    } catch (err) {
      showToast(`Nicht rückgängig gemacht: ${errorMessage(err)}`);
    }
  });
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
        s.subject ?? s.previousSubject
          ? h('span', { class: 'subject-dot', style: subjectStyle(s.subject ?? s.previousSubject), 'aria-hidden': 'true' })
          : null,
        h('strong', null, s.subject ?? s.previousSubject ?? 'Unterricht'),
        s.type ? badge(s.type, cancelled ? 'danger' : 'warn') : null),
      changes.length
        ? h('dl', { class: 'facts' }, changes.map(([k, v]) => [h('dt', null, k), h('dd', null, v)]))
        : null,
      s.note ? h('p', { class: 'note' }, s.note) : null,
    ),
  );
}
