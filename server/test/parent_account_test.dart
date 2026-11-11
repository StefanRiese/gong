import 'package:html/parser.dart' as html;
import 'package:liblanis/easy_client.dart' as lanis;
import 'package:lumo_server/lumo_server.dart';
import 'package:lumo_server/src/sph/mappers.dart' show courseKey;
import 'package:test/test.dart';

import 'support/fake_gateway.dart';

/// A parent account's „Mein Unterricht“ page: one block per pupil, the
/// pupil's id is part of the ids.
const _parentPage = '''
<html><body><div id="content">
 <div class="pupilbox"><h2 data-pupil="111">Kind Eins</h2>
  <div class="tab-content">
   <div id="aktuell111" class="tab-pane active">
     <table><tr class="printable" data-entry="7"><td><h3><a href="meinunterricht.php?a=sus_view&id=5&p=111">Mathe</a></h3></td>
       <td><b class="thema">Brüche</b><small><span class="datum">10.11.2026</span></small></td></tr></table></div>
   <div id="mappen111" class="tab-pane"><div class="row">
     <div><h2>Mathe</h2><a class="btn btn-primary" href="meinunterricht.php?a=sus_view&id=5&p=111">Mappe</a></div>
   </div></div>
   <div id="anwesend111" class="tab-pane"></div>
  </div></div>
 <div class="pupilbox"><h2 data-pupil="222">Kind Zwei</h2>
  <div class="tab-content">
   <div id="aktuell222" class="tab-pane active"></div>
   <div id="mappen222" class="tab-pane"><div class="row">
     <div><h2>Kunst</h2><a class="btn btn-primary" href="meinunterricht.php?a=sus_view&id=6&p=222">Mappe</a></div>
   </div></div>
   <div id="anwesend222" class="tab-pane"></div>
  </div></div>
</div></body></html>''';

void main() {
  group('page of a parent account', () {
    final doc = html.parse(fixCourseOverview(_parentPage));

    test('the first pupil\'s blocks get the ids liblanis looks for', () {
      for (final id in ['aktuell', 'mappen', 'anwesend']) {
        expect(doc.getElementById(id), isNotNull, reason: id);
      }
      // What liblanis reads: the cards in the rows of #mappen.
      final cards = doc
          .getElementById('mappen')!
          .getElementsByClassName('row')
          .first
          .children;
      expect(cards, hasLength(1));
      expect(cards.single.querySelector('h2')!.text, 'Mathe');
    });

    test('the blocks of other pupils stay as they are', () {
      expect(doc.getElementById('mappen222'), isNotNull);
      expect(doc.getElementById('aktuell222'), isNotNull);
      expect(doc.querySelectorAll('#mappen'), hasLength(1));
    });

    test('a student page (plain ids) is not touched', () {
      const student =
          '<div id="mappen"><div class="row">'
          '<div><h2>M</h2><a class="btn btn-primary" href="x?id=1">M</a></div></div></div>'
          '<div id="aktuell"></div>';
      expect(fixCourseOverview(student), student);
    });
  });

  group('homework status on a parent page', () {
    String row(String entry, String label) =>
        '''
<tr class="printable" data-entry="$entry"><td><h3><a href="meinunterricht.php?a=sus_view&id=5&p=9">Mathe</a></h3></td>
 <td><b class="thema">T</b><small><span class="datum">10.11.2026</span></small></td>
 <td><div class="homework"><span class="label label-success title"><i class="fa fa-home"></i></span>
   $label<div class="markup text realHomework">S. 5</div></div></td></tr>''';
    const done =
        '<span class="done label label-default"><i class="fa fa-check-square-o"></i> erledigt</span>';
    const open =
        '<span class="done label label-warning"><i class="fa fa-check-o"></i> offen</span>';

    test('an open homework gets the marker liblanis reads as „not done“', () {
      final doc = html.parse(
        fixCourseOverview('<table>${row('1', done)}${row('2', open)}</table>'),
      );
      final rows = {
        for (final r in doc.querySelectorAll('tr.printable'))
          r.attributes['data-entry']!: r.querySelector('.undone') != null,
      };
      expect(rows, {'1': false, '2': true});
    });

    test('a student page (with the checkbox marker) is not changed', () {
      final student =
          '<div id="mappen"><div class="row"></div></div>'
          '<table>${row('3', '<span class="undone"></span>')}</table>';
      final doc = html.parse(fixCourseOverview(student));
      expect(doc.querySelectorAll('.undone'), hasLength(1));
    });
  });

  group('course ids', () {
    test(
      'plain numbers stay, the pupil of a parent link becomes part of it',
      () {
        expect(courseKey('100'), '100');
        expect(courseKey('100&p=456'), '100-p-456');
        expect(courseKey('a b/c'), 'a-b-c');
        expect(
          RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(courseKey('100&p=456')),
          isTrue,
        );
      },
    );
  });

  group('SphService with a parent account', () {
    late FakeGateway gw;
    late SphService svc;

    setUp(() {
      gw = FakeGateway()..accountTypeValue = 'parent';
      // Course links of a parent carry the pupil.
      for (final l in gw.lessonsData) {
        l.courseID = '${l.courseID}&p=9';
      }
      gw.lessonsData = [
        for (final l in gw.lessonsData)
          lanis.Lesson(
            courseID: l.courseID,
            name: l.name,
            courseURL: Uri.parse(
              'https://start.schulportal.hessen.de/meinunterricht.php?a=sus_view&id=${l.courseID}',
            ),
            teachers: l.teachers,
            currentEntry: l.currentEntry,
          ),
      ];
      svc = SphService(gw);
    });
    tearDown(() => svc.dispose());

    test('courses, details and homework use the safe id', () async {
      final courses = await svc.courses();
      expect(courses.map((c) => c.id), ['100-p-9', '200-p-9']);
      final details = await svc.courseDetails('100-p-9');
      expect(details.course.id, '100-p-9');
      for (final h in await svc.homework()) {
        expect(h.courseId, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      }
    });

    test('homework cannot be marked as done', () async {
      await expectLater(
        svc.setHomeworkDone('100-p-9', 'e1', true),
        throwsA(isA<SphFeatureDisabledException>()),
      );
      expect(gw.homeworkCalls, isEmpty, reason: 'nothing sent to the portal');
    });
  });

  group('applets of an account', () {
    const student = {'stundenplan.php', 'vertretungsplan.php'};

    test('a parent account gets the timetable when the portal menu has it', () {
      final applets = appletsOfAccount(
        supported: {'kalender.php', 'meinunterricht.php'},
        menuLinks: ['kalender.php', 'stundenplan.php', null],
        accountType: 'parent',
      );
      expect(applets, {
        'kalender.php',
        'meinunterricht.php',
        'stundenplan.php',
      });
    });

    test('not when the menu lacks it, and not for other account types', () {
      expect(
        appletsOfAccount(
          supported: {'kalender.php'},
          menuLinks: ['kalender.php'],
          accountType: 'parent',
        ),
        {'kalender.php'},
      );
      expect(
        appletsOfAccount(
          supported: {'kalender.php'},
          menuLinks: ['stundenplan.php'],
          accountType: 'teacher',
        ),
        {'kalender.php'},
      );
      expect(
        appletsOfAccount(
          supported: student,
          menuLinks: ['stundenplan.php'],
          accountType: 'student',
        ),
        student,
      );
    });
  });
}
