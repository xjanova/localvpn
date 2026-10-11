import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Public address of a UDP socket as one STUN server sees it.
class StunMapping {
  final InternetAddress address;
  final int port;
  final String server;

  const StunMapping(this.address, this.port, this.server);

  String get endpoint => '${address.address}:$port';
}

/// How the NAT in front of us maps one local UDP port.
enum NatMapping {
  /// Same public port for every destination: hole punching works.
  endpointIndependent,

  /// A new public port per destination ("symmetric"): punching to another
  /// symmetric NAT fails, the relay carries the traffic.
  endpointDependent,

  /// No STUN answer at all (UDP blocked or offline).
  unknown,
}

/// Minimal RFC 5389 Binding client that shares the app's P2P UDP socket.
///
/// The socket's owner must pass every datagram to [handle] first; STUN
/// answers are consumed there and never reach the P2P layer. Asking from
/// the same socket is the whole point: the public port the server reports
/// is the one peers have to punch towards. (The old HTTP "stun" endpoint saw
/// the TCP port of an HTTPS request and the app guessed public = local port,
/// which is wrong behind almost every home router and CGNAT.)
class StunClient {
  StunClient(this.socket, {this.servers = defaultServers});

  final RawDatagramSocket socket;
  final List<(String, int)> servers;
  (String, int)? _lastGood;
  static const int _magicCookie = 0x2112A442;
  final Map<String, Completer<StunMapping?>> _pending = {};
  final Random _rng = Random.secure();

  static const List<(String, int)> defaultServers = [
    ('stun.l.google.com', 19302),
    ('stun.cloudflare.com', 3478),
    ('stun1.l.google.com', 19302),
    ('stun2.l.google.com', 19302),
  ];

  /// True when [d] was a STUN message (whether or not we were waiting).
  bool handle(Datagram d) {
    final b = d.data;
    if (b.length < 20 || (b[0] & 0xC0) != 0) return false;
    final cookie = (b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7];
    if (cookie != _magicCookie) return false;
    final type = (b[0] << 8) | b[1];
    final length = (b[2] << 8) | b[3];
    if (20 + length > b.length) return true;
    final txid = _hex(b, 8, 12);
    final waiter = _pending.remove(txid);
    if (waiter == null || waiter.isCompleted) return true;
    if (type != 0x0101) {
      waiter.complete(null); // error response
      return true;
    }
    waiter.complete(_parseMapped(b, 20, 20 + length, d.address.address));
    return true;
  }

  StunMapping? _parseMapped(Uint8List b, int start, int end, String server) {
    StunMapping? plain;
    var i = start;
    while (i + 4 <= end) {
      final attr = (b[i] << 8) | b[i + 1];
      final len = (b[i + 2] << 8) | b[i + 3];
      final v = i + 4;
      if (v + len > end) break;
      if ((attr == 0x0020 || attr == 0x0001) && len >= 8 && b[v + 1] == 0x01) {
        var port = (b[v + 2] << 8) | b[v + 3];
        final ip = Uint8List.fromList(b.sublist(v + 4, v + 8));
        if (attr == 0x0020) {
          port ^= _magicCookie >> 16;
          ip[0] ^= 0x21;
          ip[1] ^= 0x12;
          ip[2] ^= 0xA4;
          ip[3] ^= 0x42;
          return StunMapping(
              InternetAddress.fromRawAddress(ip), port, server);
        }
        plain = StunMapping(InternetAddress.fromRawAddress(ip), port, server);
      }
      i = v + ((len + 3) & ~3); // attributes are padded to 4 bytes
    }
    return plain;
  }

  /// One Binding request (with retries) to [host]:[port].
  Future<StunMapping?> query(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 1200),
    int attempts = 2,
  }) async {
    InternetAddress addr;
    try {
      addr = (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
              .timeout(const Duration(seconds: 3)))
          .first;
    } catch (_) {
      return null;
    }
    for (var a = 0; a < attempts; a++) {
      final tx = Uint8List(12);
      for (var i = 0; i < 12; i++) {
        tx[i] = _rng.nextInt(256);
      }
      final req = Uint8List(20)
        ..[0] = 0x00
        ..[1] = 0x01 // Binding Request
        ..[2] = 0
        ..[3] = 0
        ..[4] = 0x21
        ..[5] = 0x12
        ..[6] = 0xA4
        ..[7] = 0x42
        ..setRange(8, 20, tx);
      final key = _hex(tx, 0, 12);
      final c = Completer<StunMapping?>();
      _pending[key] = c;
      try {
        socket.send(req, addr, port);
      } catch (_) {
        _pending.remove(key);
        return null;
      }
      final r = await c.future.timeout(timeout, onTimeout: () => null);
      _pending.remove(key);
      if (r != null) return r;
    }
    return null;
  }

  /// Ask two different servers. The first answer is our public endpoint; if
  /// both answer with different ports the NAT maps per destination.
  Future<(StunMapping?, NatMapping)> discover() async {
    final answers = <StunMapping>[];
    for (final server in servers) {
      final m = await query(server.$1, server.$2);
      if (m != null) {
        answers.add(m);
        _lastGood ??= server;
      }
      if (answers.length >= 2) break;
    }
    if (answers.isEmpty) return (null, NatMapping.unknown);
    if (answers.length == 1) return (answers.first, NatMapping.unknown);
    final same = answers[0].port == answers[1].port &&
        answers[0].address.address == answers[1].address.address;
    return (
      answers.first,
      same ? NatMapping.endpointIndependent : NatMapping.endpointDependent,
    );
  }

  /// Our public endpoint again, from the server that answered last time.
  /// Also keeps the NAT mapping of the socket alive.
  Future<StunMapping?> refresh() async {
    final server = _lastGood ?? (servers.isEmpty ? null : servers.first);
    if (server == null) return null;
    return query(server.$1, server.$2, attempts: 1);
  }

  static String _hex(List<int> b, int start, int len) {
    final sb = StringBuffer();
    for (var i = start; i < start + len; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
