import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/member.dart';
import 'net/stun_client.dart';
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

/// How packets reach a peer right now.
enum P2pPath {
  /// Straight over UDP after the hole punch. Costs nothing.
  direct,

  /// Through the LVR1 relay, because the two NATs refuse a direct path.
  relay,

  /// Still punching; nothing reaches the peer yet.
  connecting,

  /// Different app version: nothing is exchanged.
  unavailable,
}

/// P2P connection state for a single peer
class PeerConnection {
  final String virtualIp;

  /// Where packets for this peer go: the endpoint its hello reply came
  /// from once direct, otherwise what the server last saw.
  String publicIp;
  int publicPort;
  String displayName;
  bool isDirectConnected;
  DateTime lastActivity;
  int punchAttempts;
  Uint8List? publicKey;
  P2pPeerSecurity security;

  /// Endpoints to try while punching: the peer's STUN mapping, its LAN
  /// addresses and what the server saw. Newest last, at most 8.
  final LinkedHashSet<String> candidates = LinkedHashSet<String>();

  /// What the peer said about its NAT: cone, symmetric or unknown.
  String natType = 'unknown';

  final DateTime since = DateTime.now();
  DateTime? burstUntil;
  DateTime? lastPunchRequest;

  /// Last authenticated packet that came straight from [publicIp]:[publicPort].
  DateTime? lastDirectAt;

  /// Last authenticated packet that came through the relay.
  DateTime? lastRelayedAt;

  /// The peer session whose hello reply set the current endpoint.
  int? directSession;

  InternetAddress? _address;
  String? _addressOf;

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

  /// [publicIp] parsed once, not per packet.
  InternetAddress? get address {
    if (_addressOf != publicIp) {
      _address = InternetAddress.tryParse(publicIp);
      _addressOf = publicIp;
    }
    return _address;
  }

  String get endpoint => '$publicIp:$publicPort';
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
    // PHP sends an empty payload as [] rather than {}.
    final payload = json['payload'];
    return SignalMessage(
      fromVirtualIp: json['from_virtual_ip'] as String,
      fromPublicIp: json['from_public_ip'] as String? ?? '',
      fromPublicPort: _asInt(json['from_public_port']),
      fromDisplayName: json['from_display_name'] as String? ?? 'Unknown',
      type: json['type'] as String,
      payload: payload is Map ? Map<String, dynamic>.from(payload) : {},
    );
  }
}

/// The LVR1 relay the server handed out with the heartbeat (see
/// docs/RELAY_FLEET.md).
class RelayInfo {
  final String host;
  final int port;
  final String token;
  final String? node;
  final DateTime? expiresAt;

  const RelayInfo({
    required this.host,
    required this.port,
    required this.token,
    this.node,
    this.expiresAt,
  });

  static RelayInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    final port = _asInt(json['port']);
    final token = json['token'];
    if (host is! String ||
        host.isEmpty ||
        port == null ||
        port <= 0 ||
        port > 65535 ||
        token is! String ||
        token.isEmpty ||
        token.length > 400) {
      return null;
    }
    return RelayInfo(
      host: host,
      port: port,
      token: token,
      node: json['node']?.toString(),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    );
  }
}

int? _asInt(Object? v) => switch (v) {
      final int i => i,
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };

/// Peer-to-peer transport for the virtual LAN and file transfer.
///
/// 1. One UDP socket. STUN over that same socket gives the public endpoint
///    peers must punch towards, and whether the NAT keeps one mapping for
///    every destination.
/// 2. Peers swap endpoints (STUN mapping + LAN addresses), keys and sessions
///    through the server's signalling, then both send hellos to every
///    candidate for a few seconds. A sealed hello reply makes the peer
///    direct, at the address it really came from.
/// 3. A peer that can't be reached directly (two symmetric NATs, CGNAT)
///    goes through the LVR1 UDP relay when the server offers one.
///
/// Everything sent to a peer, direct or relayed, is sealed by [P2pCrypto];
/// a peer without a usable key gets nothing.
class P2pService extends ChangeNotifier {
  P2pService({
    @visibleForTesting P2pIdentity? identity,
    @visibleForTesting List<(String, int)>? stunServers,
  })  : _fixedIdentity = identity,
        _stunServers = stunServers ?? StunClient.defaultServers;

  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const Duration _signalPollInterval = Duration(seconds: 3);
  static const Duration _keepAliveInterval = Duration(seconds: 10);
  static const Duration _directTimeout = Duration(seconds: 30);
  static const Duration _relayPathTimeout = Duration(seconds: 35);
  static const Duration _relayTimeout = Duration(seconds: 35);
  static const Duration _burstLength = Duration(seconds: 8);
  static const Duration _repunchEvery = Duration(seconds: 25);
  static const Duration _repunchViaRelayEvery = Duration(seconds: 90);
  static const Duration _stunWaitOnStart = Duration(milliseconds: 2500);
  static const Duration _pendingSignalLife = Duration(seconds: 30);
  static const Duration _reassemblyTimeout = Duration(seconds: 15);
  static const int _maxCandidates = 8;
  static const int _maxFragments = 512;
  static const int _maxOpenMessagesPerPeer = 32;
  static const int _maxReassemblyBytes = 16 << 20;
  static const int _relayBroadcastsPerSecond = 40;
  static const String _prefPrivateKey = 'p2p_x25519_private_key';
  static const String _prefLastSession = 'p2p_last_session_id';
  static const List<int> _relayMagic = [0x4C, 0x56, 0x52, 0x31]; // LVR1

  /// Largest file-message piece per datagram: with the 8-byte piece header,
  /// the seal and the relay header a datagram stays under 1280 bytes, so it
  /// is never fragmented by IP.
  static const int fragmentBytes = 1100;

  /// Shown when this app is too old for the people in the network.
  static const String updateAppMessage =
      'อัปเดตแอปเพื่อเชื่อมต่อกับเพื่อนในวงนี้';

  // Configuration
  String? _deviceId;
  String? _licenseKey;
  String? _networkSlug;
  final List<(String, int)> _stunServers;

  // Encryption
  final P2pIdentity? _fixedIdentity;
  Future<P2pIdentity>? _identity;
  P2pCrypto? _crypto;
  String? _keyAdvert;
  int _lastSessionId = 0;
  String? _ownVirtualIp;
  bool _serverRelaysKeys = false;
  bool _sawNewerWire = false;

  // Own endpoints
  String? _publicIp;
  int? _publicPort;
  String? get publicIp => _publicIp;
  int? get publicPort => _publicPort;
  NatMapping _nat = NatMapping.unknown;
  NatMapping get natMapping => _nat;
  bool _stunDone = false;
  bool _stunAnswered = false;
  List<String> _lanEndpoints = const [];

  // UDP socket for P2P communication
  RawDatagramSocket? _udpSocket;
  _Outbox? _outbox;
  StunClient? _stun;
  int? _localPort;

  @visibleForTesting
  int? get localUdpPort => _localPort;

  @visibleForTesting
  int? get localSession => _crypto?.localSession;

  // Connected peers
  final Map<String, PeerConnection> _peers = {};
  Map<String, PeerConnection> get peers => Map.unmodifiable(_peers);

  // Signals from members the heartbeat hasn't listed yet
  final Map<String, (SignalMessage, DateTime)> _pendingSignals = {};

  // File-message reassembly: peer → message id → pieces
  final Map<String, Map<int, _Reassembly>> _reassembly = {};
  int _reassemblyBytes = 0;
  int _messageId = Random.secure().nextInt(1 << 30);

  // Relay
  RelayInfo? _relay;
  InternetAddress? _relayAddress;
  Uint8List _relayCookie = Uint8List(8);
  bool _relayReady = false;
  DateTime? _relayHeardAt;
  DateTime? _lastChallengeAnswer;
  String? _relayRefusal;
  int _broadcastWindow = 0;
  int _relayBroadcasts = 0;

  /// The relay accepted our ticket and carries packets for us.
  bool get relayReady => _relayReady;

  /// Which relay node we use (from the ticket), for display.
  String? get relayNode => _relay?.node;

  // Peer data callbacks
  void Function(String virtualIp, Uint8List data)? onPeerData;
  void Function(String virtualIp, Uint8List data)? onFileMessage;

  // Timers
  Timer? _signalPollTimer;
  Timer? _keepAliveTimer;
  Timer? _punchTimer;
  int _keepAliveTicks = 0;

  // State
  bool _isActive = false;
  bool _isStarting = false;
  bool get isActive => _isActive;

  String? _error;
  String? get error => _error;

  /// How packets reach [virtualIp] now, or null for someone not in the
  /// network.
  P2pPath? pathOf(String? virtualIp) {
    final peer = virtualIp == null ? null : _peers[virtualIp];
    return peer == null ? null : _path(peer);
  }

  P2pPath _path(PeerConnection peer) {
    if (!_mayContact(peer)) return P2pPath.unavailable;
    if (peer.isDirectConnected) return P2pPath.direct;
    final relayed = peer.lastRelayedAt;
    if (_relayReady &&
        relayed != null &&
        DateTime.now().difference(relayed) < _relayPathTimeout) {
      return P2pPath.relay;
    }
    return P2pPath.connecting;
  }

  int _count(P2pPath path) =>
      _peers.values.where((p) => _path(p) == path).length;

  int get directPeerCount => _count(P2pPath.direct);
  int get relayPeerCount => _count(P2pPath.relay);
  int get connectingPeerCount => _count(P2pPath.connecting);

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
    return '${_who(names)} ใช้แอปเวอร์ชันเก่าที่ไม่เข้ารหัส — '
        'ให้อัปเดตแอปเพื่อเชื่อมต่อกับเพื่อนในวงนี้';
  }

  /// Why members are not connected yet, in Thai, or null if they are.
  String? get connectivityNotice {
    if (!_isActive || !_stunDone) return null;
    if (!_stunAnswered && !_relayReady) {
      return 'เน็ตที่ใช้อยู่บล็อกการเชื่อมต่อแบบ UDP — เพื่อนในวงจะเชื่อมถึง'
          'เครื่องนี้ไม่ได้ ลองสลับไปใช้เน็ตมือถือหรือ Wi-Fi อื่น';
    }
    final now = DateTime.now();
    final stuck = [
      for (final p in _peers.values)
        if (p.security == P2pPeerSecurity.encrypted &&
            _path(p) == P2pPath.connecting &&
            now.difference(p.since) > const Duration(seconds: 20))
          p.displayName,
    ];
    if (stuck.isEmpty) return null;
    final who = _who(stuck);
    if (_relayRefusal == 'quota') {
      return 'ใช้รีเลย์ครบโควตาของวันนี้แล้ว — เชื่อมกับ $who แบบตรงไม่ได้';
    }
    if (_nat == NatMapping.endpointDependent && !_relayReady) {
      return 'เราเตอร์ของคุณเปลี่ยนพอร์ตทุกปลายทาง (Symmetric NAT) — '
          'ยังเชื่อมตรงกับ $who ไม่ได้';
    }
    return 'ยังเชื่อมต่อกับ $who ไม่สำเร็จ — กำลังลองใหม่';
  }

  static String _who(List<String> names) => names.length <= 3
      ? names.join(', ')
      : '${names.take(3).join(', ')} และอีก ${names.length - 3} คน';

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
    _stunDone = false;
    _stunAnswered = false;
    _nat = NatMapping.unknown;

    RawDatagramSocket? socket;
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
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket = socket;
      _outbox = _Outbox(socket);
      _localPort = socket.port;
      _growBuffers(socket);
      _stun = StunClient(socket, servers: _stunServers);
      debugPrint('P2P: UDP socket bound on port $_localPort');
      socket.listen(
        _handleUdpEvent,
        onError: (e) => debugPrint('P2P UDP error: $e'),
      );

      _isActive = true;
      _keepAliveTicks = 0;
      _signalPollTimer =
          Timer.periodic(_signalPollInterval, (_) => _pollSignals());
      _keepAliveTimer =
          Timer.periodic(_keepAliveInterval, (_) => _keepAlive());
      _punchTimer = Timer.periodic(
          const Duration(milliseconds: 200), (_) => _punchTick());

      // 3. Public endpoint from STUN on this very socket. Wait briefly so
      // the first heartbeat carries it; slow answers still land later.
      await _discoverPublicEndpoint(socket)
          .timeout(_stunWaitOnStart, onTimeout: () {});
      _lanEndpoints = await _localEndpoints();
      if (!identical(_udpSocket, socket)) {
        _isStarting = false;
        return false; // stopped meanwhile
      }
      if (_relay != null) unawaited(_registerRelay());

      _isStarting = false;
      notifyListeners();
      return true;
    } catch (e) {
      // Clean up resources on failure to prevent leaks
      _cancelTimers();
      socket?.close();
      if (identical(_udpSocket, socket)) {
        _udpSocket = null;
        _outbox = null;
      }
      _stun = null;
      _localPort = null;
      _crypto = null;
      _isActive = false;
      _isStarting = false;

      _error = 'ไม่สามารถเริ่ม P2P ได้ — ลองเชื่อมต่อใหม่อีกครั้ง';
      debugPrint('P2P start error: $e');
      notifyListeners();
      return false;
    }
  }

  void _cancelTimers() {
    _signalPollTimer?.cancel();
    _signalPollTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _punchTimer?.cancel();
    _punchTimer = null;
  }

  /// Stop P2P service
  Future<void> stop() async {
    _cancelTimers();
    _udpSocket?.close();
    _udpSocket = null;
    _outbox = null;
    _stun = null;
    _localPort = null;
    _publicIp = null;
    _publicPort = null;
    _lanEndpoints = const [];
    _stunDone = false;
    _stunAnswered = false;
    _peers.clear();
    _pendingSignals.clear();
    _reassembly.clear();
    _reassemblyBytes = 0;
    _relay = null;
    _relayAddress = null;
    _relayReady = false;
    _relayRefusal = null;
    _relayCookie = Uint8List(8);
    _crypto = null;
    _ownVirtualIp = null;
    _serverRelaysKeys = false;
    _sawNewerWire = false;
    _isActive = false;
    _networkSlug = null;
    notifyListeners();
  }

  /// Room for bursts: a 32 KB file chunk is ~40 datagrams, and the OS
  /// default (64 KB on Windows) drops the tail of a few at once.
  static void _growBuffers(RawDatagramSocket socket) {
    final (rcv, snd) = switch (Platform.operatingSystem) {
      'linux' || 'android' => (8, 7),
      _ => (0x1002, 0x1001), // Windows, macOS, iOS
    };
    for (final option in [rcv, snd]) {
      try {
        socket.setRawOption(
            RawSocketOption.fromInt(RawSocketOption.levelSocket, option, 1 << 20));
      } catch (e) {
        debugPrint('P2P socket buffer not changed: $e');
      }
    }
  }

  // ── Own endpoints ─────────────────────────────────────────────────────

  Future<void> _discoverPublicEndpoint(RawDatagramSocket socket) async {
    final stun = _stun;
    if (stun == null) return;
    final (mapping, nat) = await stun.discover();
    if (!identical(_udpSocket, socket)) return;
    _nat = nat;
    _stunDone = true;
    if (mapping != null) {
      _stunAnswered = true;
      _setPublicEndpoint(mapping.address.address, mapping.port);
      return;
    }
    // No STUN answer (UDP blocked, or no STUN reachable). The server can
    // still tell us our public IP; the port is a guess that is right only
    // behind port-preserving NATs.
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/stun'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (!identical(_udpSocket, socket) || response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final ip = data['ip'] as String?;
      if (ip != null && _publicIp == null) {
        _setPublicEndpoint(ip, _localPort ?? 0);
      }
    } catch (e) {
      debugPrint('P2P STUN fallback error: $e');
    }
    notifyListeners();
  }

  void _setPublicEndpoint(String ip, int port) {
    if (ip == _publicIp && port == _publicPort) return;
    _publicIp = ip;
    _publicPort = port;
    debugPrint('P2P: public endpoint $ip:$port ($_nat)');
    // Peers still punching need the new endpoint: ask them again.
    for (final peer in _peers.values) {
      if (!peer.isDirectConnected) peer.lastPunchRequest = null;
    }
    notifyListeners();
  }

  Future<void> _refreshStun() async {
    final socket = _udpSocket;
    final stun = _stun;
    if (socket == null || stun == null) return;
    final mapping = await stun.refresh();
    if (mapping == null || !identical(_udpSocket, socket)) return;
    _stunAnswered = true;
    _setPublicEndpoint(mapping.address.address, mapping.port);
  }

  /// Private IPv4 addresses of this machine with our UDP port, so members
  /// behind the same router connect over the LAN (many routers can't
  /// hairpin to their own public address).
  Future<List<String>> _localEndpoints() async {
    final port = _localPort;
    if (port == null) return const [];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final ownNet = _ownVirtualIp?.split('.').take(3).join('.');
      final out = <String>[];
      for (final i in interfaces) {
        final name = i.name.toLowerCase();
        // Our own virtual adapter and VPN tunnels are not a LAN path.
        if (name.contains('localvpn') ||
            name.contains('tun') ||
            name.contains('wg') ||
            name.contains('wireguard')) {
          continue;
        }
        for (final a in i.addresses) {
          final ip = a.address;
          if (ownNet != null && ip.startsWith('$ownNet.')) continue;
          if (_isPrivate(ip)) out.add('$ip:$port');
        }
      }
      return out.take(4).toList();
    } catch (_) {
      return const [];
    }
  }

  static bool _isPrivate(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((e) => e == null)) return false;
    final a = p[0]!, b = p[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  // ── Members ───────────────────────────────────────────────────────────

  /// Update peer list from heartbeat response
  void updatePeers(List<NetworkMember> onlinePeers) {
    final currentVirtualIps = <String>{};
    final toPunch = <PeerConnection>[];
    final deferred = <SignalMessage>[];
    final now = DateTime.now();
    _pendingSignals
        .removeWhere((_, s) => now.difference(s.$2) > _pendingSignalLife);

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
      peer ??= _peers[vip] = PeerConnection(
        virtualIp: vip,
        publicIp: member.publicIp!,
        publicPort: member.publicPort ?? 0,
        displayName: member.displayName,
      );
      peer.displayName = member.displayName;
      if (!peer.isDirectConnected) {
        peer.publicIp = member.publicIp!;
        if (member.publicPort case final port?) peer.publicPort = port;
      }
      _addCandidate(peer, member.publicIp, member.publicPort);

      final keyChanged = _applyKeyAdvert(
        peer,
        member.p2pKey,
        fromServer: member.reportsP2pKey,
      );
      final pending = isNew ? _pendingSignals.remove(vip) : null;
      if (pending != null) deferred.add(pending.$1);
      if (keyChanged || (isNew && pending?.$1.type != 'punch_request')) {
        toPunch.add(peer);
      }
    }

    // Remove peers that went offline
    _peers.removeWhere((vip, _) => !currentVirtualIps.contains(vip));
    for (final vip in _reassembly.keys.toList()) {
      if (!currentVirtualIps.contains(vip)) _dropReassembly(vip);
    }

    notifyListeners();

    for (final signal in deferred) {
      _handleSignal(signal);
    }
    for (final peer in toPunch) {
      _requestHolePunch(peer);
    }
  }

  void _addCandidate(PeerConnection peer, String? ip, int? port) {
    if (ip == null || port == null || !_usableEndpoint(ip, port)) return;
    final endpoint = '$ip:$port';
    peer.candidates
      ..remove(endpoint)
      ..add(endpoint);
    while (peer.candidates.length > _maxCandidates) {
      peer.candidates.remove(peer.candidates.first);
    }
  }

  void _addEndpoint(PeerConnection peer, String endpoint) {
    final i = endpoint.lastIndexOf(':');
    if (i <= 0) return;
    _addCandidate(peer, endpoint.substring(0, i),
        int.tryParse(endpoint.substring(i + 1)));
  }

  /// Unicast IPv4 only: a candidate that names a broadcast or multicast
  /// address would turn our hellos into a flood.
  static bool _usableEndpoint(String ip, int port) {
    if (port <= 0 || port > 65535) return false;
    final address = InternetAddress.tryParse(ip);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final first = address.rawAddress[0];
    return first != 0 && first < 224;
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
      peer.directSession = null;
    }
    return changed;
  }

  /// Whether we exchange anything at all with [peer].
  bool _mayContact(PeerConnection peer) =>
      peer.security == P2pPeerSecurity.pendingKey ||
      peer.security == P2pPeerSecurity.encrypted;

  // ── Sending ───────────────────────────────────────────────────────────

  /// Send a virtual-LAN packet to a peer: direct, or through the relay.
  /// Returns false, sending nothing, when it can't be encrypted for the
  /// peer or there is no path yet.
  Future<bool> sendToPeer(String targetVirtualIp, Uint8List data) async =>
      _sendPacket(targetVirtualIp, P2pPacketType.data, data);

  /// Send a virtual-LAN (TUN) packet to one peer.
  Future<bool> sendTunPacket(String targetVirtualIp, Uint8List packet) async =>
      _sendPacket(targetVirtualIp, P2pPacketType.data, packet);

  /// Send a broadcast TUN packet (LAN game discovery) to every peer we have
  /// a path to, sealed for each. Relayed broadcasts are capped: one LAN game
  /// can send dozens per second.
  void broadcastTunPacket(Uint8List packet) {
    final second = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (second != _broadcastWindow) {
      _broadcastWindow = second;
      _relayBroadcasts = 0;
    }
    for (final peer in _peers.values) {
      final path = _path(peer);
      if (path == P2pPath.relay) {
        if (_relayBroadcasts >= _relayBroadcastsPerSecond) continue;
        _relayBroadcasts++;
      } else if (path != P2pPath.direct) {
        continue;
      }
      final sealed = _seal(peer, P2pPacketType.data, packet);
      if (sealed != null) _deliver(peer, sealed);
    }
  }

  /// Send a file-transfer message (LVPN_FILE_…) to a peer. Messages bigger
  /// than one datagram go as separately sealed pieces.
  Future<bool> sendFileMessage(String targetVirtualIp, Uint8List message) async {
    final peer = _peers[targetVirtualIp];
    if (peer == null) return false;
    if (message.length <= fragmentBytes) {
      final sealed = _seal(peer, P2pPacketType.file, message);
      return sealed != null && _deliver(peer, sealed);
    }
    final count = (message.length + fragmentBytes - 1) ~/ fragmentBytes;
    if (count > _maxFragments) return false;
    _messageId = (_messageId + 1) & 0xFFFFFFFF;
    for (var i = 0; i < count; i++) {
      final start = i * fragmentBytes;
      final end = min(message.length, start + fragmentBytes);
      final piece = Uint8List(8 + end - start);
      ByteData.sublistView(piece, 0, 8)
        ..setUint32(0, _messageId)
        ..setUint16(4, i)
        ..setUint16(6, count);
      piece.setRange(8, piece.length, message, start);
      final sealed = _seal(peer, P2pPacketType.fileFragment, piece);
      if (sealed == null || !_deliver(peer, sealed)) return false;
    }
    return true;
  }

  bool _sendPacket(String virtualIp, P2pPacketType type, List<int> payload) {
    final peer = _peers[virtualIp];
    if (peer == null) return false;
    final sealed = _seal(peer, type, payload);
    return sealed != null && _deliver(peer, sealed);
  }

  /// A sealed packet to [peer]: straight to its endpoint when direct,
  /// otherwise through the relay.
  bool _deliver(PeerConnection peer, Uint8List sealed) {
    final outbox = _outbox;
    if (outbox == null) return false;
    if (peer.isDirectConnected) {
      final address = peer.address;
      if (address != null && outbox.send(sealed, address, peer.publicPort)) {
        return true;
      }
    }
    return _sendViaRelay(peer.virtualIp, sealed);
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

  void _send(List<int> data, InternetAddress to, int port) {
    _outbox?.send(data, to, port);
  }

  // ── Punching ──────────────────────────────────────────────────────────

  /// What a punch signal carries: every endpoint we might be reached on,
  /// our NAT type, key and session. The key and session let a peer reach
  /// us even when the server doesn't relay keys.
  Map<String, dynamic> get _punchPayload => {
        'udp_port': _publicPort ?? _localPort,
        'public_ip': _publicIp,
        if (_publicIp != null && _publicPort != null)
          'ep': '$_publicIp:$_publicPort',
        if (_lanEndpoints.isNotEmpty) 'lan': _lanEndpoints.join(','),
        'nat': switch (_nat) {
          NatMapping.endpointIndependent => 'cone',
          NatMapping.endpointDependent => 'symmetric',
          NatMapping.unknown => 'unknown',
        },
        if (_keyAdvert case final advert?) 'p2p_key': advert,
        if (_crypto case final crypto?)
          'p2p_session': '${crypto.localSession}',
      };

  /// Ask a peer (via signaling) to punch towards us, and start punching.
  void _requestHolePunch(PeerConnection peer) {
    if (_udpSocket == null || _networkSlug == null) return;
    if (peer.isDirectConnected || !_mayContact(peer)) return;
    debugPrint('P2P: punching to ${peer.virtualIp} '
        '(${peer.candidates.length} candidates)');
    peer.lastPunchRequest = DateTime.now();
    unawaited(_sendSignal(
      targetVirtualIp: peer.virtualIp,
      type: 'punch_request',
      payload: _punchPayload,
    ));
    _startBurst(peer);
    _helloViaRelay(peer);
  }

  /// Hellos to every candidate for a few seconds; both sides do this at
  /// once, so each NAT sees outgoing traffic before the other's arrives.
  void _startBurst(PeerConnection peer) {
    peer.burstUntil = DateTime.now().add(_burstLength);
    peer.punchAttempts = 0;
    _helloCandidates(peer);
  }

  void _helloCandidates(PeerConnection peer) {
    if (peer.candidates.isEmpty) {
      _sendHello(peer, peer.publicIp, peer.publicPort);
      return;
    }
    for (final endpoint in peer.candidates) {
      final i = endpoint.lastIndexOf(':');
      _sendHello(peer, endpoint.substring(0, i),
          int.parse(endpoint.substring(i + 1)));
    }
  }

  /// Every 200 ms: hellos for peers in a burst (each tick for the first two
  /// seconds, then every second), a new round for peers still not direct.
  void _punchTick() {
    if (_udpSocket == null || _ownVirtualIp == null) return;
    final now = DateTime.now();
    for (final peer in _peers.values) {
      if (peer.isDirectConnected || !_mayContact(peer)) continue;
      final until = peer.burstUntil;
      if (until != null && now.isBefore(until)) {
        peer.punchAttempts++;
        if (peer.punchAttempts <= 10 || peer.punchAttempts % 5 == 0) {
          _helloCandidates(peer);
        }
        continue;
      }
      final last = peer.lastPunchRequest;
      final every = _path(peer) == P2pPath.relay
          ? _repunchViaRelayEvery
          : _repunchEvery;
      if (last == null || now.difference(last) > every) {
        _requestHolePunch(peer);
      }
    }
  }

  void _sendHello(PeerConnection peer, String ip, int port) {
    if (port <= 0) return;
    final address = InternetAddress.tryParse(ip);
    if (address == null) return;
    final packet = _seal(peer, P2pPacketType.hello, const []);
    if (packet != null) _send(packet, address, port);
  }

  /// A sealed hello reply from [from]:[port], bound to our session: the path
  /// works both ways now. A working endpoint is replaced only by one from a
  /// restarted peer, by a LAN path, or when it has gone quiet, so the two
  /// sides don't flap between candidates while both still burst.
  void _confirmEndpoint(
    PeerConnection peer,
    InternetAddress from,
    int port,
    int session,
  ) {
    final ip = from.address;
    final now = DateTime.now();
    if (peer.isDirectConnected &&
        peer.publicIp == ip &&
        peer.publicPort == port) {
      peer.lastDirectAt = now;
      peer.directSession = session;
      return;
    }
    if (peer.isDirectConnected) {
      final last = peer.lastDirectAt;
      final quiet =
          last == null || now.difference(last) > const Duration(seconds: 3);
      final restarted = peer.directSession != session;
      final lanPath = _isPrivate(ip) && !_isPrivate(peer.publicIp);
      if (!quiet && !restarted && !lanPath) return;
    }
    peer
      ..isDirectConnected = true
      ..publicIp = ip
      ..publicPort = port
      ..lastDirectAt = now
      ..directSession = session
      ..burstUntil = null;
    debugPrint('P2P: direct path to ${peer.virtualIp} via $ip:$port');
    notifyListeners();
  }

  // ── Receiving ─────────────────────────────────────────────────────────

  void _handleUdpEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.write) {
      _outbox?.flush();
      return;
    }
    if (event != RawSocketEvent.read) return;
    final socket = _udpSocket;
    if (socket == null) return;
    while (identical(_udpSocket, socket)) {
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        _handleDatagram(datagram);
      } catch (e) {
        debugPrint('P2P packet error: $e');
      }
    }
  }

  void _handleDatagram(Datagram datagram) {
    final data = datagram.data;
    if (data.isEmpty) return;
    // STUN answers share the socket; they would look like junk below.
    if (_stun?.handle(datagram) ?? false) return;
    if (_isRelayDatagram(datagram)) {
      _handleRelay(data);
      return;
    }
    switch (P2pWire.classify(data)) {
      case P2pWireKind.current:
        _handleSealed(data, from: datagram.address, port: datagram.port);
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

  /// A sealed packet, straight from [from]:[port] or relayed for
  /// [relayedFrom]. Relayed packets prove the relay path only: they never
  /// make a peer direct, move its endpoint or trigger a hello to an address.
  void _handleSealed(
    Uint8List data, {
    InternetAddress? from,
    int? port,
    String? relayedFrom,
  }) {
    final header = P2pWire.parseHeader(data);
    if (header == null) return;
    if (relayedFrom != null && header.senderVirtualIp != relayedFrom) return;
    final peer = _peers[header.senderVirtualIp];
    final key = peer?.publicKey;
    final crypto = _crypto;
    if (peer == null || key == null || crypto == null) return;

    // Forged, tampered, replayed or stale packets stop here
    final opened = crypto.open(data, peerKey: key);
    if (opened == null) return;
    final now = DateTime.now();
    peer.lastActivity = now;
    final relayed = relayedFrom != null;
    if (relayed) {
      final wasRelay = _path(peer) == P2pPath.relay;
      peer.lastRelayedAt = now;
      if (!wasRelay && _path(peer) == P2pPath.relay) notifyListeners();
    } else if (peer.isDirectConnected &&
        from!.address == peer.publicIp &&
        port == peer.publicPort) {
      peer.lastDirectAt = now;
    }

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
        if (relayed) {
          _sendViaRelay(peer.virtualIp, reply);
          return;
        }
        _send(reply, from!, port!);
        // A hello alone could be a replay, so it doesn't make the peer
        // direct or move its endpoint. Our own hello does, once its reply
        // comes back (new peer, or the peer restarted on another port).
        if (!peer.isDirectConnected ||
            peer.publicIp != from.address ||
            peer.publicPort != port) {
          _sendHello(peer, from.address, port);
        }
      case P2pPacketType.helloReply:
        if (!relayed) {
          _confirmEndpoint(peer, from!, port!, opened.senderSession);
        }
      case P2pPacketType.data:
        onPeerData?.call(peer.virtualIp, opened.payload);
      case P2pPacketType.file:
        onFileMessage?.call(peer.virtualIp, opened.payload);
      case P2pPacketType.fileFragment:
        _absorbFragment(peer, opened.payload);
    }
  }

  /// One piece of a file message; delivers the message once all are in.
  void _absorbFragment(PeerConnection peer, Uint8List payload) {
    if (payload.length < 8) return;
    final h = ByteData.sublistView(payload, 0, 8);
    final id = h.getUint32(0);
    final index = h.getUint16(4);
    final count = h.getUint16(6);
    if (count < 2 || count > _maxFragments || index >= count) return;

    final now = DateTime.now();
    final open = _reassembly.putIfAbsent(peer.virtualIp, () => {});
    for (final stale in open.entries
        .where((e) => now.difference(e.value.started) > _reassemblyTimeout)
        .toList()) {
      _reassemblyBytes -= stale.value.bytes;
      open.remove(stale.key);
    }
    var message = open[id];
    if (message == null) {
      if (open.length >= _maxOpenMessagesPerPeer ||
          _reassemblyBytes >= _maxReassemblyBytes) {
        return;
      }
      message = open[id] = _Reassembly(count);
    }
    if (message.parts.length != count || message.parts[index] != null) return;

    final piece = Uint8List.fromList(Uint8List.sublistView(payload, 8));
    message.parts[index] = piece;
    message.received++;
    message.bytes += piece.length;
    _reassemblyBytes += piece.length;
    if (message.received < count) return;

    open.remove(id);
    _reassemblyBytes -= message.bytes;
    final all = BytesBuilder(copy: false);
    for (final part in message.parts) {
      all.add(part!);
    }
    onFileMessage?.call(peer.virtualIp, all.toBytes());
  }

  void _dropReassembly(String virtualIp) {
    final open = _reassembly.remove(virtualIp);
    if (open == null) return;
    for (final m in open.values) {
      _reassemblyBytes -= m.bytes;
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

  // ── Relay (LVR1, docs/RELAY_FLEET.md) ─────────────────────────────────

  /// The relay ticket from the latest heartbeat (null = none offered).
  void setRelay(RelayInfo? relay) {
    final old = _relay;
    _relay = relay;
    if (relay == null) {
      if (old != null) {
        _relayAddress = null;
        _relayReady = false;
        notifyListeners();
      }
      return;
    }
    final moved = old == null || old.host != relay.host || old.port != relay.port;
    if (moved) {
      _relayAddress = null;
      _relayReady = false;
      _relayCookie = Uint8List(8);
    }
    if (moved || old.token != relay.token) unawaited(_registerRelay());
  }

  /// Register (or keep alive) with the relay. A missing or stale cookie
  /// gets a challenge back, answered at once in [_handleRelay].
  Future<void> _registerRelay() async {
    final relay = _relay;
    final socket = _udpSocket;
    if (relay == null || socket == null) return;
    var address = _relayAddress;
    if (address == null) {
      try {
        address = InternetAddress.tryParse(relay.host) ??
            (await InternetAddress.lookup(relay.host,
                        type: InternetAddressType.IPv4)
                    .timeout(const Duration(seconds: 5)))
                .first;
      } catch (e) {
        debugPrint('P2P relay ${relay.host} not resolved: $e');
        return;
      }
      if (!identical(_relay, relay) || !identical(_udpSocket, socket)) return;
      _relayAddress = address;
    }
    final token = utf8.encode(relay.token);
    final frame = Uint8List(13 + token.length)
      ..setRange(0, 4, _relayMagic)
      ..[4] = 0x01
      ..setRange(5, 13, _relayCookie)
      ..setRange(13, 13 + token.length, token);
    _send(frame, address, relay.port);
  }

  bool _isRelayDatagram(Datagram datagram) {
    final address = _relayAddress;
    final relay = _relay;
    if (address == null ||
        relay == null ||
        datagram.port != relay.port ||
        datagram.address.address != address.address) {
      return false;
    }
    final b = datagram.data;
    return b.length >= 5 &&
        b[0] == _relayMagic[0] &&
        b[1] == _relayMagic[1] &&
        b[2] == _relayMagic[2] &&
        b[3] == _relayMagic[3];
  }

  void _handleRelay(Uint8List b) {
    final now = DateTime.now();
    _relayHeardAt = now;
    switch (b[4]) {
      case 0x07: // cookie challenge
        if (b.length < 13) return;
        _relayCookie = Uint8List.fromList(b.sublist(5, 13));
        final last = _lastChallengeAnswer;
        if (last != null && now.difference(last) < const Duration(seconds: 1)) {
          return;
        }
        _lastChallengeAnswer = now;
        unawaited(_registerRelay());
      case 0x06: // registered
        _relayRefusal = null;
        if (!_relayReady) {
          _relayReady = true;
          debugPrint('P2P: relay ${_relay?.node ?? _relay?.host} ready');
          // Swap sessions with everyone still punching, so packets can
          // flow through the relay right away.
          for (final peer in _peers.values) {
            _helloViaRelay(peer);
          }
          notifyListeners();
        }
      case 0x05: // refused
        _relayRefusal =
            utf8.decode(b.sublist(5, min(b.length, 64)), allowMalformed: true);
        debugPrint('P2P: relay refused: $_relayRefusal');
        _relayReady = false;
        notifyListeners();
        // The relay restarted and forgot us: register again at once.
        final last = _lastChallengeAnswer;
        if (_relayRefusal == 'unknown' &&
            (last == null || now.difference(last) > const Duration(seconds: 1))) {
          _lastChallengeAnswer = now;
          unawaited(_registerRelay());
        }
      case 0x02: // a sealed packet from a member
        if (b.length < 9 + P2pWire.overhead) return;
        final src = '${b[5]}.${b[6]}.${b[7]}.${b[8]}';
        final packet = Uint8List.sublistView(b, 9);
        if (P2pWire.classify(packet) != P2pWireKind.current) return;
        _handleSealed(packet, relayedFrom: src);
    }
  }

  /// A hello through the relay: its reply proves the relay path and tells
  /// both sides each other's session.
  void _helloViaRelay(PeerConnection peer) {
    if (!_relayReady || peer.isDirectConnected) return;
    final hello = _seal(peer, P2pPacketType.hello, const []);
    if (hello != null) _sendViaRelay(peer.virtualIp, hello);
  }

  bool _sendViaRelay(String virtualIp, Uint8List sealed) {
    final relay = _relay;
    final address = _relayAddress;
    final outbox = _outbox;
    if (!_relayReady || relay == null || address == null || outbox == null) {
      return false;
    }
    final dst = InternetAddress.tryParse(virtualIp);
    if (dst == null || dst.type != InternetAddressType.IPv4) return false;
    final frame = Uint8List(9 + sealed.length)
      ..setRange(0, 4, _relayMagic)
      ..[4] = 0x02
      ..setRange(5, 9, dst.rawAddress)
      ..setRange(9, 9 + sealed.length, sealed);
    return outbox.send(frame, address, relay.port);
  }

  // ── Keepalive ─────────────────────────────────────────────────────────

  /// Every 10 s: hellos keep direct paths (and their NAT mappings) open,
  /// relayed hellos prove the relay path, the relay registration is
  /// renewed, and once a minute STUN and the LAN addresses are checked
  /// again (the phone may have changed networks).
  void _keepAlive() {
    if (_udpSocket == null) return;
    _keepAliveTicks++;
    final now = DateTime.now();
    var changed = false;

    for (final peer in _peers.values) {
      if (!_mayContact(peer)) continue;
      if (peer.isDirectConnected) {
        final last = peer.lastDirectAt ?? peer.lastActivity;
        if (now.difference(last) <= _directTimeout) {
          _sendHello(peer, peer.publicIp, peer.publicPort);
          continue;
        }
        // Peer timed out on its direct path: punch again soon
        peer.isDirectConnected = false;
        peer.lastPunchRequest = null;
        changed = true;
      }
      _helloViaRelay(peer);
    }

    if (_relay != null) {
      final heard = _relayHeardAt;
      if (_relayReady &&
          (heard == null || now.difference(heard) > _relayTimeout)) {
        _relayReady = false;
        changed = true;
      }
      unawaited(_registerRelay());
    }

    if (_keepAliveTicks % 6 == 0) {
      unawaited(_refreshStun());
      unawaited(_localEndpoints().then((e) {
        if (_isActive) _lanEndpoints = e;
      }));
    }
    if (changed) notifyListeners();
  }

  // ── Signalling ────────────────────────────────────────────────────────

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

      if (!_isActive || response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      for (final s in data['signals'] as List? ?? const []) {
        if (!_isActive) return;
        try {
          _handleSignal(SignalMessage.fromJson(s as Map<String, dynamic>));
        } catch (e) {
          debugPrint('P2P signal parse error: $e');
        }
      }
    } catch (e) {
      // Signal polling is best-effort
    }
  }

  /// Handle a received signaling message
  void _handleSignal(SignalMessage signal) {
    if (signal.type != 'punch_request' && signal.type != 'punch_response') {
      return;
    }
    final vip = signal.fromVirtualIp;
    final peer = _peers[vip];
    if (peer == null) {
      // Not in our member list yet (the heartbeat lags up to 15 s): keep
      // the newest signal from it for a little while.
      if (_pendingSignals.length < 64 || _pendingSignals.containsKey(vip)) {
        _pendingSignals[vip] = (signal, DateTime.now());
      }
      return;
    }
    _learnFromSignal(peer, signal.payload);
    _absorbEndpoints(peer, signal);
    if (!_mayContact(peer)) return;

    if (signal.type == 'punch_request') {
      // Tell it where we are. Only a request is answered, so the two never
      // ping-pong forever.
      peer.lastPunchRequest = DateTime.now();
      unawaited(_sendSignal(
        targetVirtualIp: vip,
        type: 'punch_response',
        payload: _punchPayload,
      ));
    }
    if (peer.isDirectConnected) {
      // Our side works; the peer's hellos get answered as they arrive.
      _helloCandidates(peer);
    } else {
      _startBurst(peer);
    }
  }

  /// Every endpoint a punch signal names becomes a candidate.
  void _absorbEndpoints(PeerConnection peer, SignalMessage signal) {
    final p = signal.payload;
    _addCandidate(peer, signal.fromPublicIp, signal.fromPublicPort);
    final legacyIp = p['public_ip'];
    _addCandidate(
      peer,
      legacyIp is String ? legacyIp : signal.fromPublicIp,
      _asInt(p['udp_port']),
    );
    final lan = p['lan'];
    if (lan is String) {
      for (final e in lan.split(',').take(4)) {
        _addEndpoint(peer, e.trim());
      }
    }
    final ep = p['ep'];
    if (ep is String) _addEndpoint(peer, ep);
    final nat = p['nat'];
    if (nat is String && nat.length <= 16) peer.natType = nat;
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
    final now = DateTime.now();
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
          )..lastRelayedAt = e.value ? null : now,
      });
    _relayReady = directByVirtualIp.values.any((direct) => !direct);
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

/// Sends datagrams, queueing what the OS can't take right now and sending
/// it on the next write event. `send` returns 0 when the buffer is full,
/// and on Windows also while the previous send is still in flight, so a
/// burst (a file chunk is ~40 datagrams) would otherwise lose most of it.
class _Outbox {
  _Outbox(this.socket);

  static const int maxBytes = 4 << 20;

  final RawDatagramSocket socket;
  final Queue<(List<int>, InternetAddress, int)> _queue = Queue();
  int _bytes = 0;

  /// False only when the datagram is dropped (queue full or socket error).
  bool send(List<int> data, InternetAddress to, int port) {
    if (_queue.isEmpty) {
      try {
        if (socket.send(data, to, port) > 0) return true;
      } catch (e) {
        debugPrint('P2P send to ${to.address}:$port failed: $e');
        return false;
      }
    }
    if (_bytes + data.length > maxBytes) return false;
    _queue.add((data, to, port));
    _bytes += data.length;
    socket.writeEventsEnabled = true;
    return true;
  }

  void flush() {
    while (_queue.isNotEmpty) {
      final (data, to, port) = _queue.first;
      var sent = 0;
      try {
        sent = socket.send(data, to, port);
      } catch (e) {
        sent = -1; // unsendable: drop it, keep the rest moving
      }
      if (sent == 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      _queue.removeFirst();
      _bytes -= data.length;
    }
  }
}

class _Reassembly {
  _Reassembly(int count) : parts = List<Uint8List?>.filled(count, null);
  final List<Uint8List?> parts;
  final DateTime started = DateTime.now();
  int received = 0;
  int bytes = 0;
}
