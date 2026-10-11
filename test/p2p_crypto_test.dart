import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvpn/services/p2p_crypto.dart';

const _slug = 'game-night';
const _vipA = '10.10.0.2';

class _Pair {
  _Pair(this.idA, this.idB, this.a, this.b);
  final P2pIdentity idA;
  final P2pIdentity idB;
  final P2pCrypto a;
  final P2pCrypto b;

  /// A → B, addressed to B's current session.
  Uint8List aToB(
    List<int> payload, {
    P2pPacketType type = P2pPacketType.data,
  }) => a.seal(
    peerKey: idB.publicKey,
    senderVirtualIp: _vipA,
    type: type,
    receiverSession: b.localSession,
    payload: payload,
  );

  P2pOpened? bOpens(Uint8List packet) => b.open(packet, peerKey: idA.publicKey);
}

Future<_Pair> _pair({
  int sessionA = 1000,
  int sessionB = 2000,
  String slugA = _slug,
  String slugB = _slug,
}) async {
  final idA = await P2pIdentity.generate();
  final idB = await P2pIdentity.generate();
  return _Pair(
    idA,
    idB,
    P2pCrypto(identity: idA, networkSlug: slugA, localSession: sessionA),
    P2pCrypto(identity: idB, networkSlug: slugB, localSession: sessionB),
  );
}

void main() {
  group('seal / open', () {
    test('round trip for every packet type', () async {
      final p = await _pair();
      for (final type in P2pPacketType.values) {
        final payload = utf8.encode('payload ${type.name}');
        final opened = p.bOpens(p.aToB(payload, type: type))!;
        expect(opened.type, type);
        expect(opened.payload, payload);
        expect(opened.senderSession, p.a.localSession);
      }
    });

    test('ciphertext does not contain the plaintext', () async {
      final p = await _pair();
      final secret = utf8.encode('SMB password=hunter2');
      final packet = p.aToB(secret);
      expect(
        utf8.decode(packet, allowMalformed: true),
        isNot(contains('hunter2')),
      );
      expect(packet.length, secret.length + P2pWire.overhead);
    });

    test('header announces sender, sessions and counter', () async {
      final p = await _pair();
      p.aToB([1]);
      final header = P2pWire.parseHeader(p.aToB([2]))!;
      expect(header.type, P2pPacketType.data);
      expect(header.senderVirtualIp, _vipA);
      expect(header.senderSession, p.a.localSession);
      expect(header.receiverSession, p.b.localSession);
      expect(header.counter, 1);
    });

    test('a third party key cannot open it', () async {
      final p = await _pair();
      final idC = await P2pIdentity.generate();
      final c = P2pCrypto(
        identity: idC,
        networkSlug: _slug,
        localSession: 2000,
      );
      final packet = p.aToB([1, 2, 3]);
      expect(c.open(packet, peerKey: p.idA.publicKey), isNull);
    });

    test('keys are bound to the network', () async {
      final p = await _pair(slugB: 'other-network');
      expect(p.bOpens(p.aToB([1, 2, 3])), isNull);
    });

    test('identity survives a save and reload', () async {
      final id = await P2pIdentity.generate();
      final reloaded = await P2pIdentity.fromPrivateKey(id.privateKeyBytes);
      expect(reloaded.publicKey, id.publicKey);
      expect(P2pKeyAdvert.parse(reloaded.advert)!.key, id.publicKey);
    });
  });

  group('tampering', () {
    test('flipping any single byte is rejected', () async {
      final p = await _pair();
      final packet = p.aToB(utf8.encode('integrity matters'));
      // Byte 3 is the version: changing it makes a different wire format,
      // which classify() handles before any key is involved.
      for (var i = 0; i < packet.length; i++) {
        if (i == 3) continue;
        final forged = Uint8List.fromList(packet)..[i] ^= 0x01;
        expect(p.bOpens(forged), isNull, reason: 'byte $i');
      }
      // The untouched packet still opens: failures did not poison state.
      expect(p.bOpens(packet), isNotNull);
    });

    test('truncated packets are rejected', () async {
      final p = await _pair();
      final packet = p.aToB(utf8.encode('short'));
      for (var len = 0; len < packet.length; len++) {
        expect(
          p.bOpens(Uint8List.sublistView(packet, 0, len)),
          isNull,
          reason: 'length $len',
        );
      }
    });

    test('a packet claiming another member as sender is rejected', () async {
      final p = await _pair();
      final idC = await P2pIdentity.generate();
      // B looks the sender up by the virtual IP in the header and finds C.
      expect(p.b.open(p.aToB([9]), peerKey: idC.publicKey), isNull);
    });

    test('our own packets reflected back are rejected', () async {
      // Equal sessions, so only the key direction tells the packets apart.
      final p = await _pair(sessionA: 1000, sessionB: 1000);
      final packet = p.aToB([7]);
      expect(p.a.open(packet, peerKey: p.idB.publicKey), isNull);
    });

    test('own key, wrong length and low-order keys are refused', () async {
      final p = await _pair();
      expect(p.a.acceptsPeerKey(p.idA.publicKey), isFalse);
      expect(p.a.acceptsPeerKey(Uint8List(31)), isFalse);
      // The all-zero point and 1 are of small order: X25519 gives 0.
      expect(p.a.acceptsPeerKey(Uint8List(32)), isFalse);
      expect(p.a.acceptsPeerKey(Uint8List(32)..[0] = 1), isFalse);
      expect(p.a.acceptsPeerKey(p.idB.publicKey), isTrue);
    });
  });

  group('replay', () {
    test('the same packet is accepted once', () async {
      final p = await _pair();
      final packet = p.aToB([1]);
      expect(p.bOpens(packet), isNotNull);
      expect(p.bOpens(packet), isNull);
      expect(p.bOpens(Uint8List.fromList(packet)), isNull);
    });

    test('reordered packets inside the window are accepted once', () async {
      final p = await _pair();
      final packets = [
        for (var i = 0; i < 50; i++) p.aToB([i]),
      ];
      for (final packet in packets.reversed) {
        expect(p.bOpens(packet), isNotNull);
      }
      for (final packet in packets) {
        expect(p.bOpens(packet), isNull);
      }
    });

    test('packets older than the window are rejected', () async {
      final p = await _pair();
      final old = p.aToB([0]);
      for (var i = 0; i < P2pReplayWindow.size; i++) {
        p.aToB([1]); // burn counters
      }
      expect(p.bOpens(p.aToB([2])), isNotNull);
      expect(p.bOpens(old), isNull);
    });

    test('nothing recorded before a receiver restart opens after it', () async {
      final p = await _pair();
      final recorded = p.aToB(utf8.encode('open the door'));
      expect(p.bOpens(recorded), isNotNull);

      // B restarts: same key pair, new session, empty memory.
      final bRestarted = P2pCrypto(
        identity: p.idB,
        networkSlug: _slug,
        localSession: 3000,
      );
      expect(bRestarted.open(recorded, peerKey: p.idA.publicKey), isNull);
    });

    test('a superseded sender session cannot come back', () async {
      final p = await _pair();
      P2pCrypto restartOfA(int session) =>
          P2pCrypto(identity: p.idA, networkSlug: _slug, localSession: session);
      Uint8List from(P2pCrypto sender, int payload) => sender.seal(
        peerKey: p.idB.publicKey,
        senderVirtualIp: _vipA,
        type: P2pPacketType.data,
        receiverSession: p.b.localSession,
        payload: [payload],
      );

      expect(p.bOpens(from(p.a, 1)), isNotNull);
      final inFlight = from(p.a, 2);
      final stale = from(p.a, 3);

      // A restarts. B still takes what the old session had in flight, once.
      expect(p.bOpens(from(restartOfA(1500), 4)), isNotNull);
      expect(p.bOpens(inFlight), isNotNull);
      expect(p.bOpens(inFlight), isNull);

      // After another restart the first session is gone for good, and an
      // older session id than the newest one seen is never adopted.
      expect(p.bOpens(from(restartOfA(1600), 5)), isNotNull);
      expect(p.bOpens(stale), isNull);
      expect(p.bOpens(from(restartOfA(1550), 6)), isNull);
    });

    test('only hello may be addressed to a session we are not on', () async {
      final p = await _pair();
      for (final type in P2pPacketType.values) {
        final packet = p.a.seal(
          peerKey: p.idB.publicKey,
          senderVirtualIp: _vipA,
          type: type,
          receiverSession: type == P2pPacketType.hello ? 0 : 999,
          payload: [1],
        );
        expect(
          p.bOpens(packet) != null,
          type == P2pPacketType.hello,
          reason: type.name,
        );
      }
    });
  });

  group('nonce reuse', () {
    test('every sealed packet gets a new counter', () async {
      final p = await _pair();
      final idC = await P2pIdentity.generate();
      final counters = <int>{};
      for (var i = 0; i < 200; i++) {
        // Alternate peers: the counter is shared by the whole session.
        final to = i.isEven ? p.idB.publicKey : idC.publicKey;
        final packet = p.a.seal(
          peerKey: to,
          senderVirtualIp: _vipA,
          type: P2pPacketType.data,
          receiverSession: 5,
          payload: const [0],
        );
        expect(counters.add(P2pWire.parseHeader(packet)!.counter), isTrue);
      }
    });

    test('a receiver accepts a reused nonce at most once', () async {
      final p = await _pair();
      // A sender bug: two instances share a session id, so both number
      // their packets from 0 under the same key.
      final twin = P2pCrypto(
        identity: p.idA,
        networkSlug: _slug,
        localSession: 1000,
      );
      final first = p.aToB(utf8.encode('first'));
      final reused = twin.seal(
        peerKey: p.idB.publicKey,
        senderVirtualIp: _vipA,
        type: P2pPacketType.data,
        receiverSession: p.b.localSession,
        payload: utf8.encode('other'),
      );
      expect(
        P2pWire.parseHeader(reused)!.counter,
        P2pWire.parseHeader(first)!.counter,
      );
      expect(p.bOpens(first), isNotNull);
      expect(p.bOpens(reused), isNull);
    });

    test('restarted sender gets a new session, so a new key', () async {
      final p = await _pair();
      final restarted = P2pCrypto(
        identity: p.idA,
        networkSlug: _slug,
        localSession: 1001,
      );
      final payload = List<int>.filled(32, 0);
      final x = p.aToB(payload);
      final y = restarted.seal(
        peerKey: p.idB.publicKey,
        senderVirtualIp: _vipA,
        type: P2pPacketType.data,
        receiverSession: p.b.localSession,
        payload: payload,
      );
      // Same counter (0) and plaintext, different keystream.
      expect(
        x.sublist(P2pWire.headerLength),
        isNot(y.sublist(P2pWire.headerLength)),
      );
    });

    test('session ids only go up, even if the clock goes back', () {
      var last = 0;
      final clock = [5000, 6000, 4000, 4000, 9000];
      for (final now in clock) {
        final next = P2pCrypto.nextSessionId(last, nowMicros: now);
        expect(next, greaterThan(last));
        last = next;
      }
    });

    test('data cannot be sealed before the peer session is known', () async {
      final p = await _pair();
      expect(
        () => p.a.seal(
          peerKey: p.idB.publicKey,
          senderVirtualIp: _vipA,
          type: P2pPacketType.data,
          receiverSession: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('wire format', () {
    test('old plaintext messages are recognised as legacy', () {
      for (final m in [
        'LVPN_PUNCH:1.2.3.4:5000',
        'LVPN_PING',
        'LVPN_PONG',
        'LVPN_FILE_CANCEL:abc',
      ]) {
        expect(P2pWire.classify(utf8.encode(m)), P2pWireKind.legacy, reason: m);
      }
    });

    test('a later version is recognised, junk is not mistaken', () {
      expect(P2pWire.classify([0x00, 0x4C, 0x56, 3, 0]), P2pWireKind.newer);
      expect(P2pWire.classify([0x00, 0x4C, 0x56, 1, 0]), P2pWireKind.junk);
      expect(P2pWire.classify([0x00, 0x4C, 0x56, 2]), P2pWireKind.junk);
      // An old raw packet: 4-byte virtual IP header then IPv4.
      expect(P2pWire.classify([10, 10, 0, 3, 0x45, 0]), P2pWireKind.junk);
    });

    test(
      'an old client would hand a v2 packet to its TUN as a non-IP packet',
      () async {
        final p = await _pair();
        final packet = p.aToB([0x45]);
        // Old clients strip 4 bytes and inject the rest; its first nibble is
        // the IP version, and a v2 packet type there is never 4 or 6.
        expect(packet[4] >> 4, 0);
      },
    );

    test('key adverts', () async {
      final id = await P2pIdentity.generate();
      final parsed = P2pKeyAdvert.parse(id.advert)!;
      expect(parsed.version, P2pWire.version);
      expect(parsed.key, id.publicKey);

      final newer = P2pKeyAdvert.parse('v3:${base64Encode(id.publicKey)}')!;
      expect(newer.version, 3);
      expect(newer.key, isNull);

      expect(P2pKeyAdvert.parse(null), isNull);
      expect(P2pKeyAdvert.parse('v2:not-base64'), isNull);
      expect(P2pKeyAdvert.parse(base64Encode(id.publicKey)), isNull);
    });
  });
}
