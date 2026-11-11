import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// Course pages ("Mein Unterricht") show the teachers in a dropdown. Since
/// November 2026 the portal puts the name into `<li><span>` instead of
/// `<li><a>`; liblanis 0.1.4 reads it with `querySelector('ul>li>a')!` and
/// fails on every course page (homework, grades and courses then fail too).
/// Reported upstream: https://github.com/lanis-mobile/liblanis/issues/3 –
/// remove this file once liblanis is fixed.
///
/// Turns the `<span>` back into an `<a>` so liblanis can parse the page.
/// Returns [page] unchanged when nothing needs fixing.
String fixTeacherDropdowns(String page) {
  if (!page.contains('dropdown-toggle btn-md')) return page;
  final doc = html.parse(page);
  var changed = false;
  for (final button in doc.getElementsByClassName(
    'btn btn-primary dropdown-toggle btn-md',
  )) {
    final group = button.parent;
    if (group == null || group.querySelector('ul>li>a') != null) continue;
    final span = group.querySelector('ul>li>span');
    if (span == null) continue;
    final link = Element.tag('a')..attributes['href'] = '#';
    link.nodes.addAll(span.nodes.toList());
    span.replaceWith(link);
    changed = true;
  }
  return changed ? doc.outerHtml : page;
}

/// The status label of a homework that is still open (parent accounts).
bool _isOpenMarker(Element e) =>
    e.classes.contains('label-warning') ||
    e.text.trim().toLowerCase() == 'offen';

/// The course overview ("Mein Unterricht") as liblanis 0.1.4 reads it
/// (`LessonsStudentParser.getHome`) assumes a list of courses
/// (`#mappen .row`), a link and heading in every course card, and a
/// `data-entry` / `.realHomework` in every entry row, each with `!`. An
/// account whose page lacks one of them (no courses yet, another account
/// type, odd entries) made homework, courses and grades fail with „Null check
/// operator used on a null value“. Makes the page complete: no course list →
/// an empty one, incomplete course cards and entries are dropped.
/// Returns [page] unchanged when nothing needs fixing.
String fixCourseOverview(String page) {
  // Answers of the portal that are no page (the „1“ after marking homework
  // as done) must stay as they are.
  if (!page.contains('<')) return page;
  final doc = html.parse(page);
  var changed = false;

  // A parent account's page has one block per pupil, with the pupil in the
  // ids (`mappen123456`). liblanis looks for `mappen` / `anwesend`: the first
  // pupil's blocks get these ids (the entries of other pupils do not belong to
  // any of these courses and are not used).
  for (final base in const ['aktuell', 'mappen', 'anwesend']) {
    if (doc.getElementById(base) != null) continue;
    final pattern = RegExp('^$base\\d+\$');
    for (final e in doc.querySelectorAll('[id^="$base"]')) {
      if (pattern.hasMatch(e.id)) {
        e.id = base;
        changed = true;
        break;
      }
    }
  }

  var mappen = doc.getElementById('mappen');
  if (mappen == null) {
    mappen = Element.tag('div')..id = 'mappen';
    doc.body?.append(mappen);
    changed = true;
  }
  if (mappen.getElementsByClassName('row').isEmpty) {
    mappen.append(Element.tag('div')..classes.add('row'));
    changed = true;
  }
  for (final card in mappen.getElementsByClassName('row').first.children) {
    if (card.querySelector('a.btn.btn-primary')?.attributes['href'] == null ||
        card.getElementsByTagName('h2').isEmpty) {
      card.remove();
      changed = true;
    }
  }

  for (final row in doc.querySelectorAll('tr.printable')) {
    if (row.querySelector('.datum') == null) continue;
    if (!row.attributes.containsKey('data-entry')) {
      row.remove();
      changed = true;
    } else if (row.querySelector('.homework') != null &&
        row.querySelector('.realHomework') == null) {
      for (final e in row.querySelectorAll('.homework')) {
        e.classes.remove('homework');
      }
      changed = true;
    } else if (row.querySelector('.homework') != null &&
        row.querySelector('.undone') == null &&
        row.querySelectorAll('.homework span.done').any(_isOpenMarker)) {
      // Parent accounts have no checkbox (`.undone`, which liblanis reads as
      // „not done“) but a status label on every homework: `done label-default`
      // „erledigt“ or `done label-warning` „offen“. Without this every
      // homework counted as done.
      row
          .querySelector('.homework')!
          .append(Element.tag('span')..classes.add('undone'));
      changed = true;
    }
  }
  return changed ? doc.outerHtml : page;
}

/// Applies the fixes above to a response of `meinunterricht.php`: only pages
/// that were loaded (GET), never the answers to changes (POST).
String fixCoursePage(String method, Uri uri, String data) {
  if (method.toUpperCase() != 'GET' ||
      !uri.path.endsWith('/meinunterricht.php')) {
    return data;
  }
  var page = fixTeacherDropdowns(data);
  // The overview has no action / course id in its address.
  if (!uri.queryParameters.containsKey('a') &&
      !uri.queryParameters.containsKey('id')) {
    page = fixCourseOverview(page);
  }
  return page;
}

/// Applies [fixCoursePage] to course pages loaded through liblanis.
class PortalFixInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final data = response.data;
    if (data is String) {
      response.data = fixCoursePage(
        response.requestOptions.method,
        response.requestOptions.uri,
        data,
      );
    }
    handler.next(response);
  }
}
