import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  VpnService() {
    _channel.setMethodCallHandler(_handleMethodCall);
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
