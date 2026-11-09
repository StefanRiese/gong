// Finds new items and turns them into notifications. Pure functions.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html_unescape/html_unescape.dart';

import '../models/models.dart';
import 'notifier.dart';

/// A notification and the fingerprints it covers. Fingerprints are marked as
/// seen only after the notification was sent.
class PendingNotification {
  final AppNotification notification;
  final Set<String> fingerprints;

  const PendingNotification(this.notification, this.fingerprints);
}

class Detection {
  /// Fingerprints of everything currently present.
  final Set<String> current;
  final List<PendingNotification> pending;

  const Detection(this.current, this.pending);
}

/// Above this many new items per run, one summary is sent instead.
const maxNotificationsPerRun = 8;

String fingerprint(List<Object?> parts) => sha256
    .convert(
      utf8.encode(parts.map((p) => p?.toString().trim() ?? '').join('\u001f')),
    )
    .toString()
    .substring(0, 32);

const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

String _dayLabel(DateTime date, DateTime today) {
  final d = DateTime(date.year, date.month, date.day);
  final diff = d.difference(today).inDays;
  final dm =
      '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.';
  final wd = _weekdays[date.weekday - 1];
  if (diff == 0) return 'heute ($wd, $dm)';
  if (diff == 1) return 'morgen ($wd, $dm)';
  return '$wd, $dm';
}

final _unescape = HtmlUnescape();
final _breaks = RegExp(r'<br\s*/?>|</(p|div|li|tr)>', caseSensitive: false);
final _tags = RegExp(r'<[^>]*>');

/// Text from a portal HTML fragment (homework descriptions may contain
/// markup and entities) for push notifications.
String plainText(String html) => _unescape
    .convert(html.replaceAll(_breaks, '\n').replaceAll(_tags, ''))
    .split('\n')
    .map((line) => line.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
    .join('\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

String _truncate(String s, int max) {
  final t = s.trim();
  return t.length <= max ? t : '${t.substring(0, max - 1)}…';
}

bool _isCancellation(Substitution s) => RegExp(
  r'entfall|fällt aus|ausfall',
  caseSensitive: false,
).hasMatch('${s.type ?? ''} ${s.note ?? ''}');

/// Text line for one substitution, e.g.
/// "3–4. Std. Deutsch: Vertretung · Schmitt · Raum A112 · Arbeitsblätter"
String substitutionLine(Substitution s) {
  final period = s.period.replaceAll(RegExp(r'\s*-\s*'), '–');
  final details = [
    s.type,
    s.substitute,
    if (s.room != null) 'Raum ${s.room}',
    s.note,
  ].whereType<String>().where((x) => x.isNotEmpty);
  final subject = s.subject ?? s.previousSubject ?? 'Unterricht';
  return '$period. Std. $subject: ${details.join(' · ')}';
}

/// New or changed substitutions for today and later, one notification per day.
/// Entries not accepted by [include] (e.g. other classes) are recorded as
/// seen without notification.
Detection detectSubstitutions(
  List<SubstitutionDay> days,
  Set<String> seen,
  DateTime now, {
  bool Function(Substitution s)? include,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final current = <String>{};
  final pending = <PendingNotification>[];
  var newCount = 0;
  final allNew = <String>{};

  for (final day in days) {
    if (day.date.isBefore(today)) continue;
    final newEntries = <Substitution>[];
    final newFps = <String>{};
    for (final s in day.entries) {
      final f = fingerprint([
        'sub',
        day.date.toIso8601String().substring(0, 10),
        s.period,
        s.subject,
        s.previousSubject,
        s.type,
        s.substitute,
        s.room,
        s.note,
      ]);
      current.add(f);
      if (!seen.contains(f) && (include == null || include(s))) {
        newEntries.add(s);
        newFps.add(f);
      }
    }
    if (newEntries.isEmpty) continue;
    newCount += newEntries.length;
    allNew.addAll(newFps);
    final soon = day.date.difference(today).inDays <= 1;
    final cancelled = newEntries.any(_isCancellation);
    pending.add(
      PendingNotification(
        AppNotification(
          title: newEntries.length == 1
              ? 'Vertretung ${_dayLabel(day.date, today)}'
              : '${newEntries.length} Vertretungen ${_dayLabel(day.date, today)}',
          message: newEntries.map(substitutionLine).join('\n'),
          tags: [cancelled ? 'x' : 'warning'],
          priority: soon ? 4 : 3,
          clickPath: '/vertretungen',
        ),
        newFps,
      ),
    );
  }

  if (newCount > maxNotificationsPerRun) {
    pending
      ..clear()
      ..add(
        PendingNotification(
          AppNotification(
            title: '$newCount neue Vertretungen',
            message: 'Details in der App.',
            tags: const ['warning'],
            clickPath: '/vertretungen',
          ),
          allNew,
        ),
      );
  }
  return Detection(current, pending);
}

/// New homework (changes to the "done" flag are ignored).
Detection detectHomework(List<Homework> items, Set<String> seen) {
  final current = <String>{};
  final fresh = <(Homework, String)>[];
  for (final h in items) {
    final f = fingerprint(['hw', h.courseId, h.entryId, h.description]);
    current.add(f);
    if (!seen.contains(f) && !h.done) fresh.add((h, f));
  }
  if (fresh.length > maxNotificationsPerRun) {
    return Detection(current, [
      PendingNotification(
        AppNotification(
          title: '${fresh.length} neue Hausaufgaben',
          message: fresh.map((e) => e.$1.courseName).toSet().join(', '),
          tags: const ['books'],
          clickPath: '/hausaufgaben',
        ),
        {for (final e in fresh) e.$2},
      ),
    ]);
  }
  return Detection(current, [
    for (final (h, f) in fresh)
      PendingNotification(
        AppNotification(
          title: 'Hausaufgabe ${h.courseName}',
          message: _truncate(
            [
              if (h.topic != null) '${h.topic}:',
              plainText(h.description),
            ].join('\n'),
            500,
          ),
          tags: const ['books'],
          clickPath: '/kurse/${Uri.encodeComponent(h.courseId)}',
        ),
        {f},
      ),
  ]);
}

/// New grades, one notification per course. The mark itself is only included
/// when [includeValues] is set (ntfy topics may be readable by others).
Detection detectGrades(
  List<CourseGrades> courses,
  Set<String> seen, {
  bool includeValues = false,
}) {
  final current = <String>{};
  final pending = <PendingNotification>[];
  final allNew = <String>{};
  var newCount = 0;

  for (final c in courses) {
    final fresh = <(Grade, String)>[];
    for (final g in c.grades) {
      final f = fingerprint(['grade', c.course.id, g.name, g.date, g.mark]);
      current.add(f);
      if (!seen.contains(f)) fresh.add((g, f));
    }
    if (fresh.isEmpty) continue;
    newCount += fresh.length;
    allNew.addAll(fresh.map((e) => e.$2));
    pending.add(
      PendingNotification(
        AppNotification(
          title: fresh.length == 1
              ? 'Neue Note: ${c.course.name}'
              : '${fresh.length} neue Noten: ${c.course.name}',
          message: fresh
              .map(
                (e) => [
                  e.$1.name,
                  if (e.$1.date.isNotEmpty) '(${e.$1.date})',
                  if (includeValues) '→ ${e.$1.mark}',
                ].join(' '),
              )
              .join('\n'),
          tags: const ['mortar_board'],
          clickPath: '/kurse/${Uri.encodeComponent(c.course.id)}',
        ),
        {for (final e in fresh) e.$2},
      ),
    );
  }

  if (newCount > maxNotificationsPerRun) {
    pending
      ..clear()
      ..add(
        PendingNotification(
          AppNotification(
            title: '$newCount neue Noten',
            message: 'Details in der App.',
            tags: const ['mortar_board'],
            clickPath: '/noten',
          ),
          allNew,
        ),
      );
  }
  return Detection(current, pending);
}
