import 'package:lumo_server/lumo_server.dart';
import 'package:html/parser.dart' as html;
import 'package:test/test.dart';

/// Invented course page head with the teacher dropdown as the portal shows it
/// since November 2026 (name in `<span>`, not `<a>`).
const _newMarkup = '''
<div><h1>Mathematik</h1>
  <div class="btn-group">
    <button class="btn btn-primary dropdown-toggle btn-md" title="Muster, Max">
      <i class="fa fa-user"></i> MUS <span class="caret"></span></button>
    <ul class="dropdown-menu">
      <li><span><i class="fa fa-user fa-fw"></i> Max Muster</span></li>
      <li class="divider"></li>
    </ul>
  </div>
  <div class="btn-group"><a class="btn btn-info" href="x">Mappe</a>
    <ul class="dropdown-menu"><li><span>other</span></li></ul></div>
</div>''';

void main() {
  test('teacher name in <span> becomes a link liblanis can read', () {
    final fixed = fixTeacherDropdowns(_newMarkup);
    final doc = html.parse(fixed);
    final button = doc
        .getElementsByClassName('btn btn-primary dropdown-toggle btn-md')
        .single;
    // The expression liblanis 0.1.4 uses.
    expect(button.parent!.querySelector('ul>li>a')!.text.trim(), 'Max Muster');
    expect(button.text.trim(), 'MUS');
    expect(
      doc.querySelectorAll('ul.dropdown-menu>li>span'),
      hasLength(1),
      reason: 'other dropdowns stay unchanged',
    );
  });

  test('old markup and other pages stay unchanged', () {
    const old =
        '<div class="btn-group">'
        '<button class="btn btn-primary dropdown-toggle btn-md">MUS</button>'
        '<ul class="dropdown-menu"><li><a href="#">Max Muster</a></li></ul></div>';
    expect(fixTeacherDropdowns(old), same(old));
    const other = '<p>Vertretungsplan</p>';
    expect(fixTeacherDropdowns(other), same(other));
  });
}
