import 'package:dio/dio.dart';

import '../sph/errors.dart';

/// One line for the log that says what failed and where: the exception, its
/// causes (Dio: method, address without query, HTTP status) and the first
/// frames of the code that threw it. No passwords or personal data.
String describeFailure(Object error, {StackTrace? stack, int frames = 4}) {
  final parts = <String>[_describe(error)];
  Object? cause = error is SphException ? error.cause : null;
  var last = error;
  for (var depth = 0; cause != null && depth < 3; depth++) {
    parts.add('caused by ${_describe(cause)}');
    last = cause;
    cause = cause is SphException ? cause.cause : null;
  }
  final where = _frames(stack ?? _stackOf(last) ?? _stackOf(error), frames);
  if (where.isNotEmpty) parts.add('at $where');
  return parts.join(' | ');
}

StackTrace? _stackOf(Object e) => switch (e) {
  DioException() => e.stackTrace,
  Error() => e.stackTrace,
  _ => null,
};

String _describe(Object e) {
  if (e is DioException) {
    final uri = e.requestOptions.uri.replace(query: '');
    final status = e.response?.statusCode;
    return 'DioException(${e.type.name}) ${e.requestOptions.method} '
        '${uri.host}${uri.path}${status == null ? '' : ' status $status'}'
        '${e.message == null ? '' : ': ${_short(e.message!)}'}';
  }
  final text = e is SphException ? e.toString() : '${e.runtimeType}: $e';
  return _short(text);
}

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 300 ? '${one.substring(0, 300)}…' : one;
}

/// The first [count] frames of our own or liblanis' code ("file:line").
String _frames(StackTrace? trace, int count) {
  if (trace == null) return '';
  final found = <String>[];
  for (final line in trace.toString().split('\n')) {
    final m = RegExp(
      r'package:(liblanis|lumo_server)/(\S+?:\d+)',
    ).firstMatch(line);
    if (m != null) found.add('${m.group(1)}/${m.group(2)}');
    if (found.length >= count) break;
  }
  return found.join(' <- ');
}
