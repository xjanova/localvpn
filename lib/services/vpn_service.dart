import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'p2p_service.dart';

class VpnService extends ChangeNotifier {
  static const MethodChannel _channel =
      MethodChannel('com.xjanova.localvpn/vpn');

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  String? _virtualIp;
  String? get virtualIp => _virtualIp;

  String? _error;
  String? get error => _error;

  /// Machine-readable reason for the last failure, e.g. `ADMIN_REQUIRED`
  /// on Windows when the app is not running as administrator.
  String? _errorCode;
  String? get errorCode => _errorCode;
  bool get needsAdmin => _errorCode == 'ADMIN_REQUIRED';

  // Virtual subnet of the running tunnel (host byte order), used to spot
  // broadcast packets that must go to every peer.
  int _netMask = 0;
  int _netAddr = 0;

  bool _isStarting = false;
  bool get isStarting => _isStarting;

  P2pService? _p2pService;

  /// P2P connection stats
  int get directPeers => _p2pService?.directPeerCount ?? 0;
  int get relayPeers => _p2pService?.relayPeerCount ?? 0;
  bool get hasP2p => _p2pService != null && _p2pService!.isActive;

  VpnService() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// Attach P2P service for direct peer connections
  void attachP2p(P2pService p2p) {
    _p2pService = p2p;

    // Listen for incoming P2P data and forward to TUN
    _p2pService!.onPeerData = _onP2pDataReceived;
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onVpnStatusChanged':
        final status = call.arguments as String?;
        _isConnected = status == 'connected';
        notifyListeners();
        break;
      case 'onVpnError':
        _error = call.arguments as String?;
        _errorCode = 'TUNNEL_FAILED';
        _isConnected = false;
        _isStarting = false;
        notifyListeners();
        break;
      case 'onTunPacket':
        // Outgoing packet from TUN - route via P2P
        final packetData = call.arguments as Uint8List?;
        if (packetData != null) {
          _handleOutgoingPacket(packetData);
        }
        break;
      case 'onTunPackets':
        // Windows batches every packet read since the last delivery.
        final packets = call.arguments as List?;
        if (packets != null) {
          for (final p in packets) {
            if (p is Uint8List) _handleOutgoingPacket(p);
          }
        }
        break;
    }
  }

  Future<bool> startVpn({
    required String virtualIp,
    required String subnet,
    required List<Map<String, String>> peers,
  }) async {
    _isStarting = true;
    _error = null;
    _errorCode = null;
    _setSubnet(virtualIp, subnet);
    notifyListeners();

    try {
      final result = await _channel.invokeMethod<bool>('startVpn', {
        'virtualIp': virtualIp,
        'subnet': subnet,
        'peers': peers,
        'useP2p': _p2pService != null,
      });

      if (result == true) {
        _isConnected = true;
        _virtualIp = virtualIp;
      } else {
        _error = 'ไม่สามารถเริ่ม VPN ได้';
      }

      return result ?? false;
    } on PlatformException catch (e) {
      _error = e.message ?? 'เกิดข้อผิดพลาดในการเริ่ม VPN';
      _errorCode = e.code;
      return false;
    } on MissingPluginException {
      // Platform channel not implemented yet - simulate connection
      _isConnected = true;
      _virtualIp = virtualIp;
      return true;
    } catch (e) {
      _error = 'เกิดข้อผิดพลาดที่ไม่คาดคิด';
      return false;
    } finally {
      _isStarting = false;
      notifyListeners();
    }
  }

  Future<void> stopVpn() async {
    try {
      await _channel.invokeMethod('stopVpn');
    } on MissingPluginException {
      // Platform channel not implemented yet
    } catch (e) {
      debugPrint('Error stopping VPN: $e');
    } finally {
      _isConnected = false;
      _virtualIp = null;
      notifyListeners();
    }
  }

  Future<String?> getVpnStatus() async {
    try {
      final status = await _channel.invokeMethod<String>('getVpnStatus');
      return status;
    } on MissingPluginException {
      return _isConnected ? 'connected' : 'disconnected';
    } catch (e) {
      return 'unknown';
    }
  }

  void _setSubnet(String virtualIp, String subnet) {
    final ip = _ipToInt(virtualIp);
    int prefix = 24;
    if (subnet.contains('/')) {
      prefix = int.tryParse(subnet.split('/').last) ?? 24;
    } else {
      final mask = _ipToInt(subnet);
      if (mask != null) {
        prefix = 0;
        while (prefix < 32 && (mask & (0x80000000 >> prefix)) != 0) {
          prefix++;
        }
      }
    }
    prefix = prefix.clamp(8, 30);
    _netMask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    _netAddr = (ip ?? 0) & _netMask;
  }

  static int? _ipToInt(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    var v = 0;
    for (final part in parts) {
      final o = int.tryParse(part);
      if (o == null || o < 0 || o > 255) return null;
      v = (v << 8) | o;
    }
    return v;
  }

  /// Handle outgoing packet from TUN interface → send via P2P
  void _handleOutgoingPacket(Uint8List packet) {
    if (_p2pService == null || packet.length < 20) return;

    final dest = (packet[16] << 24) |
        (packet[17] << 16) |
        (packet[18] << 8) |
        packet[19];
    final broadcast = (_netAddr | (~_netMask & 0xFFFFFFFF)) & 0xFFFFFFFF;

    // LAN game discovery uses broadcasts — hand those to every direct peer.
    if (dest == 0xFFFFFFFF || (_netMask != 0 && dest == broadcast)) {
      _p2pService!.broadcastTunPacket(packet);
      return;
    }

    // Extract destination IP from IPv4 header (bytes 16-19)
    final destIp = '${packet[16]}.${packet[17]}.${packet[18]}.${packet[19]}';

    _p2pService!.sendTunPacket(destIp, packet).catchError((e) {
      debugPrint('P2P send error to $destIp: $e');
      return false;
    });
  }

  /// Handle incoming P2P data → inject into TUN
  void _onP2pDataReceived(String virtualIp, Uint8List data) {
    // P2P authenticated the sender's virtual IP: a member may only inject
    // packets from its own address, not pose as another member.
    if (data.length < 20 ||
        '${data[12]}.${data[13]}.${data[14]}.${data[15]}' != virtualIp) {
      return;
    }
    try {
      _channel.invokeMethod('injectPacket', {'data': data});
    } on MissingPluginException {
      // Native TUN not implemented yet
    } catch (e) {
      debugPrint('Error injecting P2P packet: $e');
    }
  }

  // ── Screenshot demo data (lib/dev/shot_harness.dart only) ──
  void debugSetConnected(String virtualIp, String subnet) {
    _isConnected = true;
    _virtualIp = virtualIp;
    _setSubnet(virtualIp, subnet);
    notifyListeners();
  }

  void clearError() {
    _error = null;
    _errorCode = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stopVpn();
    super.dispose();
  }
}
