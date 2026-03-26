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
    }
  }

  Future<bool> startVpn({
    required String virtualIp,
    required String subnet,
    required List<Map<String, String>> peers,
  }) async {
    _isStarting = true;
    _error = null;
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

  /// Handle outgoing packet from TUN interface → send via P2P
  void _handleOutgoingPacket(Uint8List packet) {
    if (_p2pService == null || packet.length < 20) return;

    // Extract destination IP from IPv4 header (bytes 16-19)
    final destIp = '${packet[16]}.${packet[17]}.${packet[18]}.${packet[19]}';

    _p2pService!.sendToPeer(destIp, packet);
  }

  /// Handle incoming P2P data → inject into TUN
  void _onP2pDataReceived(String virtualIp, Uint8List data) {
    try {
      _channel.invokeMethod('injectPacket', {'data': data});
    } on MissingPluginException {
      // Native TUN not implemented yet
    } catch (e) {
      debugPrint('Error injecting P2P packet: $e');
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stopVpn();
    super.dispose();
  }
}
