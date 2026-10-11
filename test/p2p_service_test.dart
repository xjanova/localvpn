import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/models/member.dart';
import 'package:localvpn/services/p2p_crypto.dart';
import 'package:localvpn/services/p2p_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _vipA = '10.10.0.2';
const _vipB = '10.10.0.3';
const _vipOld = '10.10.0.9';

/// Two members on this machine talking over real UDP sockets. The test
/// binding answers every HTTP call (STUN, signaling, relay) with 400, so
/// only the direct path is exercised.
class _Node {
  _Node(this.name, this.vip, this.identity)
    : service = P2pService(identity: identity, stunServers: const []) {
    service.configure(deviceId: 'device-$name', licenseKey: '');
    service.onPeerData = (vip, data) => data$.add((vip, data));
    service.onFileMessage = (vip, data) => files.add((vip, data));
  }

  final String name;
  final String vip;
  final P2pIdentity identity;
  final P2pService service;
  final data$ = StreamController<(String, Uint8List)>.broadcast();
  final files = <(String, Uint8List)>[];

  int get port => service.localUdpPort!;

  NetworkMember self() => NetworkMember(
    displayName: name,
    virtualIp: vip,
    publicIp: '127.0.0.1',
    publicPort: port,
    machineId: 'device-$name',
    p2pKey: identity.advert,
    reportsP2pKey: true,
  );

  NetworkMember asPeer({String? advert, bool reportsKey = true}) =>
      NetworkMember(
        displayName: name,
        virtualIp: vip,
        publicIp: '127.0.0.1',
        publicPort: port,
        machineId: 'device-$name',
        p2pKey: advert ?? identity.advert,
        reportsP2pKey: reportsKey,
      );
}

Future<void> _until(bool Function() done, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting: ${reason ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Node a;
  late _Node b;
  late RawDatagramSocket stranger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    a = _Node('alice', _vipA, await P2pIdentity.generate());
    b = _Node('bob', _vipB, await P2pIdentity.generate());
    expect(await a.service.start('lan-party'), isTrue);
    expect(await b.service.start('lan-party'), isTrue);
    stranger = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    stranger.close();
    await a.service.stop();
    await b.service.stop();
  });

  Future<void> connect() async {
    a.service.updatePeers([a.self(), b.asPeer()]);
    b.service.updatePeers([b.self(), a.asPeer()]);
    await _until(
      () =>
          a.service.peers[_vipB]?.isDirectConnected == true &&
          b.service.peers[_vipA]?.isDirectConnected == true,
      reason: 'hole punch',
    );
  }

  test('members connect directly and exchange encrypted traffic', () async {
    await connect();
    expect(a.service.peers[_vipB]!.security, P2pPeerSecurity.encrypted);

    final ipPacket = Uint8List.fromList([
      0x45,
      0,
      0,
      20,
      ...List.filled(16, 7),
    ]);
    final received = b.data$.stream.first;
    expect(await a.service.sendToPeer(_vipB, ipPacket), isTrue);
    final (fromVip, data) = await received.timeout(const Duration(seconds: 5));
    expect(fromVip, _vipA);
    expect(data, ipPacket);

    final msg = utf8.encode('LVPN_FILE_CANCEL:abc');
    expect(await b.service.sendFileMessage(_vipA, msg), isTrue);
    await _until(() => a.files.isNotEmpty, reason: 'file message');
    expect(a.files.single.$1, _vipB);
    expect(a.files.single.$2, msg);
    expect(a.service.securityNotice, isNull);
  });

  test('plaintext and forged datagrams are dropped', () async {
    await connect();
    var delivered = 0;
    final sub = b.data$.stream.listen((_) => delivered++);

    // The old wire format: 4-byte virtual IP header, then the IP packet.
    stranger.send(
      [10, 10, 0, 3, 0x45, 0, 0, 20, 1, 2, 3, 4],
      InternetAddress.loopbackIPv4,
      b.port,
    );
    stranger.send(
      utf8.encode('LVPN_FILE_CANCEL:abc'),
      InternetAddress.loopbackIPv4,
      b.port,
    );
    // A v2 packet from someone who has Bob's public key but not Alice's
    // private key, claiming to be Alice in a newer session, addressed to
    // Bob's real session: only the tag can give it away.
    final mallory = await P2pIdentity.generate();
    final forged =
        P2pCrypto(
          identity: mallory,
          networkSlug: 'lan-party',
          localSession: 1 << 62,
        ).seal(
          peerKey: b.identity.publicKey,
          senderVirtualIp: _vipA,
          type: P2pPacketType.data,
          receiverSession: b.service.localSession!,
          payload: [0x45, 0, 0, 20],
        );
    stranger.send(forged, InternetAddress.loopbackIPv4, b.port);

    // Real traffic still flows afterwards.
    final ok = b.data$.stream.first;
    await a.service.sendToPeer(_vipB, Uint8List.fromList([0x45, 1]));
    await ok.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    expect(delivered, 1);
    expect(b.files, isEmpty);
  });

  test('nothing is sent to a member whose app predates encryption', () async {
    // The server keeps keys, and this member never sent one.
    final old = NetworkMember(
      displayName: 'Old Phone',
      virtualIp: _vipOld,
      publicIp: '127.0.0.1',
      publicPort: stranger.port,
      machineId: 'device-old',
      reportsP2pKey: true,
    );
    a.service.updatePeers([a.self(), old]);

    var bytesSeen = 0;
    stranger.listen((e) {
      if (e == RawSocketEvent.read) {
        bytesSeen += stranger.receive()?.data.length ?? 0;
      }
    });
    expect(
      await a.service.sendToPeer(_vipOld, Uint8List.fromList([1, 2])),
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(bytesSeen, 0);
    expect(a.service.peers[_vipOld]!.security, P2pPeerSecurity.peerOutdated);
    expect(a.service.relayPeerCount, 0);
    expect(a.service.securityNotice, contains('Old Phone'));
    expect(
      a.service.securityNotice,
      contains('อัปเดตแอปเพื่อเชื่อมต่อกับเพื่อนในวงนี้'),
    );
  });

  test(
    'an old server: plaintext punch from a member marks it outdated',
    () async {
      // No p2p_key field at all: the server predates keys, so the member may
      // still turn out to have one.
      final unknown = NetworkMember(
        displayName: 'Old Phone',
        virtualIp: _vipOld,
        publicIp: '127.0.0.1',
        publicPort: stranger.port,
        machineId: 'device-old',
      );
      a.service.updatePeers([a.self(), unknown]);
      expect(a.service.peers[_vipOld]!.security, P2pPeerSecurity.pendingKey);
      expect(a.service.securityNotice, isNull);

      stranger.send(
        utf8.encode('LVPN_PUNCH:127.0.0.1:${stranger.port}'),
        InternetAddress.loopbackIPv4,
        a.port,
      );
      await _until(
        () =>
            a.service.peers[_vipOld]!.security == P2pPeerSecurity.peerOutdated,
        reason: 'legacy detection',
      );
      expect(a.service.securityNotice, contains('Old Phone'));
    },
  );

  test('a member on a newer wire format asks us to update', () async {
    final newer = b.asPeer(advert: 'v3:${base64Encode(b.identity.publicKey)}');
    a.service.updatePeers([a.self(), newer]);
    expect(a.service.needsAppUpdate, isTrue);
    expect(a.service.securityNotice, P2pService.updateAppMessage);
    expect(await a.service.sendToPeer(_vipB, Uint8List.fromList([1])), isFalse);
  });

  test('a restarted member reconnects on its new port', () async {
    await connect();
    final oldPort = b.port;

    // Bob restarts: same key, new session, new socket.
    await b.service.stop();
    expect(await b.service.start('lan-party'), isTrue);
    b.service.updatePeers([b.self(), a.asPeer()]);
    await _until(
      () =>
          b.service.peers[_vipA]?.isDirectConnected == true &&
          a.service.peers[_vipB]?.publicPort == b.port,
      reason: 'reconnect after restart',
    );
    expect(b.port, isNot(oldPort));

    final received = b.data$.stream.first;
    expect(
      await a.service.sendToPeer(_vipB, Uint8List.fromList([0x45, 9])),
      isTrue,
    );
    final (_, data) = await received.timeout(const Duration(seconds: 5));
    expect(data, [0x45, 9]);
  });

  test(
    'a captured datagram cannot be replayed, before or after a restart',
    () async {
      await connect();
      var delivered = 0;
      final sub = b.data$.stream.listen((_) => delivered++);

      // Put an on-path attacker between Alice and Bob: Alice's packets for
      // Bob go to the stranger, which records and forwards them.
      final captured = Completer<Uint8List>();
      stranger.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = stranger.receive();
        if (d == null || captured.isCompleted) return;
        captured.complete(d.data);
      });
      a.service.peers[_vipB]!.publicPort = stranger.port;
      final secret = utf8.encode('E smb-password=hunter2');
      expect(
        await a.service.sendToPeer(_vipB, Uint8List.fromList(secret)),
        isTrue,
      );
      final packet = await captured.future.timeout(const Duration(seconds: 5));
      expect(
        utf8.decode(packet, allowMalformed: true),
        isNot(contains('hunter2')),
        reason: 'payload is not in the clear',
      );

      stranger.send(packet, InternetAddress.loopbackIPv4, b.port);
      await _until(() => delivered == 1, reason: 'first copy delivered');
      stranger.send(packet, InternetAddress.loopbackIPv4, b.port);
      stranger.send(packet, InternetAddress.loopbackIPv4, b.port);

      // Bob restarts; the attacker replays to his new port.
      await b.service.stop();
      expect(await b.service.start('lan-party'), isTrue);
      b.service.updatePeers([b.self(), a.asPeer()]);
      stranger.send(packet, InternetAddress.loopbackIPv4, b.port);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      expect(delivered, 1);
    },
  );

  test('a big file message travels as sealed pieces and arrives whole',
      () async {
    await connect();
    // A 32 KB chunk response is ~44 KB once base64-encoded.
    final message = Uint8List.fromList(
        List.generate(44 * 1024 + 123, (i) => (i * 31 + 7) & 0xFF));
    expect(await a.service.sendFileMessage(_vipB, message), isTrue);
    await _until(() => b.files.isNotEmpty, reason: 'reassembled message');
    expect(b.files.single.$1, _vipA);
    expect(b.files.single.$2, message);
  });

  test('STUN runs on the P2P socket and reports its public endpoint',
      () async {
    // A STUN server on this machine: answers a Binding request with the
    // address it came from, like a real one behind no NAT.
    final stun = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    stun.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = stun.receive();
      if (d == null || d.data.length < 20) return;
      final reply = Uint8List(32)
        ..[0] = 0x01
        ..[1] = 0x01
        ..[3] = 12
        ..setRange(4, 20, d.data, 4) // cookie + transaction id
        ..[20] = 0x00
        ..[21] = 0x20 // XOR-MAPPED-ADDRESS
        ..[23] = 8
        ..[25] = 0x01;
      final port = d.port ^ 0x2112;
      reply[26] = port >> 8;
      reply[27] = port & 0xFF;
      final ip = d.address.rawAddress;
      const cookie = [0x21, 0x12, 0xA4, 0x42];
      for (var i = 0; i < 4; i++) {
        reply[28 + i] = ip[i] ^ cookie[i];
      }
      stun.send(reply, d.address, d.port);
    });
    final c = P2pService(
      identity: await P2pIdentity.generate(),
      stunServers: [('127.0.0.1', stun.port), ('127.0.0.1', stun.port)],
    )..configure(deviceId: 'device-carol', licenseKey: '');
    expect(await c.start('lan-party'), isTrue);
    expect(c.publicIp, '127.0.0.1');
    expect(c.publicPort, c.localUdpPort);
    expect(c.natMapping.name, 'endpointIndependent');
    await c.stop();
    stun.close();
  });
}
