// Subject colors — one assignment for the whole app.
//
// Color keys are timetable subjects (often abbreviations like "M", "BIO").
// Courses ("Mathematik 05eg") are mapped to a timetable subject, either by the
// user (settings.courseSubjects) or automatically; unmapped courses use their
// own name as key. Colors come from settings.subjectColors or a palette.

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

let custom = {};          // color key → "#rrggbb" (user)
let courseOverrides = {}; // course id → subject key, "" = none (user)
let subjects = [];        // timetable subject keys
let courses = [];         // [{id, name}]
let autoMatch = {};       // course id → subject key (automatic)
let assigned = {};        // color key → palette color

const lower = (s) => s.toLocaleLowerCase('de');

function hashOf(name) {
  let hash = 0;
  for (const ch of lower(String(name).trim())) {
    hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
  }
  return hash;
}

/** Course name without the class/group suffix: "Kunst 05eg" → "Kunst". */
export function baseCourseName(name) {
  const words = String(name ?? '').trim().split(/\s+/);
  while (words.length > 1 && /\d/.test(words.at(-1))) words.pop();
  return words.join(' ');
}

/** True if the letters of [abbr] appear in order in [text]. */
function isSubsequence(abbr, text) {
  let i = 0;
  for (const ch of text) if (ch === abbr[i]) i++;
  return i === abbr.length;
}

/**
 * How well a timetable subject (e.g. "M", "BIO", "TUT") fits a course name
 * (e.g. "Mathematik 05eg"); 0 = not at all.
 */
export function matchScore(subject, courseName) {
  const abbr = lower(subject.trim());
  const name = lower(baseCourseName(courseName));
  if (!abbr || !name) return 0;
  if (abbr === name) return 100;
  if (name.startsWith(abbr)) return 50 + abbr.length;
  if (abbr.length >= 2 && abbr[0] === name[0] && isSubsequence(abbr, name)) return 30 + abbr.length;
  const words = name.split(/[^\p{L}]+/u).filter(Boolean);
  if (abbr.length >= 2 && words.some((w) => w.startsWith(abbr))) return 20 + abbr.length;
  return 0;
}

/**
 * Matches courses to timetable subjects one-to-one: best scores first,
 * longer abbreviations before shorter ones ("ETHI" takes Ethik before "E"),
 * ties alphabetically by course name.
 */
export function matchCourses(subjectKeys, courseList) {
  const candidates = [];
  for (const s of subjectKeys) {
    for (const c of courseList) {
      const score = matchScore(s, c.name);
      if (score > 0) candidates.push({ s, c, score });
    }
  }
  candidates.sort((a, b) => b.score - a.score || b.s.length - a.s.length
    || a.c.name.localeCompare(b.c.name, 'de'));
  const usedSubjects = new Set();
  const result = {};
  for (const { s, c } of candidates) {
    if (usedSubjects.has(s) || c.id in result) continue;
    usedSubjects.add(s);
    result[c.id] = s;
  }
  return result;
}

/**
 * Sets the data all colors are derived from. Call at start and after the
 * settings or the timetable changed. Missing fields keep their current value.
 * @param {{subjects?: string[], courses?: {id: string, name: string}[],
 *   settings?: {subjectColors?: object, courseSubjects?: object}}} data
 */
export function initColors(data = {}) {
  if (data.subjects) subjects = [...new Set(data.subjects.map((s) => s?.trim()).filter(Boolean))];
  if (data.courses) courses = data.courses.map((c) => ({ id: c.id, name: c.name.trim() }));
  if (data.settings) {
    custom = { ...(data.settings.subjectColors ?? {}) };
    courseOverrides = { ...(data.settings.courseSubjects ?? {}) };
  }
  autoMatch = matchCourses(subjects, courses);

  // Palette slots for all keys in use: subjects first, then unmapped courses.
  const keys = [...subjects].sort((a, b) => a.localeCompare(b, 'de'));
  for (const c of courses) {
    const key = courseKeyOf(c.id, c.name);
    if (!keys.includes(key)) keys.push(key);
  }
  const used = new Set();
  assigned = {};
  for (const key of keys) {
    if (used.size >= PALETTE.length) used.clear(); // more keys than colors
    let slot = hashOf(key) % PALETTE.length;
    while (used.has(slot)) slot = (slot + 1) % PALETTE.length;
    used.add(slot);
    assigned[key] = PALETTE[slot];
  }
}

export function getSubjectColors() {
  return { ...custom };
}

export function getCourseOverrides() {
  return { ...courseOverrides };
}

export function getSubjects() {
  return [...subjects];
}

export function getCourses() {
  return [...courses];
}

/** Automatically matched timetable subject of a course (or null). */
export function autoSubjectOf(courseId) {
  return autoMatch[courseId] ?? null;
}

/** Timetable subject a course belongs to (user choice, else automatic). */
export function courseSubject(courseId) {
  if (courseId in courseOverrides) return courseOverrides[courseId] || null;
  return autoMatch[courseId] ?? null;
}

function courseKeyOf(courseId, courseName) {
  return courseSubject(courseId) ?? String(courseName ?? '').trim();
}

/** Color key of a course: its timetable subject, or its own name. */
export function courseKey(course) {
  return courseKeyOf(course.id, course.name);
}

/** Automatic (palette) color of a key. */
export function autoColor(key) {
  const k = String(key).trim();
  return assigned[k] ?? PALETTE[hashOf(k) % PALETTE.length];
}

/** Color of a timetable subject or course key, or null without a key. */
export function subjectColor(key) {
  const k = key?.trim();
  if (!k) return null;
  return custom[k] ?? autoColor(k);
}

/** Inline style for h(): sets --subject (CSP-safe via CSSOM). */
export function subjectStyle(key) {
  const color = subjectColor(key);
  return color ? { '--subject': color } : null;
}

/** Inline style for a course ({id, name} or courseId + name). */
export function courseStyle(courseOrId, name) {
  const course = typeof courseOrId === 'object' ? courseOrId : { id: courseOrId, name };
  return subjectStyle(courseKey(course));
}
