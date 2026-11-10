// Read-only access to Caseda Schulmenü (school meals of Caseda Gastro
// Services, built on the schulmenueplaner.de platform): weekly menu, own
// orders and balance. Ordering is not supported on purpose.

import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// One dish of a menu line on one day.
class MealOffer {
  final DateTime date;

  /// Menu line, e.g. "Menü 1".
  final String line;
  final String name;
  final List<String> allergens;

  /// Price in cents, null if not shown.
  final int? priceCents;

  /// Ordered quantity (0 = not ordered).
  final int ordered;

  /// The order deadline has passed (no ordering / cancelling any more).
  final bool deadlinePassed;

  const MealOffer({
    required this.date,
    required this.line,
    required this.name,
    required this.allergens,
    required this.priceCents,
    required this.ordered,
    required this.deadlinePassed,
  });

  factory MealOffer.fromJson(Map<String, Object?> j) => MealOffer(
    date: DateTime.parse(j['date'] as String),
    line: j['line'] as String,
    name: j['name'] as String,
    allergens: [for (final a in j['allergens'] as List? ?? const []) '$a'],
    priceCents: j['priceCents'] as int?,
    ordered: j['ordered'] as int? ?? 0,
    deadlinePassed: j['deadlinePassed'] as bool? ?? false,
  );

  Map<String, Object?> toJson() => {
    'date':
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
    'line': line,
    'name': name,
    'allergens': allergens,
    'priceCents': priceCents,
    'ordered': ordered,
    'deadlinePassed': deadlinePassed,
  };
}

/// The order page of one calendar week.
class MealWeek {
  final List<MealOffer> offers;

  /// Account balance in cents (header of the customer area), if shown.
  final int? balanceCents;

  const MealWeek({required this.offers, required this.balanceCents});
}

/// Balance and own orders (what Lumo shows; the menu itself is not kept).
class MealsSnapshot {
  final int? balanceCents;

  /// Ordered dishes from the start of the current week, by date.
  final List<MealOffer> orders;

  const MealsSnapshot({required this.balanceCents, required this.orders});

  factory MealsSnapshot.fromJson(Map<String, Object?> j) => MealsSnapshot(
    balanceCents: j['balanceCents'] as int?,
    orders: [
      for (final o in j['orders'] as List? ?? const [])
        MealOffer.fromJson((o as Map).cast()),
    ],
  );

  Map<String, Object?> toJson() => {
    'balanceCents': balanceCents,
    'orders': [for (final o in orders) o.toJson()],
  };
}

/// Access to the meal ordering system (tests: fake).
abstract interface class MealsGateway {
  /// Balance and orders of the current and the following weeks.
  Future<MealsSnapshot> load(DateTime today);

  /// Page where meals are ordered (linked from the web UI), if known.
  Uri? get orderUrl;
}

/// [MealsGateway] for Caseda Schulmenü: logs in, reads [weeks] week pages,
/// logs out (a new session per sync run).
class CasedaGateway implements MealsGateway {
  final Uri baseUrl;
  final String username;
  final String password;
  final int weeks;

  const CasedaGateway({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.weeks = 3,
  });

  @override
  Uri get orderUrl => baseUrl.resolve('/kunden/essen/');

  @override
  Future<MealsSnapshot> load(DateTime today) async {
    final client = CasedaClient(
      baseUrl: baseUrl,
      username: username,
      password: password,
    );
    try {
      await client.login();
      int? balance;
      final orders = <MealOffer>[];
      for (var i = 0; i < weeks; i++) {
        final (year, week) = isoWeek(today.add(Duration(days: 7 * i)));
        final w = await client.week(year, week);
        balance ??= w.balanceCents;
        orders.addAll(w.offers.where((o) => o.ordered > 0));
      }
      orders.sort((a, b) => a.date.compareTo(b.date));
      return MealsSnapshot(balanceCents: balance, orders: orders);
    } on CasedaException {
      rethrow;
    } on Object catch (e) {
      throw CasedaException('Caseda not reachable: $e');
    } finally {
      await client.logout();
      client.close();
    }
  }
}

class CasedaException implements Exception {
  final String message;

  /// Wrong e-mail or password (no retry before the settings change).
  final bool isAuth;

  const CasedaException(this.message, {this.isAuth = false});

  @override
  String toString() => 'CasedaException: $message';
}

/// "3,90 €" → 390; "-12,30 €" → -1230.
int? parseEuroCents(String text) {
  final m = RegExp(
    r'(-?)\s*(\d{1,6})(?:,(\d{1,2}))?',
  ).firstMatch(text.replaceAll('.', ''));
  if (m == null) return null;
  final cents =
      int.parse(m[2]!) * 100 + int.parse((m[3] ?? '0').padRight(2, '0'));
  return m[1] == '-' ? -cents : cents;
}

String _text(Element? e) =>
    (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Parses the order page (`/kunden/essen/<year>/<week>/`).
///
/// The page has a table `food-order`: the header holds the days
/// ("Montag, 09.11.26"); each menu line is a block of rows whose first cell
/// (`menu-meal`, with rowspan) names the line, followed by rows with the
/// dishes (`menu-cell`), allergens (`menu-allergens`), prices with
/// "Bestellt: n" (`menu-price`) and the order forms (`data-order-status`,
/// `data-order-timelimit-expired`).
MealWeek parseMealWeek(String page) {
  final doc = html.parse(page);
  final table = doc.querySelector('table.food-order');
  if (table == null) {
    if (doc.querySelector('#login_form') != null) {
      throw const CasedaException('Not logged in', isAuth: true);
    }
    return MealWeek(offers: const [], balanceCents: _balance(doc));
  }

  final dates = <DateTime?>[];
  for (final th in table.querySelectorAll('thead th').skip(1)) {
    final m = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{2,4})').firstMatch(_text(th));
    if (m == null) {
      dates.add(null);
      continue;
    }
    var year = int.parse(m[3]!);
    if (year < 100) year += 2000;
    dates.add(DateTime(year, int.parse(m[2]!), int.parse(m[1]!)));
  }

  final offers = <MealOffer>[];
  final rows = table.querySelectorAll('tbody > tr');
  var line = '';
  List<Element> names = [], allergens = [], prices = [], forms = [];

  void flush() {
    for (var i = 0; i < names.length && i < dates.length; i++) {
      final date = dates[i];
      final name = _text(names[i]);
      if (date == null || name.isEmpty) continue;
      final priceCell = i < prices.length ? prices[i] : null;
      final form = i < forms.length ? forms[i].querySelector('form') : null;
      final orderedText = _text(priceCell?.querySelector('.order-quantity'));
      final ordered =
          int.tryParse(RegExp(r'\d+').firstMatch(orderedText)?[0] ?? '') ??
          (form?.attributes['data-order-status'] == '1' ? 1 : 0);
      final price = _text(priceCell?.querySelector('.price'));
      offers.add(
        MealOffer(
          date: date,
          line: line,
          name: name,
          allergens: [
            for (final a in _text(
              i < allergens.length ? allergens[i] : null,
            ).split(','))
              if (a.trim().isNotEmpty) a.trim(),
          ],
          priceCents: price.isEmpty
              ? (form?.attributes['data-price'] == null
                    ? null
                    : parseEuroCents(form!.attributes['data-price']!))
              : parseEuroCents(price),
          ordered: ordered,
          deadlinePassed:
              form?.attributes['data-order-timelimit-expired'] == '1',
        ),
      );
    }
  }

  for (final row in rows) {
    final head = row.querySelector('td.menu-meal');
    final cells = row.querySelectorAll('td').where((c) => c != head).toList();
    if (head != null) {
      flush();
      line = _text(head);
      names = allergens = prices = forms = [];
    }
    if (cells.isEmpty) continue;
    final cls = cells.first.classes;
    if (cls.contains('menu-cell')) {
      names = cells;
    } else if (cls.contains('menu-allergens')) {
      allergens = cells;
    } else if (cls.contains('menu-price')) {
      prices = cells;
    } else if (cls.contains('order-button-cell')) {
      forms = cells;
    }
  }
  flush();

  offers.sort((a, b) => a.date.compareTo(b.date));
  return MealWeek(offers: offers, balanceCents: _balance(doc));
}

int? _balance(Document doc) {
  final e = doc.querySelector('.header-account-balance');
  return e == null ? null : parseEuroCents(_text(e));
}

/// Session with Caseda Schulmenü (form login with Django CSRF token).
class CasedaClient {
  final Uri baseUrl;
  final String username;
  final String password;
  final HttpClient _http = HttpClient()
    ..userAgent = 'Lumo'
    ..connectionTimeout = const Duration(seconds: 15);
  final Map<String, String> _cookies = {};

  CasedaClient({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  Future<(int, String, String?)> _request(
    String method,
    String path, {
    Map<String, String>? form,
  }) async {
    final url = baseUrl.resolve(path);
    final req = await _http.openUrl(method, url);
    req.followRedirects = false;
    if (_cookies.isNotEmpty) {
      req.headers.set(
        'cookie',
        _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
    req.headers.set('referer', baseUrl.resolve('/').toString());
    if (form != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.write(Uri(queryParameters: form).query);
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    for (final c in res.cookies) {
      _cookies[c.name] = c.value;
    }
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, body, res.headers.value('location'));
  }

  /// Logs in; throws [CasedaException] if the credentials are rejected.
  Future<void> login() async {
    final (_, start, _) = await _request('GET', '/');
    final token = html
        .parse(start)
        .querySelector('#login_form input[name="csrfmiddlewaretoken"]')
        ?.attributes['value'];
    if (token == null) throw const CasedaException('No login form found');
    final (status, _, location) = await _request(
      'POST',
      '/login/',
      form: {
        'csrfmiddlewaretoken': token,
        'username': username,
        'password': password,
      },
    );
    if (status != 302 || !(location ?? '').contains('/kunden')) {
      throw const CasedaException(
        'Login failed (wrong e-mail or password?)',
        isAuth: true,
      );
    }
  }

  /// Order page of [week] in [year] (ISO week numbers as used by the site).
  Future<MealWeek> week(int year, int week) async {
    final (status, body, _) = await _request(
      'GET',
      '/kunden/essen/$year/$week/',
    );
    if (status != 200) throw CasedaException('HTTP $status for week $week');
    return parseMealWeek(body);
  }

  Future<void> logout() async {
    try {
      await _request('GET', '/logout/');
    } on Object {
      // best effort
    }
  }

  void close() => _http.close();
}

/// ISO 8601 week of [date]: (week-based year, week number).
(int, int) isoWeek(DateTime date) {
  final d = DateTime.utc(date.year, date.month, date.day);
  final thursday = d.add(Duration(days: 4 - d.weekday));
  final first = DateTime.utc(thursday.year, 1, 1);
  return (thursday.year, thursday.difference(first).inDays ~/ 7 + 1);
}
