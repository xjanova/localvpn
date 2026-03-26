import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/member.dart';

/// P2P connection state for a single peer
class PeerConnection {
  final String virtualIp;
  final String publicIp;
  int publicPort;
  String displayName;
  bool isDirectConnected;
  DateTime lastActivity;
  int punchAttempts;

  PeerConnection({
    required this.virtualIp,
    required this.publicIp,
    required this.publicPort,
    required this.displayName,
    this.isDirectConnected = false,
    DateTime? lastActivity,
    this.punchAttempts = 0,
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
/// 1. Device joins network via server (tracker)
/// 2. Heartbeat returns peer list with public IP:port (like DHT)
/// 3. STUN endpoint reveals own public IP:port
/// 4. UDP hole punching attempts direct connection
/// 5. Falls back to server relay if hole punch fails
class P2pService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const int _maxPunchAttempts = 5;
  static const Duration _punchInterval = Duration(milliseconds: 500);
  static const Duration _signalPollInterval = Duration(seconds: 3);
  static const Duration _peerTimeout = Duration(seconds: 60);

  // Configuration
  String? _deviceId;
  String? _licenseKey;
  String? _networkSlug;

  // Own public endpoint (discovered via STUN)
  String? _publicIp;
  int? _publicPort;
  String? get publicIp => _publicIp;
  int? get publicPort => _publicPort;

  // UDP socket for P2P communication
  RawDatagramSocket? _udpSocket;
  int? _localPort;

  // Connected peers
  final Map<String, PeerConnection> _peers = {};
  Map<String, PeerConnection> get peers => Map.unmodifiable(_peers);

  // Peer data callbacks
  void Function(String virtualIp, Uint8List data)? onPeerData;

  // Timers
  Timer? _signalPollTimer;
  Timer? _keepAliveTimer;

  // State
  bool _isActive = false;
  bool get isActive => _isActive;

  String? _error;
  String? get error => _error;

  int get directPeerCount =>
      _peers.values.where((p) => p.isDirectConnected).length;
  int get relayPeerCount =>
      _peers.values.where((p) => !p.isDirectConnected).length;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
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

  /// Start P2P service for a network
  Future<bool> start(String networkSlug) async {
    if (_isActive) await stop();

    _networkSlug = networkSlug;
    _error = null;

    try {
      // 1. Bind UDP socket on any available port
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _localPort = _udpSocket!.port;
      debugPrint('P2P: UDP socket bound on port $_localPort');

      // Listen for incoming UDP packets
      _udpSocket!.listen(
        _handleUdpPacket,
        onError: (e) => debugPrint('P2P UDP error: $e'),
      );

      // 2. Discover own public IP:port via STUN
      await _discoverPublicEndpoint();

      // 3. Start polling for signaling messages
      _signalPollTimer = Timer.periodic(
        _signalPollInterval,
        (_) => _pollSignals(),
      );

      // 4. Keep-alive: send periodic pings to connected peers
      _keepAliveTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _sendKeepAlives(),
      );

      _isActive = true;
      notifyListeners();
      return true;
    } catch (e) {
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

    for (final peer in onlinePeers) {
      if (peer.virtualIp == null || peer.publicIp == null) continue;
      currentVirtualIps.add(peer.virtualIp!);

      final existing = _peers[peer.virtualIp!];
      if (existing != null) {
        // Update info but keep connection state
        existing.displayName = peer.displayName;
      } else {
        // New peer discovered - initiate hole punch
        _peers[peer.virtualIp!] = PeerConnection(
          virtualIp: peer.virtualIp!,
          publicIp: peer.publicIp!,
          publicPort: peer.publicPort ?? 0,
          displayName: peer.displayName,
        );

        // Initiate hole punch for new peer
        if (peer.publicPort != null && peer.publicPort! > 0) {
          _initiateHolePunch(peer.virtualIp!, peer.publicIp!, peer.publicPort!);
        }
      }
    }

    // Remove peers that went offline
    _peers.removeWhere(
      (vip, _) => !currentVirtualIps.contains(vip),
    );

    notifyListeners();
  }

  /// Send data to a peer (P2P direct or relay fallback)
  Future<bool> sendToPeer(String targetVirtualIp, Uint8List data) async {
    final peer = _peers[targetVirtualIp];

    // Try direct P2P first
    if (peer != null && peer.isDirectConnected && _udpSocket != null) {
      try {
        // Prepend virtual IP header (4 bytes) for routing
        final packet = _buildPacket(targetVirtualIp, data);
        final sent = _udpSocket!.send(
          packet,
          InternetAddress(peer.publicIp),
          peer.publicPort,
        );
        if (sent > 0) {
          peer.lastActivity = DateTime.now();
          return true;
        }
      } catch (e) {
        debugPrint('P2P direct send failed: $e');
        peer.isDirectConnected = false;
      }
    }

    // Fallback to server relay
    return _relayData(targetVirtualIp, data);
  }

  /// Initiate UDP hole punch to a peer
  Future<void> _initiateHolePunch(
    String targetVirtualIp,
    String targetPublicIp,
    int targetPublicPort,
  ) async {
    if (_udpSocket == null || _networkSlug == null) return;

    final peer = _peers[targetVirtualIp];
    if (peer == null || peer.isDirectConnected) return;

    debugPrint('P2P: Initiating hole punch to $targetVirtualIp '
        '($targetPublicIp:$targetPublicPort)');

    // Send signaling message asking peer to punch towards us
    await _sendSignal(
      targetVirtualIp: targetVirtualIp,
      type: 'punch_request',
      payload: {
        'udp_port': _localPort,
        'public_ip': _publicIp,
      },
    );

    // Send UDP punch packets
    peer.punchAttempts = 0;
    for (int i = 0; i < _maxPunchAttempts; i++) {
      if (!_isActive) return;
      peer.punchAttempts = i + 1;

      try {
        final punchData = utf8.encode('LVPN_PUNCH:$_publicIp:$_localPort');
        _udpSocket!.send(
          punchData,
          InternetAddress(targetPublicIp),
          targetPublicPort,
        );
      } catch (e) {
        debugPrint('P2P punch packet $i failed: $e');
      }

      await Future.delayed(_punchInterval);
    }
  }

  /// Handle incoming UDP packet
  void _handleUdpPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _udpSocket == null) return;

    final datagram = _udpSocket!.receive();
    if (datagram == null) return;

    final senderIp = datagram.address.address;
    final senderPort = datagram.port;
    final data = datagram.data;

    // Check if it's a punch packet
    final text = utf8.decode(data, allowMalformed: true);
    if (text.startsWith('LVPN_PUNCH:')) {
      _handlePunchPacket(senderIp, senderPort, text);
      return;
    }

    // Check if it's a keepalive
    if (text == 'LVPN_PING') {
      _udpSocket!.send(utf8.encode('LVPN_PONG'), datagram.address, senderPort);
      return;
    }

    if (text == 'LVPN_PONG') {
      // Peer is alive - update activity
      for (final peer in _peers.values) {
        if (peer.publicIp == senderIp && peer.publicPort == senderPort) {
          peer.lastActivity = DateTime.now();
          peer.isDirectConnected = true;
          break;
        }
      }
      return;
    }

    // Regular data packet - extract virtual IP and forward
    if (data.length > 4) {
      final virtualIp = _extractVirtualIp(data);
      if (virtualIp != null && onPeerData != null) {
        onPeerData!(virtualIp, Uint8List.sublistView(data, 4));
      }
    }
  }

  /// Handle a punch packet - establish direct connection
  void _handlePunchPacket(String senderIp, int senderPort, String text) {
    debugPrint('P2P: Received punch from $senderIp:$senderPort');

    // Find which peer this is from
    for (final peer in _peers.values) {
      if (peer.publicIp == senderIp ||
          text.contains(peer.publicIp)) {
        peer.isDirectConnected = true;
        peer.publicPort = senderPort;
        peer.lastActivity = DateTime.now();
        debugPrint('P2P: Direct connection established with '
            '${peer.virtualIp} ($senderIp:$senderPort)');

        // Send ack punch back
        try {
          _udpSocket?.send(
            utf8.encode('LVPN_PUNCH:${_publicIp ?? ""}:$_localPort'),
            InternetAddress(senderIp),
            senderPort,
          );
        } catch (_) {}

        notifyListeners();
        break;
      }
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

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final signals = data['signals'] as List? ?? [];

        for (final s in signals) {
          final signal =
              SignalMessage.fromJson(s as Map<String, dynamic>);
          _handleSignal(signal);
        }
      }
    } catch (e) {
      // Signal polling is best-effort
    }
  }

  /// Handle a received signaling message
  void _handleSignal(SignalMessage signal) {
    switch (signal.type) {
      case 'punch_request':
        // Peer wants to punch to us - punch back
        final peerPort = signal.payload['udp_port'] as int? ??
            signal.fromPublicPort ??
            0;
        final peerIp =
            signal.payload['public_ip'] as String? ?? signal.fromPublicIp;

        if (peerPort > 0 && peerIp.isNotEmpty) {
          // Update peer info
          final peer = _peers[signal.fromVirtualIp];
          if (peer != null) {
            peer.publicPort = peerPort;
          }

          // Punch towards them
          _initiateHolePunch(signal.fromVirtualIp, peerIp, peerPort);

          // Send response signal
          _sendSignal(
            targetVirtualIp: signal.fromVirtualIp,
            type: 'punch_response',
            payload: {
              'udp_port': _localPort,
              'public_ip': _publicIp,
            },
          );
        }
        break;

      case 'punch_response':
        // Peer responded - punch towards their port
        final peerPort = signal.payload['udp_port'] as int? ??
            signal.fromPublicPort ??
            0;
        final peerIp =
            signal.payload['public_ip'] as String? ?? signal.fromPublicIp;

        if (peerPort > 0 && peerIp.isNotEmpty) {
          final peer = _peers[signal.fromVirtualIp];
          if (peer != null) {
            peer.publicPort = peerPort;
          }
          _initiateHolePunch(signal.fromVirtualIp, peerIp, peerPort);
        }
        break;

      case 'punch_ack':
        // Connection confirmed
        final peer = _peers[signal.fromVirtualIp];
        if (peer != null) {
          peer.isDirectConnected = true;
          peer.lastActivity = DateTime.now();
          notifyListeners();
        }
        break;
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

  /// Send keepalive pings to directly connected peers
  void _sendKeepAlives() {
    if (_udpSocket == null) return;

    final staleThreshold = DateTime.now().subtract(_peerTimeout);

    for (final peer in _peers.values) {
      if (peer.isDirectConnected) {
        if (peer.lastActivity.isBefore(staleThreshold)) {
          // Peer timed out
          peer.isDirectConnected = false;
          notifyListeners();
          continue;
        }

        try {
          _udpSocket!.send(
            utf8.encode('LVPN_PING'),
            InternetAddress(peer.publicIp),
            peer.publicPort,
          );
        } catch (_) {
          peer.isDirectConnected = false;
        }
      }
    }
  }

  /// Relay data through the server (fallback)
  Future<bool> _relayData(String targetVirtualIp, Uint8List data) async {
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
              'data': base64Encode(data),
            }),
          )
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('P2P relay error: $e');
      return false;
    }
  }

  /// Build a packet with virtual IP header
  Uint8List _buildPacket(String virtualIp, Uint8List data) {
    final parts = virtualIp.split('.');
    if (parts.length != 4) return data;

    final header = Uint8List(4);
    for (int i = 0; i < 4; i++) {
      header[i] = int.parse(parts[i]);
    }

    final packet = Uint8List(4 + data.length);
    packet.setRange(0, 4, header);
    packet.setRange(4, 4 + data.length, data);
    return packet;
  }

  /// Extract virtual IP from packet header
  String? _extractVirtualIp(Uint8List data) {
    if (data.length < 4) return null;
    return '${data[0]}.${data[1]}.${data[2]}.${data[3]}';
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
