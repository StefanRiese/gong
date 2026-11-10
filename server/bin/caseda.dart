// Proof of concept: balance and own orders from Caseda Schulmenü.
//
// Credentials from the environment or server/.env:
//   CASEDA_URL=https://www.caseda-schulmenue.de
//   CASEDA_USERNAME=…  CASEDA_PASSWORD=…
//
//   dart run bin/caseda.dart [weeks]            balance and orders (default 3 weeks)
//   dart run bin/caseda.dart --summary [weeks]  counts only (for logs / debugging)

import 'dart:io';

import 'package:gong_server/gong_server.dart';

Future<void> main(List<String> args) async {
  final summary = args.contains('--summary');
  final rest = args.where((a) => a != '--summary').toList();
  final weeks = rest.isEmpty ? 3 : int.parse(rest.first);

  final env = loadEnv();
  final url = env['CASEDA_URL'] ?? 'https://www.caseda-schulmenue.de';
  final user = env['CASEDA_USERNAME'];
  final password = env['CASEDA_PASSWORD'];
  if (user == null || user.isEmpty || password == null || password.isEmpty) {
    stderr.writeln('CASEDA_USERNAME and CASEDA_PASSWORD needed');
    exit(2);
  }

  String euro(int cents) =>
      '${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')} €';
  const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

  final client = CasedaClient(
    baseUrl: Uri.parse(url),
    username: user,
    password: password,
  );
  try {
    await client.login();
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    int? balance;
    final orders = <MealOffer>[];
    for (var i = 0; i < weeks; i++) {
      final (year, week) = isoWeek(today.add(Duration(days: 7 * i)));
      final w = await client.week(year, week);
      balance ??= w.balanceCents;
      orders.addAll(w.offers.where((o) => o.ordered > 0));
    }
    final upcoming = orders.where((o) => !o.date.isBefore(start)).toList();

    if (summary) {
      stdout.writeln(
        'login ok; balance shown: ${balance != null}; '
        'orders in $weeks weeks: ${orders.length} '
        '(from today: ${upcoming.length})',
      );
      return;
    }
    stdout.writeln(
      'Guthaben: ${balance == null ? 'unbekannt' : euro(balance)}',
    );
    stdout.writeln(
      upcoming.isEmpty ? 'Keine Bestellungen ab heute.' : 'Bestellt:',
    );
    for (final o in upcoming) {
      stdout.writeln(
        '  ${days[o.date.weekday - 1]} ${o.date.day}.${o.date.month}.  '
        '${o.line}: ${o.name}'
        '${o.ordered > 1 ? ' (${o.ordered}×)' : ''}'
        '${o.priceCents == null ? '' : ' – ${euro(o.priceCents!)}'}',
      );
    }
  } on CasedaException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } finally {
    await client.logout();
    client.close();
  }
}
