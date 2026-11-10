import 'dart:io';
import 'dart:typed_data';

import 'package:lumo_server/src/net/mdns.dart';
import 'package:test/test.dart';

Uint8List query(String name, int type, {int cls = 1}) {
  final b = BytesBuilder()..add([0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final l in name.split('.')) {
    b
      ..addByte(l.length)
      ..add(l.codeUnits);
  }
  b
    ..addByte(0)
    ..add([type >> 8, type & 0xFF, cls >> 8, cls & 0xFF]);
  return b.toBytes();
}

void main() {
  fibTest();
  nsecTest();
  test('parses the question of a query', () {
    final q = parseDnsQuestions(query('Lumo.local', 1));
    expect(q, hasLength(1));
    expect(q.single.name, 'lumo.local');
    expect(q.single.type, 1);
    expect(q.single.unicast, isFalse);
    expect(
      parseDnsQuestions(query('lumo.local', 1, cls: 0x8001)).single.unicast,
      isTrue,
    );
  });

  test('ignores responses and broken packets', () {
    final response = query('lumo.local', 1)..[2] = 0x84;
    expect(parseDnsQuestions(response), isEmpty);
    expect(parseDnsQuestions(Uint8List(5)), isEmpty);
    final cut = query('lumo.local', 1).sublist(0, 16);
    expect(parseDnsQuestions(cut), isEmpty);
  });

  test('answer holds one A record per IPv4 address', () {
    final a = buildMdnsAnswer('lumo.local', [
      InternetAddress('192.168.1.24'),
      InternetAddress('10.0.0.2'),
    ]);
    final b = ByteData.sublistView(a);
    expect(b.getUint16(2), 0x8400);
    expect(b.getUint16(6), 2);
    expect(a.sublist(a.length - 4), [10, 0, 0, 2]);
    expect(a.sublist(12, 18), [4, ...'lumo'.codeUnits, 5].sublist(0, 6));
  });
}

void nsecTest() {
  test('AAAA query gets an NSEC record saying only A exists', () {
    final a = buildMdnsNoAaaa('lumo.local', [InternetAddress('192.168.1.24')]);
    final b = ByteData.sublistView(a);
    expect(b.getUint16(6), 1); // answers
    expect(b.getUint16(10), 1); // additional: the A record
    expect(a.sublist(a.length - 4), [192, 168, 1, 24]);
    expect(String.fromCharCodes(a), contains('lumo'));
  });
}

void fibTest() {
  test('reads local addresses from fib_trie', () {
    const text = '''
Main:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 192.168.1.0/24 2 0 2
        |-- 192.168.1.0
           /32 link BROADCAST
        |-- 192.168.1.24
           /32 host LOCAL
        |-- 192.168.1.255
           /32 link BROADCAST
  +-- 127.0.0.0/8 2 0 2
     |-- 127.0.0.1
        /32 host LOCAL
''';
    expect(MdnsResponder.parseFibTrie(text).map((a) => a.address), [
      '192.168.1.24',
    ]);
  });
}
