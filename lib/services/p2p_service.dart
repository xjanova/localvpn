import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/member.dart';
import 'p2p_crypto.dart';

/// Whether traffic with a peer can be end-to-end encrypted.
enum P2pPeerSecurity {
  /// The peer's public key has not arrived yet; nothing is sent to it.
  pendingKey,

  /// Every packet with this peer is encrypted and authenticated.
  encrypted,

  /// The peer runs an app from before encryption. Nothing is exchanged.
  peerOutdated,

  /// The peer runs a newer wire format than this app understands.
  selfOutdated,
}

/// P2P connection state for a single peer
class PeerConnection {
  final String virtualIp;
  String publicIp;
  int publicPort;
  String displayName;
  bool isDirectConnected;
  DateTime lastActivity;
  int punchAttempts;
  Uint8List? publicKey;
  P2pPeerSecurity security;

  PeerConnection({
    required this.virtualIp,
    required this.publicIp,
    required this.publicPort,
    required this.displayName,
    this.isDirectConnected = false,
    DateTime? lastActivity,
    this.punchAttempts = 0,
    this.publicKey,
    this.security = P2pPeerSecurity.pendingKey,
  }) : lastActivity = lastActivity ?? DateTime.now();
}

/// Signal message from the signaling server
class SignalMessage {
  final String fromVirtualIp;
  final String fromPublicIp;
  final int? fromPublicPort;
  final String fromDisplayName;
  final String type;
  final Map<String, dynamic> payload;

  SignalMessage({
    required this.fromVirtualIp,
    required this.fromPublicIp,
    this.fromPublicPort,
    required this.fromDisplayName,
    required this.type,
    required this.payload,
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      fromVirtualIp: json['from_virtual_ip'] as String,
      fromPublicIp: json['from_public_ip'] as String? ?? '',
      fromPublicPort: json['from_public_port'] as int?,
      fromDisplayName: json['from_display_name'] as String? ?? 'Unknown',
      type: json['type'] as String,
      payload: json['payload'] as Map<String, dynamic>? ?? {},
    );
  }
}

/// BitTorrent-style P2P service.
///
/// Flow:
/// 1. Device joins network via server (tracker), advertising its public key
/// 2. Heartbeat returns peer list with public IP:port and public keys
/// 3. STUN endpoint reveals own public IP:port
/// 4. UDP hole punching attempts direct connection
/// 5. Falls back to server relay if hole punch fails
///
/// Everything sent to a peer, direct or relayed, is sealed by [P2pCrypto];
/// a peer without a usable key gets nothing.
class P2pService extends ChangeNotifier {
  P2pService({@visibleForTesting P2pIdentity? identity})
      : _fixedIdentity = identity;

  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const int _maxPunchAttempts = 5;
  static const Duration _punchInterval = Duration(milliseconds: 500);
  static const Duration _signalPollInterval = Duration(seconds: 3);
  static const Duration _peerTimeout = Duration(seconds: 60);
  static const String _prefPrivateKey = 'p2p_x25519_private_key';
  static const String _prefLastSession = 'p2p_last_session_id';

  /// Shown when this app is too old for the people in the network.
  static const String updateAppMessage =
      'อัปเดตแอปเพื่อเชื่อมต่อกับเพื่อนในวงนี้';

  // Configuration
  String? _deviceId;
  String? _licenseKey;
  String? _networkSlug;

  // Encryption
  final P2pIdentity? _fixedIdentity;
  Future<P2pIdentity>? _identity;
  P2pCrypto? _crypto;
  String? _keyAdvert;
  int _lastSessionId = 0;
  String? _ownVirtualIp;
  bool _serverRelaysKeys = false;
  bool _sawNewerWire = false;

  // Own public endpoint (discovered via STUN)
  String? _publicIp;
  int? _publicPort;
  String? get publicIp => _publicIp;
  int? get publicPort => _publicPort;

  // UDP socket for P2P communication
  RawDatagramSocket? _udpSocket;
  int? _localPort;

  @visibleForTesting
  int? get localUdpPort => _localPort;

  @visibleForTesting
  int? get localSession => _crypto?.localSession;

  // Connected peers
  final Map<String, PeerConnection> _peers = {};
  Map<String, PeerConnection> get peers => Map.unmodifiable(_peers);

  // Peer data callbacks
  void Function(String virtualIp, Uint8List data)? onPeerData;
  void Function(String virtualIp, Uint8List data)? onFileMessage;

  // Timers
  Timer? _signalPollTimer;
  Timer? _keepAliveTimer;

  // State
  bool _isActive = false;
  bool _isStarting = false;
  bool get isActive => _isActive;

  String? _error;
  String? get error => _error;

  int get directPeerCount =>
      _peers.values.where((p) => p.isDirectConnected).length;
  int get relayPeerCount => _peers.values
      .where((p) =>
          !p.isDirectConnected && p.security == P2pPeerSecurity.encrypted)
      .length;

  /// This app can't read what someone in the network sends.
  bool get needsAppUpdate =>
      _sawNewerWire ||
      _peers.values.any((p) => p.security == P2pPeerSecurity.selfOutdated);

  /// Members whose app predates encryption; they are not connected to.
  List<String> get outdatedPeerNames => [
        for (final p in _peers.values)
          if (p.security == P2pPeerSecurity.peerOutdated) p.displayName,
      ];

  /// Why some members can't be reached, in Thai, or null if all can.
  String? get securityNotice {
    if (needsAppUpdate) return updateAppMessage;
    final names = outdatedPeerNames;
    if (names.isEmpty) return null;
    final who = names.length <= 3
        ? names.join(', ')
        : '${names.take(3).join(', ')} และอีก ${names.length - 3} คน';
    return '$who ใช้แอปเวอร์ชันเก่าที่ไม่เข้ารหัส — '
        'ให้อัปเดตแอปเพื่อเชื่อมต่อกับเพื่อนในวงนี้';
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (_deviceId case final id?) 'X-Device-Id': id,
      };

  /// Configure with credentials
  void configure({
    required String deviceId,
    required String licenseKey,
  }) {
    _deviceId = deviceId;
    _licenseKey = licenseKey;
  }

  /// This device's public key in the form sent to the server as `p2p_key`,
  /// or null if no key could be made.
  Future<String?> keyAdvert() async {
    try {
      return (await _loadIdentity()).advert;
    } catch (e) {
      debugPrint('P2P key unavailable: $e');
      return null;
    }
  }

  Future<P2pIdentity> _loadIdentity() {
    final fixed = _fixedIdentity;
    if (fixed != null) return Future.value(fixed);
    return _identity ??= _loadOrCreateIdentity();
  }

  Future<P2pIdentity> _loadOrCreateIdentity() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefPrivateKey);
      if (stored != null) {
        final bytes = base64Decode(stored);
        if (bytes.length == 32) return await P2pIdentity.fromPrivateKey(bytes);
      }
    } catch (e) {
      debugPrint('P2P stored key unreadable, making a new one: $e');
    }
    final identity = await P2pIdentity.generate();
    try {
      await prefs?.setString(
          _prefPrivateKey, base64Encode(identity.privateKeyBytes));
    } catch (e) {
      // Still usable for this run; peers pick up the new key next time.
      debugPrint('P2P key not saved: $e');
    }
    return identity;
  }

  /// A session id above every one this device used before, so peers can
  /// tell a restart from a replay.
  Future<int> _newSessionId() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      _lastSessionId = max(_lastSessionId, prefs.getInt(_prefLastSession) ?? 0);
    } catch (_) {}
    final id = P2pCrypto.nextSessionId(_lastSessionId);
    _lastSessionId = id;
    try {
      await prefs?.setInt(_prefLastSession, id);
    } catch (_) {}
    return id;
  }

  /// Start P2P service for a network
  Future<bool> start(String networkSlug) async {
    if (_isStarting) return false;
    if (_isActive) await stop();
    _isStarting = true;

    _networkSlug = networkSlug;
    _error = null;
    _serverRelaysKeys = false;
    _sawNewerWire = false;

    try {
      // 1. Keys: nothing leaves this device unencrypted
      final identity = await _loadIdentity();
      _keyAdvert = identity.advert;
      _crypto = P2pCrypto(
        identity: identity,
        networkSlug: networkSlug,
        localSession: await _newSessionId(),
      );

      // 2. Bind UDP socket on any available port
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _localPort = _udpSocket!.port;
      debugPrint('P2P: UDP socket bound on port $_localPort');

      // Listen for incoming UDP packets
      _udpSocket!.listen(
        _handleUdpPacket,
        onError: (e) => debugPrint('P2P UDP error: $e'),
      );

      // 3. Discover own public IP:port via STUN
      await _discoverPublicEndpoint();

      // 4. Start polling for signaling messages
      _signalPollTimer = Timer.periodic(
        _signalPollInterval,
        (_) => _pollSignals(),
      );

      // 5. Keep-alive: send periodic hellos to connected peers
      _keepAliveTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _sendKeepAlives(),
      );

      _isActive = true;
      _isStarting = false;
      notifyListeners();
      return true;
    } catch (e) {
      // Clean up resources on failure to prevent leaks
      _signalPollTimer?.cancel();
      _signalPollTimer = null;
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      _udpSocket?.close();
      _udpSocket = null;
      _localPort = null;
      _crypto = null;
      _isStarting = false;

      _error = 'ไม่สามารถเริ่ม P2P ได้: $e';
      debugPrint('P2P start error: $e');
      notifyListeners();
      return false;
    }
  }

  /// Stop P2P service
  Future<void> stop() async {
    _signalPollTimer?.cancel();
    _signalPollTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    _localPort = null;
    _publicIp = null;
    _publicPort = null;
    _peers.clear();
    _crypto = null;
    _ownVirtualIp = null;
    _serverRelaysKeys = false;
    _sawNewerWire = false;
    _isActive = false;
    _networkSlug = null;
    notifyListeners();
  }

  /// Discover own public IP:port via STUN endpoint
  Future<void> _discoverPublicEndpoint() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/stun'), headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _publicIp = data['ip'] as String?;
        // Server sees the HTTP port, not our UDP port.
        // For symmetric NAT, the UDP port may differ.
        // We store our local UDP port as a hint.
        _publicPort = _localPort;
        debugPrint('P2P STUN: public IP=$_publicIp, localPort=$_localPort');
      }
    } catch (e) {
      debugPrint('P2P STUN error: $e');
    }
  }

  /// Update peer list from heartbeat response
  void updatePeers(List<NetworkMember> onlinePeers) {
    final currentVirtualIps = <String>{};
    final toPunch = <PeerConnection>[];

    for (final member in onlinePeers) {
      final vip = member.virtualIp;
      if (vip == null) continue;
      // Self: remember our virtual IP, it goes in every packet header
      if (member.machineId != null && member.machineId == _deviceId) {
        _ownVirtualIp = vip;
        continue;
      }
      if (member.publicIp == null) continue;
      currentVirtualIps.add(vip);
      if (member.reportsP2pKey) _serverRelaysKeys = true;

      var peer = _peers[vip];
      final isNew = peer == null;
      // New peer discovered
      peer ??= _peers[vip] = PeerConnection(
        virtualIp: vip,
        publicIp: member.publicIp!,
        publicPort: member.publicPort ?? 0,
        displayName: member.displayName,
      );
      peer.displayName = member.displayName;

      final keyChanged = _applyKeyAdvert(
        peer,
        member.p2pKey,
        fromServer: member.reportsP2pKey,
      );
      if ((isNew || keyChanged) && peer.publicPort > 0) toPunch.add(peer);
    }

    // Remove peers that went offline
    _peers.removeWhere(
      (vip, _) => !currentVirtualIps.contains(vip),
    );

    notifyListeners();

    for (final peer in toPunch) {
      _requestHolePunch(peer.virtualIp, peer.publicIp, peer.publicPort);
    }
  }

  /// Applies a key advert (`p2p_key`) to [peer]. True if the peer has a new
  /// key, which then has to prove the path again.
  bool _applyKeyAdvert(
    PeerConnection peer,
    String? advert, {
    required bool fromServer,
  }) {
    final parsed = P2pKeyAdvert.parse(advert);
    if (parsed == null) {
      // The server keeps keys and this member never sent one: its app is
      // from before encryption.
      if (fromServer && advert == null && peer.publicKey == null) {
        peer.security = P2pPeerSecurity.peerOutdated;
      }
      return false;
    }
    if (parsed.version > P2pWire.version) {
      peer.security = P2pPeerSecurity.selfOutdated;
      return false;
    }
    final key = parsed.key;
    if (key == null) {
      peer.security = P2pPeerSecurity.peerOutdated;
      return false;
    }
    if (_crypto?.acceptsPeerKey(key) == false) {
      debugPrint('P2P: unusable key for ${peer.virtualIp}');
      return false;
    }
    final changed =
        peer.publicKey == null || !listEquals(peer.publicKey, key);
    peer.security = P2pPeerSecurity.encrypted;
    if (changed) {
      peer.publicKey = key;
      peer.isDirectConnected = false;
    }
    return changed;
  }

  /// Whether we exchange anything at all with [peer].
  bool _mayContact(PeerConnection peer) =>
      peer.security == P2pPeerSecurity.pendingKey ||
      peer.security == P2pPeerSecurity.encrypted;

  /// Send a virtual-LAN packet to a peer (P2P direct or relay fallback).
  /// Returns false, sending nothing, when it can't be encrypted for the peer.
  Future<bool> sendToPeer(String targetVirtualIp, Uint8List data) =>
      _sendSealed(targetVirtualIp, P2pPacketType.data, data);

  /// Send a file-transfer message (LVPN_FILE_…) to a peer.
  Future<bool> sendFileMessage(String targetVirtualIp, Uint8List message) =>
      _sendSealed(targetVirtualIp, P2pPacketType.file, message);

  Future<bool> _sendSealed(
    String targetVirtualIp,
    P2pPacketType type,
    Uint8List payload,
  ) async {
    final peer = _peers[targetVirtualIp];
    final packet = peer == null ? null : _seal(peer, type, payload);
    if (peer == null || packet == null) return false;

    // Try direct P2P first
    final socket = _udpSocket;
    if (peer.isDirectConnected && socket != null) {
      try {
        final sent = socket.send(
          packet,
          InternetAddress(peer.publicIp),
          peer.publicPort,
        );
        if (sent > 0) return true;
      } catch (e) {
        debugPrint('P2P direct send failed: $e');
        peer.isDirectConnected = false;
      }
    }

    // Fallback to server relay: the same sealed packet, so the server only
    // ever sees ciphertext
    return _relayData(targetVirtualIp, packet);
  }

  // Relay budget for virtual-LAN packets: the HTTP relay is a fallback for
  // peers we cannot reach directly, not a packet pipe, so cap it.
  static const int _relayPacketsPerSecond = 25;
  static const int _relayMaxPacketBytes = 1500;
  int _relayWindowStart = 0;
  int _relayWindowCount = 0;

  /// Send a virtual-LAN (TUN) packet to one peer: direct UDP when the hole
  /// punch worked, otherwise the server relay within a small budget. Sealed
  /// either way; false if it can't be encrypted for the peer.
  Future<bool> sendTunPacket(String targetVirtualIp, Uint8List packet) async {
    final peer = _peers[targetVirtualIp];
    if (peer == null) return false;
    if (peer.isDirectConnected && _udpSocket != null) {
      return sendToPeer(targetVirtualIp, packet);
    }
    if (packet.length > _relayMaxPacketBytes) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (now != _relayWindowStart) {
      _relayWindowStart = now;
      _relayWindowCount = 0;
    }
    if (_relayWindowCount >= _relayPacketsPerSecond) return false;
    final sealed = _seal(peer, P2pPacketType.data, packet);
    if (sealed == null) return false;
    _relayWindowCount++;
    return _relayData(targetVirtualIp, sealed);
  }

  /// Send a broadcast TUN packet to every directly connected peer, sealed
  /// for each. Broadcasts never go through the relay (one LAN game can send
  /// dozens per second).
  void broadcastTunPacket(Uint8List packet) {
    final socket = _udpSocket;
    if (socket == null) return;
    for (final peer in _peers.values) {
      if (!peer.isDirectConnected) continue;
      final sealed = _seal(peer, P2pPacketType.data, packet);
      if (sealed == null) continue;
      try {
        socket.send(
          sealed,
          InternetAddress(peer.publicIp),
          peer.publicPort,
        );
      } catch (e) {
        debugPrint('P2P broadcast to ${peer.virtualIp} failed: $e');
      }
    }
  }

  /// Seals [payload] for [peer], or null if that can't be done (no key yet,
  /// peer on another app version, peer session not known yet).
  Uint8List? _seal(
    PeerConnection peer,
    P2pPacketType type,
    List<int> payload, {
    int? receiverSession,
  }) {
    final crypto = _crypto;
    final ownVip = _ownVirtualIp;
    final key = peer.publicKey;
    if (crypto == null ||
        ownVip == null ||
        key == null ||
        peer.security != P2pPeerSecurity.encrypted) {
      return null;
    }
    final session = receiverSession ?? crypto.peerSession(key);
    if (session == 0 && type != P2pPacketType.hello) return null;
    try {
      return crypto.seal(
        peerKey: key,
        senderVirtualIp: ownVip,
        type: type,
        receiverSession: session,
        payload: payload,
      );
    } catch (e) {
      debugPrint('P2P seal failed for ${peer.virtualIp}: $e');
      return null;
    }
  }

  /// What a punch signal carries: our endpoint, key and session. The key
  /// and session let a peer reach us even when the server doesn't relay
  /// keys yet.
  Map<String, dynamic> get _punchPayload => {
        'udp_port': _localPort,
        'public_ip': _publicIp,
        if (_keyAdvert case final advert?) 'p2p_key': advert,
        if (_crypto case final crypto?)
          'p2p_session': '${crypto.localSession}',
      };

  /// Ask a peer (via signaling) to punch towards us, and punch towards it.
  Future<void> _requestHolePunch(
    String targetVirtualIp,
    String targetPublicIp,
    int targetPublicPort,
  ) async {
    if (_udpSocket == null || _networkSlug == null) return;

    final peer = _peers[targetVirtualIp];
    if (peer == null || peer.isDirectConnected || !_mayContact(peer)) return;

    debugPrint('P2P: Initiating hole punch to $targetVirtualIp '
        '($targetPublicIp:$targetPublicPort)');

    // Send signaling message asking peer to punch towards us
    await _sendSignal(
      targetVirtualIp: targetVirtualIp,
      type: 'punch_request',
      payload: _punchPayload,
    );

    await _punchTowards(peer, targetPublicIp, targetPublicPort);
  }

  /// Send hello packets to open our NAT towards a peer. A sealed reply
  /// marks the peer as directly connected.
  Future<void> _punchTowards(
    PeerConnection peer,
    String targetPublicIp,
    int targetPublicPort,
  ) async {
    peer.punchAttempts = 0;
    for (int i = 0; i < _maxPunchAttempts; i++) {
      if (!_isActive || peer.isDirectConnected) return;
      peer.punchAttempts = i + 1;
      _sendHello(peer, targetPublicIp, targetPublicPort);
      await Future.delayed(_punchInterval);
    }
  }

  void _sendHello(PeerConnection peer, String ip, int port) {
    final packet = _seal(peer, P2pPacketType.hello, const []);
    if (packet == null) return;
    try {
      _udpSocket?.send(packet, InternetAddress(ip), port);
    } catch (e) {
      debugPrint('P2P hello to ${peer.virtualIp} failed: $e');
    }
  }

  /// Handle incoming UDP packet
  void _handleUdpPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _udpSocket == null) return;

    final datagram = _udpSocket!.receive();
    if (datagram == null) return;

    switch (P2pWire.classify(datagram.data)) {
      case P2pWireKind.current:
        _handleSealedPacket(datagram);
      case P2pWireKind.newer:
        // A member runs a later wire format that this app can't read.
        if (!_sawNewerWire && _peerAt(datagram.address.address) != null) {
          _sawNewerWire = true;
          notifyListeners();
        }
      case P2pWireKind.legacy:
        _handleLegacyPacket(datagram);
      case P2pWireKind.junk:
        break;
    }
  }

  void _handleSealedPacket(Datagram datagram) {
    final header = P2pWire.parseHeader(datagram.data);
    final peer = header == null ? null : _peers[header.senderVirtualIp];
    final key = peer?.publicKey;
    final crypto = _crypto;
    if (peer == null || key == null || crypto == null) return;

    // Forged, tampered, replayed or stale packets stop here
    final opened = crypto.open(datagram.data, peerKey: key);
    if (opened == null) return;
    peer.lastActivity = DateTime.now();

    switch (opened.type) {
      case P2pPacketType.hello:
        // Answer where it came from: that is the peer's NAT mapping
        final reply = _seal(
          peer,
          P2pPacketType.helloReply,
          const [],
          receiverSession: opened.senderSession,
        );
        if (reply == null) return;
        try {
          _udpSocket?.send(reply, datagram.address, datagram.port);
        } catch (e) {
          debugPrint('P2P hello reply to ${peer.virtualIp} failed: $e');
        }
        // A hello alone could be a replay, so it doesn't make the peer
        // direct or move its endpoint. Our own hello does, once its reply
        // comes back (new peer, or the peer restarted on another port).
        if (!peer.isDirectConnected ||
            peer.publicIp != datagram.address.address ||
            peer.publicPort != datagram.port) {
          _sendHello(peer, datagram.address.address, datagram.port);
        }
      case P2pPacketType.helloReply:
        // A reply bound to our session: the path works both ways, now
        final senderIp = datagram.address.address;
        final senderPort = datagram.port;
        final changed = !peer.isDirectConnected ||
            peer.publicIp != senderIp ||
            peer.publicPort != senderPort;
        peer.isDirectConnected = true;
        peer.publicIp = senderIp;
        peer.publicPort = senderPort;
        if (changed) {
          debugPrint('P2P: Direct connection established with '
              '${peer.virtualIp} ($senderIp:$senderPort)');
          notifyListeners();
        }
      case P2pPacketType.data:
        onPeerData?.call(peer.virtualIp, opened.payload);
      case P2pPacketType.file:
        onFileMessage?.call(peer.virtualIp, opened.payload);
    }
  }

  /// Plaintext from an app that predates encryption. Never processed; it
  /// only tells us why that member can't be reached.
  void _handleLegacyPacket(Datagram datagram) {
    final peer = _peerAt(datagram.address.address, datagram.port);
    // A member with a key never sends this; maybe another device behind
    // the same NAT.
    if (peer == null || peer.publicKey != null) return;
    if (peer.security != P2pPeerSecurity.peerOutdated) {
      peer.security = P2pPeerSecurity.peerOutdated;
      notifyListeners();
    }
  }

  /// Poll for signaling messages from the server
  Future<void> _pollSignals() async {
    if (_networkSlug == null || _deviceId == null) return;

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/signal/poll'),
            headers: _headers,
            body: jsonEncode({
              'slug': _networkSlug,
              'machine_id': _deviceId,
              'license_key': _licenseKey ?? '',
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (!_isActive) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final signals = data['signals'] as List? ?? [];

        for (final s in signals) {
          if (!_isActive) return;
          try {
            final signal =
                SignalMessage.fromJson(s as Map<String, dynamic>);
            await _handleSignal(signal);
          } catch (e) {
            debugPrint('P2P signal parse error: $e');
          }
        }
      }
    } catch (e) {
      // Signal polling is best-effort
    }
  }

  /// Handle a received signaling message
  Future<void> _handleSignal(SignalMessage signal) async {
    if (signal.type != 'punch_request' && signal.type != 'punch_response') {
      return;
    }
    final peer = _peers[signal.fromVirtualIp];
    if (peer == null) return;
    _learnFromSignal(peer, signal.payload);
    if (!_mayContact(peer)) return;

    final peerPort = signal.payload['udp_port'] as int? ??
        signal.fromPublicPort ??
        0;
    final peerIp =
        signal.payload['public_ip'] as String? ?? signal.fromPublicIp;
    if (peerPort <= 0 || peerIp.isEmpty) return;
    peer.publicPort = peerPort;

    if (signal.type == 'punch_request') {
      // Peer wants to punch to us - punch back, and tell it where we are.
      // Only a request is answered, so the two never ping-pong forever.
      _punchTowards(peer, peerIp, peerPort);
      await _sendSignal(
        targetVirtualIp: signal.fromVirtualIp,
        type: 'punch_response',
        payload: _punchPayload,
      );
    } else {
      await _punchTowards(peer, peerIp, peerPort);
    }
  }

  /// Key and session from a punch signal. When the heartbeat carries keys
  /// it is the only key source; signals fill in for a server that doesn't.
  void _learnFromSignal(PeerConnection peer, Map<String, dynamic> payload) {
    final advert = payload['p2p_key'];
    if (!_serverRelaysKeys) {
      if (advert is String) {
        _applyKeyAdvert(peer, advert, fromServer: false);
      } else if (peer.publicKey == null) {
        // Apps with encryption always send their key: this one predates it.
        peer.security = P2pPeerSecurity.peerOutdated;
      }
      notifyListeners();
    }
    final key = peer.publicKey;
    final session = int.tryParse('${payload['p2p_session']}');
    if (key != null && session != null && session > 0) {
      _crypto?.notePeerSessionHint(key, session);
    }
  }

  /// Send a signaling message via the server
  Future<void> _sendSignal({
    required String targetVirtualIp,
    required String type,
    Map<String, dynamic>? payload,
  }) async {
    if (_networkSlug == null || _deviceId == null) return;

    try {
      await http
          .post(
            Uri.parse('$_baseUrl/signal'),
            headers: _headers,
            body: jsonEncode({
              'slug': _networkSlug,
              'machine_id': _deviceId,
              'license_key': _licenseKey ?? '',
              'target_virtual_ip': targetVirtualIp,
              'type': type,
              'payload': payload ?? {},
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('P2P signal send error: $e');
    }
  }

  /// Send keepalive hellos to directly connected peers
  void _sendKeepAlives() {
    if (_udpSocket == null) return;

    final staleThreshold = DateTime.now().subtract(_peerTimeout);
    var changed = false;

    for (final peer in _peers.values) {
      if (!peer.isDirectConnected) continue;
      if (peer.lastActivity.isBefore(staleThreshold)) {
        // Peer timed out
        peer.isDirectConnected = false;
        changed = true;
        continue;
      }
      _sendHello(peer, peer.publicIp, peer.publicPort);
    }

    if (changed) notifyListeners();
  }

  /// Relay a sealed packet through the server (fallback)
  Future<bool> _relayData(String targetVirtualIp, Uint8List packet) async {
    if (_networkSlug == null || _deviceId == null) return false;

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/relay'),
            headers: _headers,
            body: jsonEncode({
              'slug': _networkSlug,
              'source_machine_id': _deviceId,
              'license_key': _licenseKey ?? '',
              'target_virtual_ip': targetVirtualIp,
              'data': base64Encode(packet),
            }),
          )
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('P2P relay error: $e');
      return false;
    }
  }

  /// The peer at a public endpoint: exact IP:port first, else IP only
  PeerConnection? _peerAt(String publicIp, [int? publicPort]) {
    for (final peer in _peers.values) {
      if (peer.publicIp == publicIp &&
          (peer.publicPort == publicPort || peer.publicPort == 0)) {
        return peer;
      }
    }
    for (final peer in _peers.values) {
      if (peer.publicIp == publicIp) return peer;
    }
    return null;
  }

  // ── Screenshot demo data (lib/dev/shot_harness.dart only) ──
  void debugSeedPeers(Map<String, bool> directByVirtualIp) {
    _peers
      ..clear()
      ..addAll({
        for (final e in directByVirtualIp.entries)
          e.key: PeerConnection(
            virtualIp: e.key,
            publicIp: '203.0.113.${_peers.length + 10}',
            publicPort: 40000,
            displayName: e.key,
            isDirectConnected: e.value,
            security: P2pPeerSecurity.encrypted,
          ),
      });
    _isActive = true;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
