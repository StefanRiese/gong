import 'package:gong_server/gong_server.dart';
import 'package:test/test.dart';

/// Invented order page with the structure of Caseda Schulmenü
/// (schulmenueplaner.de): two days, a menu line and a dessert line.
const _page = '''
<html><body>
<div class="header-account-balance">Guthaben: 12,30 &euro;</div>
<table class="table food-order">
  <thead><tr>
    <th class="menu-meal head">&nbsp;</th>
    <th>Montag, 16.11.26</th><th>Dienstag, 17.11.26</th>
  </tr></thead>
  <tbody>
    <tr>
      <td rowspan="4" class="head menu-meal">Menü 1 </td>
      <td class="menu-cell day-usual"> Nudeln mit Tomatensauce </td>
      <td class="menu-cell day-usual"> Gemüsereis </td>
    </tr>
    <tr>
      <td class="menu-allergens day-usual"><div class="extras"> a, a1, g </div></td>
      <td class="menu-allergens day-usual"><div class="extras"></div></td>
    </tr>
    <tr>
      <td class="menu-price menu-pdf-ordered day-usual"><div class="price"> 3,90 &euro; </div>
        <div class="order-quantity"> Bestellt: 1 </div></td>
      <td class="menu-price day-usual"><div class="price"> 3,90 &euro; </div></td>
    </tr>
    <tr>
      <td class="order-button-cell"><form class="essen" data-order-status="1"
        data-order-timelimit-expired="1" data-price="3,90"></form></td>
      <td class="order-button-cell"><form class="essen" data-order-status="0"
        data-order-timelimit-expired="0" data-price="3,90"></form></td>
    </tr>
    <tr>
      <td rowspan="4" class="head menu-meal">Dessert</td>
      <td class="menu-cell day-usual"> Apfel </td>
      <td class="menu-cell day-usual"></td>
    </tr>
    <tr>
      <td class="menu-allergens day-usual"></td><td class="menu-allergens day-usual"></td>
    </tr>
    <tr>
      <td class="menu-price day-usual"></td><td class="menu-price day-usual"></td>
    </tr>
    <tr>
      <td class="order-button-cell"><form data-order-status="0" data-price="0,50"></form></td>
      <td class="order-button-cell"></td>
    </tr>
  </tbody>
</table>
</body></html>
''';

void main() {
  test('parses dishes, orders, prices, allergens and balance', () {
    final w = parseMealWeek(_page);
    expect(w.balanceCents, 1230);
    expect(w.offers, hasLength(3), reason: 'empty dessert cell is skipped');

    final mon = w.offers
        .where((o) => o.date == DateTime(2026, 11, 16))
        .toList();
    expect(mon.map((o) => o.line), ['Menü 1', 'Dessert']);
    expect(mon[0].name, 'Nudeln mit Tomatensauce');
    expect(mon[0].allergens, ['a', 'a1', 'g']);
    expect(mon[0].priceCents, 390);
    expect((mon[0].ordered, mon[0].deadlinePassed), (1, true));
    expect(mon[1].priceCents, 50, reason: 'price from the form');
    expect(mon[1].ordered, 0);

    final tue = w.offers.singleWhere((o) => o.date == DateTime(2026, 11, 17));
    expect(
      (tue.name, tue.ordered, tue.deadlinePassed),
      ('Gemüsereis', 0, false),
    );
    expect(tue.allergens, isEmpty);
    expect(tue.toJson()['date'], '2026-11-17');
  });

  test('login page instead of the order page', () {
    expect(
      () => parseMealWeek('<form id="login_form"></form>'),
      throwsA(isA<CasedaException>()),
    );
  });

  test('euro amounts and ISO weeks', () {
    expect(parseEuroCents('3,90 €'), 390);
    expect(parseEuroCents('Guthaben: -1.234,5 €'), -123450);
    expect(parseEuroCents('–'), isNull);
    expect(isoWeek(DateTime(2026, 11, 10)), (2026, 46));
    expect(isoWeek(DateTime(2027, 1, 1)), (2026, 53));
    expect(isoWeek(DateTime(2026, 1, 1)), (2026, 1));
  });
}
