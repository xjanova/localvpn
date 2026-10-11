// The relay is its own package (tools/lvnode); these tests run it in-process
// against the real app code.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/models/member.dart';
import 'package:localvpn/services/p2p_crypto.dart';
import 'package:localvpn/services/p2p_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tools/lvnode/lib/src/relay_server.dart';
import '../tools/lvnode/lib/src/relay_token.dart';

const _node = 7;
const _net = 42;
const _vipA = '10.10.0.2';
const _vipB = '10.10.0.3';
final _secret = utf8.encode('node-secret-for-tests-0123456789');
final _loopback = InternetAddress.loopbackIPv4;

int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String _ticket(
  String vip, {
  int node = _node,
  int net = _net,
  int ttl = 600,
  int dailyMb = 0,
  List<int>? secret,
}) =>
    RelayToken.sign(
      node: node,
      network: net,
      vip: vip,
      expires: _now + ttl,
      dailyMb: dailyMb,
      secret: secret ?? _secret,
    );

Future<void> _until(bool Function() done, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: ${reason ?? ''}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A member whose public endpoint (as the server reports it) is a dead
/// port, so hole punching never works and only the relay is left.
class _Member {
  _Member(this.name, this.vip, this.identity)
      : service = P2pService(identity: identity, stunServers: const []) {
    service.configure(deviceId: 'device-$name', licenseKey: '');
    service.onPeerData = (vip, bytes) => packets.add((vip, bytes));
    service.onFileMessage = (vip, data) => files.add((vip, data));
  }

  final String name;
  final String vip;
  final P2pIdentity identity;
  final P2pService service;
  final packets = <(String, Uint8List)>[];
  final files = <(String, Uint8List)>[];

  NetworkMember self() => NetworkMember(
        displayName: name,
        virtualIp: vip,
        publicIp: '127.0.0.1',
        publicPort: service.localUdpPort,
        machineId: 'device-$name',
        p2pKey: identity.advert,
        reportsP2pKey: true,
      );

  NetworkMember unreachable(int deadPort) => NetworkMember(
        displayName: name,
        virtualIp: vip,
        publicIp: '127.0.0.1',
        publicPort: deadPort,
        machineId: 'device-$name',
        p2pKey: identity.advert,
        reportsP2pKey: true,
      );
}

/// A bare UDP client speaking LVR1 by hand.
class _Raw {
  _Raw._(this.socket);
  final RawDatagramSocket socket;
  final received = <Uint8List>[];

  static Future<_Raw> open() async {
    final s = await RawDatagramSocket.bind(_loopback, 0);
    final raw = _Raw._(s);
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = s.receive();
      if (d != null) raw.received.add(d.data);
    });
    return raw;
  }

  void send(List<int> bytes, int port) => socket.send(bytes, _loopback, port);

  /// Waits while the socket can't take it (Windows has one send in flight).
  Future<void> sendSure(List<int> bytes, int port) async {
    while (socket.send(bytes, _loopback, port) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<Uint8List> next(int type) async {
    await _until(() => received.any((d) => d.length > 4 && d[4] == type),
        reason: 'LVR1 type $type');
    final d = received.firstWhere((d) => d[4] == type);
    received.remove(d);
    return d;
  }

  void register(List<int> cookie, String token, int port) => send(
      [...RelayServer.magic, 0x01, ...cookie, ...utf8.encode(token)], port);

  /// Cookie round trip, then a real registration; returns the answer.
  Future<Uint8List> join(String token, int port) async {
    register(List.filled(8, 0), token, port);
    final challenge = await next(0x07);
    register(challenge.sublist(5, 13), token, port);
    await _until(() => received.any((d) => d[4] == 0x06 || d[4] == 0x05),
        reason: 'registration answer');
    final d = received.firstWhere((d) => d[4] == 0x06 || d[4] == 0x05);
    received.remove(d);
    return d;
  }

  Future<void> forward(String dst, int size, int port) => sendSure([
        ...RelayServer.magic,
        0x02,
        ...InternetAddress(dst).rawAddress,
        ...List.filled(size, 0xAB),
      ], port);

  void close() => socket.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RelayServer relay;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    relay = RelayServer(nodeId: _node, secret: _secret);
    await relay.bind(address: _loopback, port: 0);
  });
  tearDown(() => relay.close());

  test('members that cannot punch talk through the relay, sealed', () async {
    final dead = await RawDatagramSocket.bind(_loopback, 0);
    final a = _Member('alice', _vipA, await P2pIdentity.generate());
    final b = _Member('bob', _vipB, await P2pIdentity.generate());
    expect(await a.service.start('lan-party'), isTrue);
    expect(await b.service.start('lan-party'), isTrue);
    addTearDown(() async {
      await a.service.stop();
      await b.service.stop();
      dead.close();
    });

    for (final m in [a, b]) {
      m.service.setRelay(RelayInfo(
        host: '127.0.0.1',
        port: relay.port,
        token: _ticket(m.vip),
        node: 'th-test',
      ));
    }
    a.service.updatePeers([a.self(), b.unreachable(dead.port)]);
    b.service.updatePeers([b.self(), a.unreachable(dead.port)]);

    await _until(
      () =>
          a.service.pathOf(_vipB) == P2pPath.relay &&
          b.service.pathOf(_vipA) == P2pPath.relay,
      reason: 'relay path both ways',
    );
    expect(a.service.peers[_vipB]!.isDirectConnected, isFalse,
        reason: 'a relayed hello reply never makes a peer direct');
    expect(a.service.peers[_vipB]!.publicPort, dead.port,
        reason: 'nor moves its endpoint to the relay');
    expect(a.service.relayPeerCount, 1);

    final packet = Uint8List.fromList([0x45, 0, 0, 20, ...List.filled(16, 9)]);
    expect(await a.service.sendTunPacket(_vipB, packet), isTrue);
    await _until(() => b.packets.isNotEmpty, reason: 'relayed packet');
    expect(b.packets.single.$1, _vipA);
    expect(b.packets.single.$2, packet);

    final message = Uint8List.fromList(
        List.generate(20000, (i) => (i * 13) & 0xFF));
    expect(await b.service.sendFileMessage(_vipA, message), isTrue);
    await _until(() => a.files.isNotEmpty, reason: 'relayed file message');
    expect(a.files.single.$2, message);

    final usage = relay.takeUsage();
    expect(usage.map((u) => u.network).toSet(), {_net});
    expect(usage.map((u) => u.vip).toSet(), {_vipA, _vipB});
  });

  test('registration needs the cookie, a valid signature, this node and time',
      () async {
    final c = await _Raw.open();
    addTearDown(c.close);

    // No cookie: only a challenge comes back, smaller than the request.
    c.register(List.filled(8, 0), _ticket(_vipA), relay.port);
    final challenge = await c.next(0x07);
    expect(challenge.length, 13);
    expect(relay.clientCount, 0);
    final cookie = challenge.sublist(5, 13);

    Future<String> refusal(String token) async {
      c.register(cookie, token, relay.port);
      return utf8.decode((await c.next(0x05)).sublist(5));
    }

    expect(await refusal(_ticket(_vipA, secret: utf8.encode('another-secret-0123456'))),
        'bad-token');
    expect(await refusal('${_ticket(_vipA)}0'), 'bad-token');
    expect(await refusal(_ticket(_vipA, node: 8)), 'wrong-node');
    expect(await refusal(_ticket(_vipA, ttl: -5)), 'expired');
    expect(relay.clientCount, 0);

    c.register(cookie, _ticket(_vipA), relay.port);
    await c.next(0x06);
    expect(relay.clientCount, 1);
  });

  test('packets stay inside one network', () async {
    final x = await _Raw.open();
    final y = await _Raw.open();
    final z = await _Raw.open();
    addTearDown(() {
      x.close();
      y.close();
      z.close();
    });
    expect((await x.join(_ticket(_vipA), relay.port))[4], 0x06);
    expect((await y.join(_ticket(_vipB, net: 43), relay.port))[4], 0x06);

    await x.forward(_vipB, 80, relay.port);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(y.received, isEmpty, reason: 'another network, same virtual IP');

    expect((await z.join(_ticket(_vipB), relay.port))[4], 0x06);
    await x.forward(_vipB, 80, relay.port);
    final got = await z.next(0x02);
    expect(got.sublist(5, 9), InternetAddress(_vipA).rawAddress,
        reason: 'the relay stamps the sender from its ticket');
    expect(got.length, 9 + 80);
  });

  test('the daily cap stops forwarding and tells the sender', () async {
    final x = await _Raw.open();
    final z = await _Raw.open();
    addTearDown(() {
      x.close();
      z.close();
    });
    await x.join(_ticket(_vipA, dailyMb: 1), relay.port);
    await z.join(_ticket(_vipB), relay.port);

    for (var i = 0; i < 760; i++) {
      await x.forward(_vipB, 1400, relay.port);
    }
    final notice = await x.next(0x05);
    expect(utf8.decode(notice.sublist(5)), 'quota');
    expect(relay.stats.forwarded, lessThanOrEqualTo(1048576 ~/ 1400));
  });

  test('forwards from an unregistered address get a small notice', () async {
    final x = await _Raw.open();
    addTearDown(x.close);
    await x.forward(_vipB, 60, relay.port);
    final notice = await x.next(0x05);
    expect(utf8.decode(notice.sublist(5)), 'unknown');
    expect(notice.length, lessThan(RelayServer.minForward));
  });
}
