import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// One question of a DNS query.
class DnsQuestion {
  final String name; // lower case, without trailing dot
  final int type;
  final bool unicast; // QU bit: the sender wants a unicast reply
  const DnsQuestion(this.name, this.type, {this.unicast = false});
}

/// Questions of an mDNS query packet; empty for responses and broken packets.
List<DnsQuestion> parseDnsQuestions(Uint8List data) {
  try {
    if (data.length < 12) return const [];
    final b = ByteData.sublistView(data);
    if (b.getUint16(2) & 0x8000 != 0) return const []; // a response
    final count = b.getUint16(4);
    var pos = 12;
    final out = <DnsQuestion>[];
    for (var i = 0; i < count; i++) {
      final labels = <String>[];
      var p = pos;
      var end = -1; // position after the name in the packet (first pointer)
      for (var hops = 0; ; hops++) {
        if (hops > 32 || p >= data.length) return const [];
        final len = data[p];
        if (len == 0) {
          if (end < 0) end = p + 1;
          break;
        }
        if (len & 0xC0 == 0xC0) {
          if (p + 1 >= data.length) return const [];
          if (end < 0) end = p + 2;
          p = ((len & 0x3F) << 8) | data[p + 1];
          continue;
        }
        if (len > 63 || p + 1 + len > data.length) return const [];
        labels.add(String.fromCharCodes(data.sublist(p + 1, p + 1 + len)));
        p += 1 + len;
      }
      if (end + 4 > data.length) return const [];
      final cls = b.getUint16(end + 2);
      if (cls & 0x7FFF == 1) {
        out.add(
          DnsQuestion(
            labels.join('.').toLowerCase(),
            b.getUint16(end),
            unicast: cls & 0x8000 != 0,
          ),
        );
      }
      pos = end + 4;
    }
    return out;
  } on RangeError {
    return const [];
  }
}

/// mDNS response with A records of [name] for [addresses] ([ttl] 0: goodbye).
/// [id] is 0 for multicast answers and the query id for legacy unicast ones.
Uint8List buildMdnsAnswer(
  String name,
  List<InternetAddress> addresses, {
  int ttl = 120,
  int id = 0,
}) {
  final v4 = addresses.where((a) => a.type == InternetAddressType.IPv4);
  final out = BytesBuilder();
  void u16(int v) => out.add([v >> 8 & 0xFF, v & 0xFF]);
  u16(id);
  u16(0x8400); // response, authoritative
  u16(0);
  u16(v4.length);
  u16(0);
  u16(0);
  final labels = <int>[];
  for (final l in name.split('.')) {
    labels
      ..add(l.length)
      ..addAll(l.codeUnits);
  }
  labels.add(0);
  for (final a in v4) {
    out.add(labels);
    u16(1); // A
    u16(0x8001); // IN, cache flush
    u16(ttl >> 16);
    u16(ttl & 0xFFFF);
    u16(4);
    out.add(a.rawAddress);
  }
  return out.toBytes();
}

List<int> _encodeName(String name) {
  final out = <int>[];
  for (final l in name.split('.')) {
    out
      ..add(l.length)
      ..addAll(l.codeUnits);
  }
  return out..add(0);
}

/// Answer to an AAAA query for a name that only has A records: an NSEC record
/// saying so (RFC 6762 §6.1), with the A records as additional data.
/// Without it Windows waits for the missing AAAA answer and fails.
Uint8List buildMdnsNoAaaa(
  String name,
  List<InternetAddress> addresses, {
  int ttl = 120,
  int id = 0,
}) {
  final v4 = addresses.where((a) => a.type == InternetAddressType.IPv4);
  final out = BytesBuilder();
  void u16(int v) => out.add([v >> 8 & 0xFF, v & 0xFF]);
  final labels = _encodeName(name);
  u16(id);
  u16(0x8400);
  u16(0);
  u16(1);
  u16(0);
  u16(v4.length);
  out.add(labels);
  u16(47); // NSEC
  u16(0x8001);
  u16(ttl >> 16);
  u16(ttl & 0xFFFF);
  u16(labels.length + 3);
  out
    ..add(labels)
    ..add([0, 1, 0x40]); // window 0, one byte, type 1 (A)
  for (final a in v4) {
    out.add(labels);
    u16(1);
    u16(0x8001);
    u16(ttl >> 16);
    u16(ttl & 0xFFFF);
    u16(4);
    out.add(a.rawAddress);
  }
  return out.toBytes();
}

/// Minimal mDNS responder: answers A queries for `<label>.local` with the
/// IPv4 addresses of this machine, so the server is reachable as
/// `http://lumo.local:8080`. Best effort: failures only mean no mDNS name.
class MdnsResponder {
  static final _group = InternetAddress('224.0.0.251');
  static const _port = 5353;

  final String hostname; // e.g. lumo.local
  final RawDatagramSocket _socket;
  final Future<List<InternetAddress>> Function() _addresses;
  final void Function(String) _log;
  StreamSubscription<RawSocketEvent>? _sub;

  MdnsResponder._(this.hostname, this._socket, this._addresses, this._log);

  /// Addresses worth announcing: IPv4, not loopback / link-local.
  ///
  /// Some containers refuse listing interfaces ("Bad value for ai_flags");
  /// then Linux's own address table is read instead.
  static Future<List<InternetAddress>> localAddresses() async {
    final out = <InternetAddress>[];
    try {
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) out.add(a);
        }
      }
      return out;
    } on SocketException {
      try {
        return parseFibTrie(await File('/proc/net/fib_trie').readAsString());
      } on Object {
        return const [];
      }
    }
  }

  /// Local IPv4 addresses from `/proc/net/fib_trie` (the `/32 host LOCAL`
  /// entries), without loopback and link-local ones.
  static List<InternetAddress> parseFibTrie(String text) {
    final out = <String>{};
    String? last;
    for (final line in text.split('\n')) {
      final m = RegExp(r'\|--\s+(\d+\.\d+\.\d+\.\d+)').firstMatch(line);
      if (m != null) {
        last = m.group(1);
      } else if (last != null && line.contains('/32 host LOCAL')) {
        out.add(last);
      }
    }
    return [
      for (final a in out)
        if (InternetAddress.tryParse(a) case final ip?
            when !ip.isLoopback && !ip.isLinkLocal)
          ip,
    ];
  }

  /// Starts answering for [label].local; null when that is not possible.
  static Future<MdnsResponder?> start(
    String label, {
    required void Function(String) log,
    Future<List<InternetAddress>> Function()? addresses,
  }) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      socket.multicastLoopback = false;
      var joined = 0;
      try {
        for (final i in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        )) {
          if (i.addresses.every((a) => a.isLoopback)) continue;
          try {
            socket.joinMulticast(_group, i);
            joined++;
          } on Object {
            // interface without multicast support
          }
        }
      } on SocketException {
        // Interfaces cannot be listed here: let the system pick one.
        try {
          socket.joinMulticast(_group);
          joined++;
        } on Object {
          // handled below
        }
      }
      if (joined == 0) {
        socket.close();
        log('mDNS: no network interface with multicast, $label.local is off');
        return null;
      }
      final r = MdnsResponder._(
        '$label.local',
        socket,
        addresses ?? localAddresses,
        log,
      );
      r._sub = socket.listen(r._onEvent);
      unawaited(r._announce());
      return r;
    } on Object catch (e) {
      log('mDNS: $label.local is off ($e)');
      return null;
    }
  }

  Future<void> _announce() async {
    for (var i = 0; i < 2; i++) {
      final addrs = await _addresses();
      if (addrs.isNotEmpty) {
        _socket.send(buildMdnsAnswer(hostname, addrs), _group, _port);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final d = _socket.receive();
    if (d == null) return;
    final asked = parseDnsQuestions(
      d.data,
    ).where((q) => q.name == hostname && (q.type == 1 || q.type == 255));
    if (asked.isEmpty) return;
    unawaited(_reply(d, asked.first.unicast));
  }

  Future<void> _reply(Datagram d, bool unicast, {bool noAaaa = false}) async {
    try {
      final addrs = await _addresses();
      if (addrs.isEmpty) return;
      final legacy = d.port != _port; // plain DNS client, not an mDNS stack
      final build = noAaaa ? buildMdnsNoAaaa : buildMdnsAnswer;
      if (legacy || unicast) {
        final id = legacy ? (d.data[0] << 8 | d.data[1]) : 0;
        _socket.send(build(hostname, addrs, id: id), d.address, d.port);
      } else {
        _socket.send(build(hostname, addrs), _group, _port);
      }
    } on Object catch (e) {
      _log('mDNS: cannot answer ($e)');
    }
  }

  /// Withdraws the name (goodbye packet) and closes the socket.
  Future<void> stop() async {
    try {
      final addrs = await _addresses();
      if (addrs.isNotEmpty) {
        _socket.send(buildMdnsAnswer(hostname, addrs, ttl: 0), _group, _port);
      }
    } on Object {
      // closing anyway
    }
    await _sub?.cancel();
    _socket.close();
  }
}
