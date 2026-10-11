import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'relay_token.dart';

/// Whether the node takes traffic (set by the backend at each sync).
enum RelayStatus {
  active,

  /// Members already registered keep going; nobody new is let in.
  draining,

  /// Nothing is relayed.
  disabled,
}

class RelayStats {
  int rx = 0;
  int tx = 0;
  int forwarded = 0;
  int dropped = 0;
  int registrations = 0;
  int refusals = 0;
}

/// One member's bytes through the relay since the last [RelayServer.takeUsage].
typedef RelayUsage = ({int network, String vip, int bytes});

/// The LVR1 UDP relay (docs/RELAY_FLEET.md).
///
/// It routes sealed P2P packets between members of the same virtual
/// network that cannot punch through their NATs. It never sees plaintext:
/// it only reads the destination virtual IP and stamps the sender's, taken
/// from the sender's signed ticket.
class RelayServer {
  RelayServer({
    required this.nodeId,
    required List<int> secret,
    this.maxClients = 5000,
    DateTime Function()? clock,
  })  : _secret = List.unmodifiable(secret),
        _clock = clock ?? DateTime.now;

  static const List<int> magic = [0x4C, 0x56, 0x52, 0x31]; // LVR1
  static const Duration idleTimeout = Duration(seconds: 45);
  static const int maxFrame = 1600;
  static const int cookieBucketSeconds = 120;

  /// Smallest forward worth reading: relay header plus a sealed packet's
  /// header and tag. Anything we answer is smaller than this.
  static const int minForward = 9 + 49;

  final int nodeId;
  final List<int> _secret;
  final DateTime Function() _clock;
  int maxClients;
  RelayStatus status = RelayStatus.active;

  /// False when the node's budget is used up for new members.
  bool acceptNew = true;
  final RelayStats stats = RelayStats();

  RawDatagramSocket? _socket;
  final Queue<(List<int>, InternetAddress, int)> _queue = Queue();
  int _queued = 0;
  Timer? _sweepTimer;
  final Map<String, _Client> _byAddress = {};
  final Map<String, _Client> _byMember = {};
  final Map<String, _DayUsage> _day = {};
  final Map<String, int> _usage = {};
  final Map<String, DateTime> _lastNotice = {};

  int get port => _socket?.port ?? 0;
  int get clientCount => _byMember.length;

  Future<int> bind({InternetAddress? address, int port = 51821}) async {
    final socket =
        await RawDatagramSocket.bind(address ?? InternetAddress.anyIPv4, port);
    _socket = socket;
    for (final option in Platform.isLinux ? [8, 7] : [0x1002, 0x1001]) {
      try {
        socket.setRawOption(RawSocketOption.fromInt(
            RawSocketOption.levelSocket, option, 4 << 20));
      } catch (_) {}
    }
    socket.listen((event) {
      if (event == RawSocketEvent.write) return _flush();
      if (event != RawSocketEvent.read) return;
      while (identical(_socket, socket)) {
        final datagram = socket.receive();
        if (datagram == null) return;
        try {
          _onDatagram(datagram);
        } catch (_) {
          stats.dropped++;
        }
      }
    });
    _sweepTimer = Timer.periodic(const Duration(seconds: 15), (_) => sweep());
    return socket.port;
  }

  void close() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _socket?.close();
    _socket = null;
  }

  /// Bytes each member pushed through since the last call.
  List<RelayUsage> takeUsage() {
    final out = <RelayUsage>[
      for (final e in _usage.entries)
        (
          network: int.parse(e.key.substring(0, e.key.indexOf('|'))),
          vip: e.key.substring(e.key.indexOf('|') + 1),
          bytes: e.value,
        ),
    ];
    _usage.clear();
    return out;
  }

  /// Forgets idle and expired members (also run every 15 s).
  void sweep() {
    final now = _clock();
    final nowS = _seconds(now);
    for (final c in _byMember.values.toList()) {
      if (status == RelayStatus.disabled ||
          now.difference(c.lastSeen) > idleTimeout ||
          c.expires < nowS - 60) {
        _forget(c);
      }
    }
    _lastNotice.removeWhere(
        (_, at) => now.difference(at) > const Duration(seconds: 10));
    final today = _dayNumber(now);
    _day.removeWhere((_, d) => d.day != today);
  }

  void _onDatagram(Datagram d) {
    final b = d.data;
    stats.rx += b.length;
    if (b.length < 5 ||
        b[0] != magic[0] ||
        b[1] != magic[1] ||
        b[2] != magic[2] ||
        b[3] != magic[3]) {
      return;
    }
    switch (b[4]) {
      case 0x01:
        _register(d);
      case 0x02:
        _forward(d);
    }
  }

  void _register(Datagram d) {
    final b = d.data;
    if (b.length < 14 || b.length > 13 + 400) return;
    final now = _clock();
    final nowS = _seconds(now);
    if (!_cookieValid(b, d.address, d.port, nowS)) {
      // Prove you own that address first: 13 bytes back, less than came in.
      final cookie = _cookie(d.address, d.port, nowS ~/ cookieBucketSeconds);
      _send([...magic, 0x07, ...cookie], d.address, d.port);
      return;
    }
    final String text;
    try {
      text = utf8.decode(Uint8List.sublistView(b, 13));
    } catch (_) {
      return _refuse(d, 'bad-token');
    }
    final token = RelayToken.verify(text, _secret);
    if (token == null) return _refuse(d, 'bad-token');
    if (token.node != nodeId) return _refuse(d, 'wrong-node');
    if (token.expires <= nowS) return _refuse(d, 'expired');
    if (status == RelayStatus.disabled) return _refuse(d, 'full');

    final key = '${token.network}|${token.vip}';
    var client = _byMember[key];
    if (client == null &&
        (status == RelayStatus.draining ||
            !acceptNew ||
            _byMember.length >= maxClients)) {
      return _refuse(d, 'full');
    }
    final day = _dayUsage(key, now);
    if (token.dailyMb > 0 && day.bytes >= token.dailyMb * 1048576) {
      return _refuse(d, 'quota');
    }

    // One address belongs to one member; one member to one address (the
    // newest: NAT rebinding, phone changing networks).
    final addressKey = '${d.address.address}:${d.port}';
    final previous = _byAddress[addressKey];
    if (previous != null && previous != client) _forget(previous);
    if (client == null) {
      client = _Client(key, token.network, _vipBytes(token.vip), d.address,
          d.port, now);
      _byMember[key] = client;
      stats.registrations++;
    } else if (client.addressKey != addressKey) {
      _byAddress.remove(client.addressKey);
      client
        ..address = d.address
        ..port = d.port;
    }
    _byAddress[addressKey] = client;
    client
      ..expires = token.expires
      ..kbps = token.kbps
      ..dailyMb = token.dailyMb
      ..lastSeen = now;
    _send([...magic, 0x06, 0, idleTimeout.inSeconds], d.address, d.port);
  }

  void _forward(Datagram d) {
    final b = d.data;
    if (b.length < minForward || b.length > 9 + maxFrame) return;
    final now = _clock();
    final src = _byAddress['${d.address.address}:${d.port}'];
    if (src == null) {
      stats.dropped++;
      return _notice(d, 'unknown', now);
    }
    if (src.expires <= _seconds(now)) {
      _forget(src);
      stats.dropped++;
      return _notice(d, 'expired', now);
    }
    if (status == RelayStatus.disabled) {
      stats.dropped++;
      return;
    }
    src.lastSeen = now;
    final dst = _byMember['${src.network}|${b[5]}.${b[6]}.${b[7]}.${b[8]}'];
    if (dst == null || identical(dst, src)) {
      stats.dropped++;
      return;
    }
    final size = b.length - 9;
    if (!src.take(size, now)) {
      stats.dropped++;
      return;
    }
    final day = _dayUsage(src.key, now);
    if (src.dailyMb > 0 && day.bytes + size > src.dailyMb * 1048576) {
      stats.dropped++;
      return _notice(d, 'quota', now);
    }
    day.bytes += size;
    _usage[src.key] = (_usage[src.key] ?? 0) + size;

    final out = Uint8List(b.length)
      ..setRange(0, 5, b)
      ..setRange(5, 9, src.vip)
      ..setRange(9, b.length, b, 9);
    _send(out, dst.address, dst.port);
    stats.forwarded++;
  }

  void _forget(_Client c) {
    _byMember.remove(c.key);
    if (identical(_byAddress[c.addressKey], c)) _byAddress.remove(c.addressKey);
  }

  void _refuse(Datagram d, String reason) {
    stats.refusals++;
    _send([...magic, 0x05, ...utf8.encode(reason)], d.address, d.port);
  }

  /// A refusal to an address that hasn't proved itself: at most one per
  /// two seconds, and always smaller than [minForward].
  void _notice(Datagram d, String reason, DateTime now) {
    final key = '${d.address.address}:${d.port}';
    final last = _lastNotice[key];
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    if (_lastNotice.length > 50000) return;
    _lastNotice[key] = now;
    _refuse(d, reason);
  }

  /// `send` returns 0 when the socket buffer is full (and on Windows while
  /// the previous send is in flight): queue it and send on the write event.
  void _send(List<int> data, InternetAddress to, int port) {
    final socket = _socket;
    if (socket == null) return;
    if (_queue.isEmpty) {
      try {
        if (socket.send(data, to, port) > 0) {
          stats.tx += data.length;
          return;
        }
      } catch (_) {
        return;
      }
    }
    if (_queued + data.length > 8 << 20) {
      stats.dropped++;
      return;
    }
    _queue.add((data, to, port));
    _queued += data.length;
    socket.writeEventsEnabled = true;
  }

  void _flush() {
    final socket = _socket;
    if (socket == null) return;
    while (_queue.isNotEmpty) {
      final (data, to, port) = _queue.first;
      var sent = 0;
      try {
        sent = socket.send(data, to, port);
      } catch (_) {
        sent = -1;
      }
      if (sent == 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      _queue.removeFirst();
      _queued -= data.length;
      if (sent > 0) stats.tx += data.length;
    }
  }

  List<int> _cookie(InternetAddress address, int port, int bucket) => Hmac(
        sha256,
        _secret,
      ).convert(utf8.encode('c|${address.address}|$port|$bucket')).bytes.sublist(0, 8);

  bool _cookieValid(Uint8List b, InternetAddress address, int port, int nowS) {
    final bucket = nowS ~/ cookieBucketSeconds;
    for (final candidate in [bucket, bucket - 1]) {
      final expected = _cookie(address, port, candidate);
      var diff = 0;
      for (var i = 0; i < 8; i++) {
        diff |= expected[i] ^ b[5 + i];
      }
      if (diff == 0) return true;
    }
    return false;
  }

  _DayUsage _dayUsage(String key, DateTime now) {
    final today = _dayNumber(now);
    final usage = _day[key];
    if (usage != null && usage.day == today) return usage;
    return _day[key] = _DayUsage(today);
  }

  static int _seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  /// Days in Thai time, where daily caps reset at midnight.
  static int _dayNumber(DateTime t) => (_seconds(t) + 7 * 3600) ~/ 86400;

  static Uint8List _vipBytes(String vip) =>
      Uint8List.fromList(vip.split('.').map(int.parse).toList());
}

class _Client {
  _Client(this.key, this.network, this.vip, this.address, this.port,
      this.lastSeen);

  final String key;
  final int network;
  final Uint8List vip;
  InternetAddress address;
  int port;
  DateTime lastSeen;
  int expires = 0;
  int kbps = 0;
  int dailyMb = 0;
  double _tokens = 0;
  DateTime? _refilled;

  String get addressKey => '${address.address}:$port';

  /// Token bucket of one second at [kbps] (at least 64 KiB).
  bool take(int bytes, DateTime now) {
    if (kbps <= 0) return true;
    final rate = kbps * 125.0;
    final burst = max(rate, 65536.0);
    final last = _refilled;
    _tokens = last == null
        ? burst
        : min(burst,
            _tokens + rate * now.difference(last).inMicroseconds / 1e6);
    _refilled = now;
    if (_tokens < bytes) return false;
    _tokens -= bytes;
    return true;
  }
}

class _DayUsage {
  _DayUsage(this.day);
  final int day;
  int bytes = 0;
}
