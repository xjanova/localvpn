import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// End-to-end encryption for traffic between members of a virtual LAN.
///
/// Every datagram between two members — direct UDP or through the server
/// relay — uses wire format v2:
///
///     offset size
///      0     4   00 'L' 'V' version        (version = [P2pWire.version])
///      4     1   type                      ([P2pPacketType])
///      5     4   sender virtual IP
///      9     8   sender session            (big-endian)
///     17     8   receiver session          (0 only in [P2pPacketType.hello])
///     25     8   counter                   (never repeats within a session)
///     33     n   ChaCha20 ciphertext
///     33+n  16   Poly1305 tag              (AAD = bytes 0..32)
///
/// Keys: each device has one static X25519 key pair. The server only relays
/// public keys. For a packet from S to R:
///
///     shared = X25519(S.private, R.public)          (rejected if all zero)
///     key    = HKDF-SHA256(shared, salt, "lvpn p2p v2 key" | slug |
///                          S.public | R.public | S.session | R.session)
///     nonce  = 00 00 00 00 | counter
///
/// A session is picked fresh, larger than the last one, each time the P2P
/// service starts. Binding the key to the receiver's session means nothing
/// recorded before the receiver restarted can be replayed to it; inside a
/// session the counter must be new to a 2048-packet sliding window.
abstract final class P2pWire {
  static const int version = 2;
  static const int headerLength = 33;
  static const int tagLength = 16;
  static const int overhead = headerLength + tagLength;

  /// Largest counter a sender may use; the session ends before it wraps.
  static const int maxCounter = (1 << 60) - 1;

  static const List<int> _magic = [0x00, 0x4C, 0x56];
  // Every plaintext message of the old protocol starts with this.
  static final Uint8List _legacyPrefix = ascii.encode('LVPN_');

  static P2pWireKind classify(List<int> datagram) {
    if (datagram.length >= 4 &&
        datagram[0] == _magic[0] &&
        datagram[1] == _magic[1] &&
        datagram[2] == _magic[2]) {
      final v = datagram[3];
      if (v == version) {
        return datagram.length >= overhead
            ? P2pWireKind.current
            : P2pWireKind.junk;
      }
      return v > version ? P2pWireKind.newer : P2pWireKind.junk;
    }
    if (datagram.length >= _legacyPrefix.length) {
      for (var i = 0; i < _legacyPrefix.length; i++) {
        if (datagram[i] != _legacyPrefix[i]) return P2pWireKind.junk;
      }
      return P2pWireKind.legacy;
    }
    return P2pWireKind.junk;
  }

  /// Reads the cleartext header. Nothing in it is trusted until
  /// [P2pCrypto.open] has checked the tag.
  static P2pHeader? parseHeader(Uint8List datagram) {
    if (classify(datagram) != P2pWireKind.current) return null;
    final b = ByteData.sublistView(datagram, 0, headerLength);
    return P2pHeader(
      type: P2pPacketType.fromCode(b.getUint8(4)),
      senderVirtualIp:
          '${b.getUint8(5)}.${b.getUint8(6)}.${b.getUint8(7)}.${b.getUint8(8)}',
      senderSession: b.getUint64(9),
      receiverSession: b.getUint64(17),
      counter: b.getUint64(25),
    );
  }
}

enum P2pWireKind {
  /// Wire format v2, long enough to hold a tag.
  current,

  /// A later wire format: this app is out of date.
  newer,

  /// Plaintext from an app that predates encryption (LVPN_PUNCH, LVPN_PING…).
  legacy,

  /// Anything else.
  junk,
}

/// Packet types of wire format v2. The codes are on the wire.
enum P2pPacketType {
  /// Hole punch and keepalive. Answered with [helloReply].
  hello(1),

  /// Answer to [hello]. Proves the path works in both directions right now.
  helloReply(2),

  /// One IP packet of the virtual LAN.
  data(3),

  /// A file-transfer message (LVPN_FILE_…).
  file(4),

  /// One piece of a file-transfer message too big for one datagram.
  /// Payload: message id (4), index (2), count (2), bytes. Each piece is
  /// sealed on its own, so each has its own counter and replay check.
  fileFragment(5);

  const P2pPacketType(this.code);
  final int code;

  static P2pPacketType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

class P2pHeader {
  final P2pPacketType? type;
  final String senderVirtualIp;
  final int senderSession;
  final int receiverSession;
  final int counter;

  const P2pHeader({
    required this.type,
    required this.senderVirtualIp,
    required this.senderSession,
    required this.receiverSession,
    required this.counter,
  });
}

/// An authenticated, decrypted packet.
class P2pOpened {
  final P2pPacketType type;
  final int senderSession;
  final Uint8List payload;

  const P2pOpened({
    required this.type,
    required this.senderSession,
    required this.payload,
  });
}

/// The `p2p_key` value a device advertises through the server:
/// `v<wire version>:<base64 X25519 public key>`.
abstract final class P2pKeyAdvert {
  static final RegExp _format = RegExp(r'^v(\d{1,3}):([A-Za-z0-9+/]{43}=)$');

  static String encode(List<int> publicKey) =>
      'v${P2pWire.version}:${base64Encode(publicKey)}';

  /// Returns null for a missing or malformed advert. A version other than
  /// [P2pWire.version] comes back without a key.
  static ({int version, Uint8List? key})? parse(String? advert) {
    if (advert == null) return null;
    final m = _format.firstMatch(advert);
    if (m == null) return null;
    final version = int.parse(m.group(1)!);
    if (version != P2pWire.version) return (version: version, key: null);
    final key = base64Decode(m.group(2)!);
    if (key.length != 32) return null;
    return (version: version, key: key);
  }
}

/// This device's static X25519 key pair.
class P2pIdentity {
  P2pIdentity._(this._keyPair, this.publicKey);

  final SimpleKeyPairData _keyPair;
  final Uint8List publicKey;

  static Future<P2pIdentity> generate() {
    final random = Random.secure();
    return fromPrivateKey(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  static Future<P2pIdentity> fromPrivateKey(List<int> privateKey) async {
    final keyPair =
        await const DartX25519().newKeyPairFromSeed(privateKey)
            as SimpleKeyPairData;
    final publicKey = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );
    return P2pIdentity._(keyPair, publicKey);
  }

  /// For persisting only. Never log or send it.
  List<int> get privateKeyBytes => _keyPair.bytes;

  String get advert => P2pKeyAdvert.encode(publicKey);
}

/// Sliding anti-replay window over packet counters (RFC 6479 style).
class P2pReplayWindow {
  static const int size = 2048;

  final Uint32List _bits = Uint32List(size ~/ 32);
  int _highest = -1;

  /// Whether [counter] is new and not too far behind the newest one seen.
  bool canAccept(int counter) {
    if (counter < 0 || counter > P2pWire.maxCounter) return false;
    if (counter > _highest) return true;
    if (_highest - counter >= size) return false;
    return !_isSet(counter);
  }

  /// Records [counter]. False, and nothing recorded, if it was a replay or
  /// too old.
  bool accept(int counter) {
    if (!canAccept(counter)) return false;
    if (counter > _highest) {
      if (counter - _highest >= size) {
        _bits.fillRange(0, _bits.length, 0);
      } else {
        // Slots between the old and the new top now belong to counters
        // that were never seen.
        for (var c = _highest + 1; c < counter; c++) {
          _bits[(c % size) >> 5] &= ~(1 << (c & 31));
        }
      }
      _highest = counter;
    }
    _bits[(counter % size) >> 5] |= 1 << (counter & 31);
    return true;
  }

  bool _isSet(int counter) =>
      _bits[(counter % size) >> 5] & (1 << (counter & 31)) != 0;
}

class _PeerSession {
  _PeerSession(this.id);
  final int id;
  final P2pReplayWindow window = P2pReplayWindow();
}

class _Peer {
  _Peer(this.publicKey, this.sharedSecret);

  final Uint8List publicKey;
  final Uint8List sharedSecret;

  /// Newest authenticated session of this peer, and the one before it so
  /// packets still in flight across a peer restart are not lost.
  _PeerSession? current;
  _PeerSession? previous;

  /// Session the server said this peer is on, before any packet proved it.
  int sessionHint = 0;

  final Map<String, SecretKeyData> keys = {};

  _PeerSession? sessionFor(int id) {
    if (current?.id == id) return current;
    if (previous?.id == id) return previous;
    return null;
  }
}

/// Seals and opens wire-format-v2 packets for one device in one network.
///
/// Synchronous on purpose: the replay check and the window update happen
/// with no await in between, so two copies of a packet cannot both pass.
class P2pCrypto {
  P2pCrypto({
    required P2pIdentity identity,
    required String networkSlug,
    required this.localSession,
  }) : _identity = identity,
       _slug = utf8.encode(networkSlug) {
    if (localSession <= 0) {
      throw ArgumentError.value(localSession, 'localSession');
    }
    if (_slug.length > 0xFFFF) {
      throw ArgumentError.value(networkSlug, 'networkSlug');
    }
  }

  static const _aead = DartChacha20.poly1305Aead();
  static const _maxPeers = 512;
  static const _maxKeysPerPeer = 8;
  static final Uint8List _salt = ascii.encode('LocalVPN P2P v2');
  static final Uint8List _label = ascii.encode('lvpn p2p v2 key');

  final P2pIdentity _identity;
  final List<int> _slug;

  /// This device's session. Peers bind the packets they send us to it.
  final int localSession;

  // One counter for every packet this session sends, whatever the peer:
  // a nonce can then never repeat under any key derived for this session.
  int _counter = 0;

  final Map<String, _Peer?> _peers = {};

  /// A new session id: time based so it keeps growing across restarts, and
  /// always above [lastIssued] in case the clock went backwards.
  static int nextSessionId(int lastIssued, {int? nowMicros, Random? random}) {
    final now = nowMicros ?? DateTime.now().microsecondsSinceEpoch;
    final fromClock = now * 256 + (random ?? Random.secure()).nextInt(256);
    return max(fromClock, lastIssued + 1);
  }

  /// Whether [publicKey] can be used as a peer key (right length, a usable
  /// curve point, not our own).
  bool acceptsPeerKey(List<int> publicKey) => _peer(publicKey) != null;

  /// The session to address packets for this peer to: the newest one it
  /// proved, or the server's hint. 0 if neither is known yet.
  int peerSession(List<int> peerKey) {
    final peer = _peer(peerKey);
    if (peer == null) return 0;
    return max(peer.current?.id ?? 0, peer.sessionHint);
  }

  /// Records the session a peer announced through the server. It only
  /// decides where we address packets; nothing is accepted because of it.
  void notePeerSessionHint(List<int> peerKey, int session) {
    final peer = _peer(peerKey);
    if (peer != null && session > peer.sessionHint) peer.sessionHint = session;
  }

  /// Encrypts [payload] for the peer with [peerKey].
  ///
  /// [receiverSession] is 0 only for a [P2pPacketType.hello] to a peer whose
  /// session is not known yet.
  Uint8List seal({
    required List<int> peerKey,
    required String senderVirtualIp,
    required P2pPacketType type,
    required int receiverSession,
    List<int> payload = const [],
  }) {
    if (receiverSession == 0 && type != P2pPacketType.hello) {
      throw ArgumentError(
        'Only hello may be sent before the peer session '
        'is known',
      );
    }
    final peer = _peer(peerKey);
    if (peer == null) throw ArgumentError('Unusable peer key');
    final vip = _parseIpv4(senderVirtualIp);
    if (vip == null) throw ArgumentError.value(senderVirtualIp);
    if (_counter > P2pWire.maxCounter) {
      throw StateError('Session exhausted; start a new one');
    }
    final counter = _counter++;

    final header = Uint8List(P2pWire.headerLength);
    final h = ByteData.sublistView(header);
    header.setRange(0, 3, P2pWire._magic);
    h.setUint8(3, P2pWire.version);
    h.setUint8(4, type.code);
    header.setRange(5, 9, vip);
    h.setUint64(9, localSession);
    h.setUint64(17, receiverSession);
    h.setUint64(25, counter);

    final key = _key(
      peer,
      outgoing: true,
      senderSession: localSession,
      receiverSession: receiverSession,
    );
    final box = _aead.encryptSync(
      payload,
      secretKey: key,
      nonce: _nonce(counter),
      aad: header,
    );

    final out = Uint8List(P2pWire.overhead + payload.length);
    out.setRange(0, P2pWire.headerLength, header);
    out.setRange(
      P2pWire.headerLength,
      P2pWire.headerLength + payload.length,
      box.cipherText,
    );
    out.setRange(out.length - P2pWire.tagLength, out.length, box.mac.bytes);
    return out;
  }

  /// Authenticates and decrypts a datagram from the peer with [peerKey].
  /// Null when the packet is forged, tampered with, replayed, from a session
  /// that was superseded, or addressed to another session of ours.
  P2pOpened? open(Uint8List datagram, {required List<int> peerKey}) {
    final header = P2pWire.parseHeader(datagram);
    final type = header?.type;
    if (header == null || type == null) return null;
    // Only a hello may predate our session: it is how a peer that has not
    // seen our restart reaches us. Everything else must be bound to now.
    if (type != P2pPacketType.hello && header.receiverSession != localSession) {
      return null;
    }
    // getUint64 reads values >= 2^63 as negative.
    if (header.senderSession <= 0 || header.counter < 0) return null;

    final peer = _peer(peerKey);
    if (peer == null) return null;

    final known = peer.sessionFor(header.senderSession);
    final session = known ?? _PeerSession(header.senderSession);
    if (known == null) {
      final current = peer.current;
      if (current != null && header.senderSession < current.id) return null;
    }
    if (!session.window.canAccept(header.counter)) return null;

    final key = _key(
      peer,
      outgoing: false,
      senderSession: header.senderSession,
      receiverSession: header.receiverSession,
    );
    final cipherEnd = datagram.length - P2pWire.tagLength;
    final List<int> clear;
    try {
      clear = _aead.decryptSync(
        SecretBox(
          Uint8List.sublistView(datagram, P2pWire.headerLength, cipherEnd),
          nonce: _nonce(header.counter),
          mac: Mac(Uint8List.sublistView(datagram, cipherEnd)),
        ),
        secretKey: key,
        aad: Uint8List.sublistView(datagram, 0, P2pWire.headerLength),
      );
    } on SecretBoxAuthenticationError {
      return null;
    }

    if (!session.window.accept(header.counter)) return null;
    if (known == null) {
      peer.previous = peer.current;
      peer.current = session;
    }

    return P2pOpened(
      type: type,
      senderSession: header.senderSession,
      payload: clear is Uint8List ? clear : Uint8List.fromList(clear),
    );
  }

  _Peer? _peer(List<int> publicKey) {
    if (publicKey.length != 32) return null;
    final id = base64Encode(publicKey);
    if (_peers.containsKey(id)) return _peers[id];
    if (_peers.length >= _maxPeers) _peers.remove(_peers.keys.first);

    _Peer? peer;
    if (!_equal(publicKey, _identity.publicKey)) {
      final secret =
          const DartX25519().sharedSecretSync(
                keyPairData: _identity._keyPair,
                remotePublicKey: SimplePublicKey(
                  List<int>.of(publicKey),
                  type: KeyPairType.x25519,
                ),
              )
              as SecretKeyData;
      final shared = Uint8List.fromList(secret.bytes);
      // A low-order point gives an all-zero secret anyone can compute.
      if (shared.any((b) => b != 0)) {
        peer = _Peer(Uint8List.fromList(publicKey), shared);
      }
    }
    _peers[id] = peer;
    return peer;
  }

  SecretKeyData _key(
    _Peer peer, {
    required bool outgoing,
    required int senderSession,
    required int receiverSession,
  }) {
    final id = '${outgoing ? 'o' : 'i'}$senderSession:$receiverSession';
    final cached = peer.keys[id];
    if (cached != null) return cached;

    final info = BytesBuilder(copy: false)
      ..add(_label)
      ..add([_slug.length >> 8, _slug.length & 0xFF])
      ..add(_slug)
      ..add(outgoing ? _identity.publicKey : peer.publicKey)
      ..add(outgoing ? peer.publicKey : _identity.publicKey)
      ..add(_u64(senderSession))
      ..add(_u64(receiverSession));
    final prk = digest.Hmac(digest.sha256, _salt).convert(peer.sharedSecret);
    final okm = digest.Hmac(
      digest.sha256,
      prk.bytes,
    ).convert([...info.takeBytes(), 1]);
    final key = SecretKeyData(okm.bytes);

    if (peer.keys.length >= _maxKeysPerPeer) {
      peer.keys.remove(peer.keys.keys.first);
    }
    peer.keys[id] = key;
    return key;
  }

  static List<int> _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, counter);
    return nonce;
  }

  static List<int> _u64(int v) {
    final b = Uint8List(8);
    ByteData.sublistView(b).setUint64(0, v);
    return b;
  }

  static List<int>? _parseIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final out = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return null;
      out.add(v);
    }
    return out;
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
