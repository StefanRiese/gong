// WebUntis (Untis GmbH): changed lessons of the own timetable. Read-only.
//
// Uses the REST interface of the WebUntis web app
// (`/WebUntis/api/rest/view/v1/timetable/entries`): unlike the old JSON-RPC
// interface it also shows teachers, substitutes and room changes for class
// accounts (e.g. "klasse5e"). Login like the web app; period numbers from the
// time grid (JSON-RPC, same session).

import 'dart:convert';
import 'dart:io';

/// A lesson that WebUntis marks as changed.
class UntisChange {
  final DateTime date;

  /// Periods as in the Schulportal ("3" or "3 - 4"), null if the time does
  /// not match the time grid.
  final String? period;
  final String start;
  final String end;

  /// "Entfall", "Vertretung", "Raumänderung", "Änderung".
  final String type;
  final String? subject;

  /// Teacher of the regular lesson (removed) and the substitute (added).
  final String? teacher;
  final String? substitute;
  final String? room;
  final String? previousRoom;
  final String? note;

  const UntisChange({
    required this.date,
    required this.period,
    required this.start,
    required this.end,
    required this.type,
    this.subject,
    this.teacher,
    this.substitute,
    this.room,
    this.previousRoom,
    this.note,
  });

  factory UntisChange.fromJson(Map<String, Object?> j) => UntisChange(
    date: DateTime.parse(j['date'] as String),
    period: j['period'] as String?,
    start: j['start'] as String,
    end: j['end'] as String,
    type: j['type'] as String,
    subject: j['subject'] as String?,
    teacher: j['teacher'] as String?,
    substitute: j['substitute'] as String?,
    room: j['room'] as String?,
    previousRoom: j['previousRoom'] as String?,
    note: j['note'] as String?,
  );

  Map<String, Object?> toJson() => {
    'date': date.toIso8601String().substring(0, 10),
    'period': period,
    'start': start,
    'end': end,
    'type': type,
    'subject': subject,
    'teacher': teacher,
    'substitute': substitute,
    'room': room,
    'previousRoom': previousRoom,
    'note': note,
  };

  @override
  String toString() => [
    '${date.toIso8601String().substring(0, 10)} ${period ?? '$start-$end'}',
    type,
    ?subject,
    if (teacher != null || substitute != null)
      '${teacher ?? '?'} → ${substitute ?? '—'}',
    if (previousRoom != null) 'Raum $previousRoom → ${room ?? '—'}',
    ?note,
  ].join(' · ');
}

/// Changed lessons of the own class (what is kept in the cache).
class UntisSnapshot {
  /// Class of the WebUntis account, e.g. "05eG".
  final String className;
  final List<UntisChange> changes;

  const UntisSnapshot({required this.className, required this.changes});

  factory UntisSnapshot.fromJson(Map<String, Object?> j) => UntisSnapshot(
    className: j['className'] as String? ?? '',
    changes: [
      for (final c in j['changes'] as List? ?? const [])
        UntisChange.fromJson(c as Map<String, Object?>),
    ],
  );

  Map<String, Object?> toJson() => {
    'className': className,
    'changes': [for (final c in changes) c.toJson()],
  };
}

/// What the sync needs from WebUntis (tests: fake).
abstract interface class UntisGateway {
  /// Changes of the own class from [today] on.
  Future<UntisSnapshot> load(DateTime today);
}

class UntisException implements Exception {
  final String message;
  final bool isAuth;
  const UntisException(this.message, {this.isAuth = false});
  @override
  String toString() => 'UntisException: $message';
}

/// 745 → "07:45".
String untisTime(int v) =>
    '${(v ~/ 100).toString().padLeft(2, '0')}:${(v % 100).toString().padLeft(2, '0')}';

/// Turns the `days` of a `timetable/entries` response into changes. Regular
/// lessons are skipped. [periodByStart]/[periodByEnd] map "HH:MM" to periods.
List<UntisChange> mapUntisEntries(
  Map<String, Object?> json, {
  Map<String, int> periodByStart = const {},
  Map<String, int> periodByEnd = const {},
}) {
  final out = <UntisChange>[];
  for (final day in (json['days'] as List? ?? const []).cast<Map>()) {
    for (final g in (day['gridEntries'] as List? ?? const []).cast<Map>()) {
      final status = g['status'] as String?;
      if (status != 'CANCELLED' && status != 'CHANGED') continue;

      // position1..7: {current, removed} of type TEACHER, SUBJECT, ROOM,
      // CLASS, … with status REGULAR / ADDED / REMOVED.
      final current = <String, List<String>>{};
      final removed = <String, List<String>>{};
      void add(Map<String, List<String>> into, Object? x) {
        if (x is! Map) return;
        final name = x['shortName'] as String?;
        if (name == null || name.isEmpty) return;
        (into['${x['type']}:${x['status']}'] ??= []).add(name);
      }

      for (var i = 1; i <= 7; i++) {
        for (final e in (g['position$i'] as List? ?? const []).cast<Map>()) {
          add(current, e['current']);
          add(removed, e['removed']);
        }
      }
      String? names(Map<String, List<String>> m, String type, String status) =>
          m['$type:$status']?.join(', ');

      final teacher = names(removed, 'TEACHER', 'REMOVED');
      final substitute = names(current, 'TEACHER', 'ADDED');
      final previousRoom = names(removed, 'ROOM', 'REMOVED');
      final newRoom = names(current, 'ROOM', 'ADDED');
      final room = newRoom ?? names(current, 'ROOM', 'REGULAR');
      final subject =
          names(current, 'SUBJECT', 'REGULAR') ??
          names(current, 'SUBJECT', 'ADDED') ??
          names(removed, 'SUBJECT', 'REMOVED');
      final type = status == 'CANCELLED'
          ? 'Entfall'
          : teacher != null || substitute != null
          ? 'Vertretung'
          : previousRoom != null || newRoom != null
          ? 'Raumänderung'
          : 'Änderung';

      final note = [g['substitutionText'], g['notesAll']]
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty && s != '-')
          .join(' · ');
      final duration = g['duration'] as Map;
      final startAt = DateTime.parse(duration['start'] as String);
      final endAt = DateTime.parse(duration['end'] as String);
      String hm(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      final from = periodByStart[hm(startAt)];
      final to = periodByEnd[hm(endAt)];
      out.add(
        UntisChange(
          date: DateTime(startAt.year, startAt.month, startAt.day),
          period: from == null
              ? null
              : (to == null || to == from ? '$from' : '$from - $to'),
          start: hm(startAt),
          end: hm(endAt),
          type: type,
          subject: subject,
          teacher: teacher,
          substitute: substitute,
          room: room,
          previousRoom: previousRoom,
          note: note.isEmpty ? null : note,
        ),
      );
    }
  }
  out.sort((a, b) {
    final d = a.date.compareTo(b.date);
    return d != 0 ? d : a.start.compareTo(b.start);
  });
  return out;
}

/// Client for one WebUntis school (login like the web app).
class UntisClient {
  final String server;
  final String school;
  final String username;
  final String password;
  final HttpClient _http = HttpClient()
    ..userAgent = 'Gong'
    ..connectionTimeout = const Duration(seconds: 15);
  final Map<String, String> _cookies = {};
  String? _token;

  /// Class of the account (id, name) after [login].
  (int, String)? klasse;

  UntisClient({
    required this.server,
    required this.school,
    required this.username,
    required this.password,
  });

  Future<(int, String)> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String>? form,
    Object? json,
    bool bearer = false,
  }) async {
    final req = await _http.openUrl(method, Uri.https(server, path, query));
    req.followRedirects = false;
    req.headers.set('accept', 'application/json');
    if (_cookies.isNotEmpty) {
      req.headers.set(
        'cookie',
        _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
    if (bearer && _token != null) {
      req.headers.set('authorization', 'Bearer $_token');
    }
    if (form != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.write(Uri(queryParameters: form).query);
    } else if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    for (final c in res.cookies) {
      _cookies[c.name] = c.value;
    }
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  /// GET of a REST endpoint with the API token; decoded JSON.
  Future<Map<String, Object?>> _rest(
    String path,
    Map<String, String> query,
  ) async {
    final (status, body) = await _request(
      'GET',
      path,
      query: query,
      bearer: true,
    );
    if (status == 401 || status == 403) {
      throw UntisException('Not allowed ($status)', isAuth: true);
    }
    if (status != 200) throw UntisException('HTTP $status for $path');
    return jsonDecode(body) as Map<String, Object?>;
  }

  Future<void> login() async {
    final (status, body) = await _request(
      'POST',
      '/WebUntis/j_spring_security_check',
      form: {
        'school': school,
        'j_username': username,
        'j_password': password,
        'token': '',
      },
    );
    if (status != 200 || !body.contains('SUCCESS')) {
      throw const UntisException('Login failed', isAuth: true);
    }
    final (ts, token) = await _request('GET', '/WebUntis/api/token/new');
    if (ts != 200 || token.isEmpty) {
      throw const UntisException('No API token', isAuth: true);
    }
    _token = token.trim();
    final filter = await _rest('/WebUntis/api/rest/view/v1/timetable/filter', {
      'resourceType': 'CLASS',
      'timetableType': 'MY_TIMETABLE',
    });
    final pre = filter['preSelected'] as Map<String, Object?>?;
    if (pre == null) {
      throw const UntisException('No own class for this account');
    }
    klasse = (pre['id'] as int, pre['shortName'] as String? ?? '');
  }

  /// Periods by start and end time ("HH:MM"), from the time grid.
  Future<(Map<String, int>, Map<String, int>)> timeGrid() async {
    final (status, body) = await _request(
      'POST',
      '/WebUntis/jsonrpc.do',
      query: {'school': school},
      json: {
        'id': '1',
        'method': 'getTimegridUnits',
        'params': <String, Object?>{},
        'jsonrpc': '2.0',
      },
    );
    if (status != 200) throw UntisException('HTTP $status for time grid');
    final days =
        (jsonDecode(body) as Map<String, Object?>)['result'] as List? ??
        const [];
    final byStart = <String, int>{};
    final byEnd = <String, int>{};
    if (days.isNotEmpty) {
      final units = (days.first as Map)['timeUnits'] as List;
      for (final (i, u) in units.indexed) {
        byStart[untisTime((u as Map)['startTime'] as int)] = i + 1;
        byEnd[untisTime(u['endTime'] as int)] = i + 1;
      }
    }
    return (byStart, byEnd);
  }

  /// Raw `timetable/entries` of the own class.
  Future<Map<String, Object?>> entries(DateTime from, DateTime to) {
    String d(DateTime x) => x.toIso8601String().substring(0, 10);
    return _rest('/WebUntis/api/rest/view/v1/timetable/entries', {
      'start': d(from),
      'end': d(to),
      'resourceType': 'CLASS',
      'resources': '${klasse!.$1}',
      'periodTypes': '',
      'timetableType': 'MY_TIMETABLE',
    });
  }

  /// Changes of the own class from [from] for [days] days.
  Future<List<UntisChange>> changes(DateTime from, {int days = 14}) async {
    final (byStart, byEnd) = await timeGrid();
    final json = await entries(from, from.add(Duration(days: days - 1)));
    return mapUntisEntries(json, periodByStart: byStart, periodByEnd: byEnd);
  }

  Future<void> logout() async {
    if (_token == null) return;
    try {
      await _request('POST', '/WebUntis/j_spring_security_logout');
    } catch (_) {
      // Best effort.
    }
    _token = null;
  }

  void close() => _http.close(force: true);
}

/// [UntisGateway] for a WebUntis school: logs in, reads [days] days, logs out.
class UntisWebGateway implements UntisGateway {
  final String server;
  final String school;
  final String username;
  final String password;
  final int days;

  UntisWebGateway({
    required this.server,
    required this.school,
    required this.username,
    required this.password,
    this.days = 21,
  });

  @override
  Future<UntisSnapshot> load(DateTime today) async {
    final client = UntisClient(
      server: server,
      school: school,
      username: username,
      password: password,
    );
    try {
      await client.login();
      final changes = await client.changes(
        DateTime(today.year, today.month, today.day),
        days: days,
      );
      return UntisSnapshot(
        className: client.klasse?.$2 ?? '',
        changes: changes,
      );
    } on UntisException {
      rethrow;
    } on Object catch (e) {
      // Network, timeout or unexpected data.
      throw UntisException('WebUntis not reachable: ${e.runtimeType}');
    } finally {
      await client.logout();
      client.close();
    }
  }
}
