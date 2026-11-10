import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// Course pages ("Mein Unterricht") show the teachers in a dropdown. Since
/// November 2026 the portal puts the name into `<li><span>` instead of
/// `<li><a>`; liblanis 0.1.4 reads it with `querySelector('ul>li>a')!` and
/// fails on every course page (homework, grades and courses then fail too).
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

/// Applies [fixTeacherDropdowns] to course pages loaded through liblanis.
class PortalFixInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final data = response.data;
    if (data is String &&
        response.requestOptions.uri.path.endsWith('/meinunterricht.php')) {
      response.data = fixTeacherDropdowns(data);
    }
    handler.next(response);
  }
}
