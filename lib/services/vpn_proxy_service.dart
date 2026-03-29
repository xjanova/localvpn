import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/proxy_server.dart';

enum VpnProxyStatus { disconnected, connecting, connected, disconnecting, error }

class VpnProxyService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const String _prefLastCountry = 'vpn_proxy_last_country';

  String? _deviceId;
  String? _licenseKey;

  late OpenVPN _openvpn;
  VpnProxyStatus _status = VpnProxyStatus.disconnected;
  VpnProxyStatus get status => _status;

  VPNStage? _stage;
  VPNStage? get stage => _stage;

  String? _error;
  String? get error => _error;

  String? _connectedIp;
  String? get connectedIp => _connectedIp;

  String? _connectedCountry;
  String? get connectedCountry => _connectedCountry;

  String? _connectedHostname;
  String? get connectedHostname => _connectedHostname;

  Duration? _duration;
  Duration? get duration => _duration;

  String? _byteIn;
  String? get byteIn => _byteIn;

  String? _byteOut;
  String? get byteOut => _byteOut;

  List<ProxyCountry> _countries = [];
  List<ProxyCountry> get countries => _countries;

  List<ProxyCountry> _lockedCountries = [];
  List<ProxyCountry> get lockedCountries => _lockedCountries;

  bool _isPremium = false;
  bool get isPremium => _isPremium;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  int? _currentPing;
  int? get currentPing => _currentPing;

  String? _lastCountryCode;
  String? get lastCountryCode => _lastCountryCode;

  void configure({required String deviceId, String? licenseKey}) {
    _deviceId = deviceId;
    _licenseKey = licenseKey;

    _openvpn = OpenVPN(
      onVpnStatusChanged: _onStatusChanged,
      onVpnStageChanged: _onStageChanged,
    );
    _openvpn.initialize(
      groupIdentifier: 'group.com.xjanova.localvpn',
      providerBundleIdentifier: 'com.xjanova.localvpn.VPNExtension',
      localizedDescription: 'LocalVPN Proxy',
    );

    _loadLastCountry();
  }

  Future<void> _loadLastCountry() async {
    final prefs = await SharedPreferences.getInstance();
    _lastCountryCode = prefs.getString(_prefLastCountry);
  }

  Future<void> _saveLastCountry(String code) async {
    _lastCountryCode = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLastCountry, code);
  }

  void _onStatusChanged(VpnStatus? vpnStatus) {
    _duration = vpnStatus?.duration != null
        ? _parseDuration(vpnStatus!.duration!)
        : null;
    _byteIn = vpnStatus?.byteIn;
    _byteOut = vpnStatus?.byteOut;
    notifyListeners();
  }

  void _onStageChanged(VPNStage stage, String raw) {
    _stage = stage;
    debugPrint('VPN Proxy stage: $stage ($raw)');

    // Don't override disconnecting state with connected (race condition)
    if (_status == VpnProxyStatus.disconnecting && stage == VPNStage.connected) {
      return;
    }

    switch (stage) {
      case VPNStage.connected:
        _status = VpnProxyStatus.connected;
        _error = null;
        break;
      case VPNStage.disconnected:
        _status = VpnProxyStatus.disconnected;
        _connectedCountry = null;
        _connectedHostname = null;
        break;
      case VPNStage.error:
        _status = VpnProxyStatus.error;
        _error = raw.isNotEmpty ? raw : 'VPN connection failed';
        break;
      case VPNStage.denied:
        _status = VpnProxyStatus.error;
        _error = 'VPN permission denied';
        break;
      default:
        _status = VpnProxyStatus.connecting;
    }

    notifyListeners();
  }

  Duration? _parseDuration(String durationStr) {
    try {
      final parts = durationStr.split(':');
      if (parts.length == 3) {
        return Duration(
          hours: int.parse(parts[0]),
          minutes: int.parse(parts[1]),
          seconds: int.parse(parts[2]),
        );
      }
    } catch (_) {}
    return null;
  }

  /// Fetch server list from backend
  Future<void> fetchServers() async {
    if (_deviceId == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/proxy-servers').replace(
        queryParameters: {
          'machine_id': _deviceId!,
          if (_licenseKey != null) 'license_key': _licenseKey!,
        },
      );

      final response = await http.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        if (data['success'] == true) {
          _isPremium = data['is_premium'] as bool? ?? false;

          _countries = (data['countries'] as List<dynamic>?)
                  ?.map(
                      (c) => ProxyCountry.fromJson(c as Map<String, dynamic>))
                  .toList() ??
              [];

          _lockedCountries = (data['locked_countries'] as List<dynamic>?)
                  ?.map(
                      (c) => ProxyCountry.fromJson(c as Map<String, dynamic>))
                  .toList() ??
              [];
        } else {
          _error = data['error'] as String? ?? 'Failed to fetch servers';
        }
      } else {
        _error = 'Server error (${response.statusCode})';
      }
    } catch (e) {
      _error = 'ไม่สามารถโหลดรายการ VPN servers ได้';
      debugPrint('VpnProxyService.fetchServers error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Connect to the best server in a country
  Future<bool> connectToCountry(ProxyCountry country) async {
    final server = country.bestServer;
    if (server == null) {
      _error = 'ไม่มี server สำหรับประเทศนี้';
      notifyListeners();
      return false;
    }
    return connect(server);
  }

  /// Connect to a specific server
  Future<bool> connect(ProxyServer server) async {
    if (_status == VpnProxyStatus.connecting) return false;

    _status = VpnProxyStatus.connecting;
    _error = null;
    _connectedCountry = server.countryCode;
    _connectedHostname = server.hostname;
    notifyListeners();

    try {
      // Decode base64 OpenVPN config (strip whitespace/newlines from base64)
      final cleanBase64 = server.openvpnConfig.replaceAll(RegExp(r'\s'), '');
      final configData = utf8.decode(base64Decode(cleanBase64));

      _openvpn.connect(
        configData,
        server.hostname,
        username: '',
        password: '',
        certIsRequired: false,
      );

      await _saveLastCountry(server.countryCode);
      return true;
    } catch (e) {
      _status = VpnProxyStatus.error;
      _error = 'ไม่สามารถเชื่อมต่อ VPN ได้: $e';
      _connectedCountry = null;
      _connectedHostname = null;
      notifyListeners();
      return false;
    }
  }

  /// Disconnect from VPN
  Future<void> disconnect() async {
    _status = VpnProxyStatus.disconnecting;
    notifyListeners();

    _openvpn.disconnect();

    // Wait briefly for the stage callback
    await Future.delayed(const Duration(milliseconds: 500));

    if (_status != VpnProxyStatus.disconnected) {
      _status = VpnProxyStatus.disconnected;
      _connectedCountry = null;
      _connectedHostname = null;
      notifyListeners();
    }
  }

  /// Find a server by hostname across all countries (for "follow gateway")
  ProxyServer? findServerByHostname(String hostname) {
    for (final country in _countries) {
      for (final server in country.servers) {
        if (server.hostname == hostname) return server;
      }
    }
    return null;
  }

  /// Find a country by code
  ProxyCountry? findCountryByCode(String code) {
    final upper = code.toUpperCase();
    for (final country in _countries) {
      if (country.countryCode.toUpperCase() == upper) return country;
    }
    return null;
  }

  /// Ping a server to measure latency
  Future<int?> pingServer(ProxyServer server) async {
    try {
      final sw = Stopwatch()..start();
      final socket = await Socket.connect(
        server.ip,
        443,
        timeout: const Duration(seconds: 3),
      );
      sw.stop();
      socket.destroy();
      final ms = sw.elapsedMilliseconds;
      server.measuredPing = ms;
      return ms;
    } catch (_) {
      return null;
    }
  }

  /// Ping the best server for each country (background, parallel)
  Future<void> pingAllCountries() async {
    final futures = <Future>[];
    for (final country in _countries) {
      final server = country.bestServer;
      if (server != null) {
        futures.add(pingServer(server).then((ms) {
          if (ms != null && _status == VpnProxyStatus.connected &&
              _connectedCountry == country.countryCode) {
            _currentPing = ms;
          }
        }));
      }
    }
    await Future.wait(futures);
    notifyListeners();
  }

  /// Continuously ping connected server
  Future<void> pingConnected() async {
    if (_connectedCountry == null) return;
    final country = _countries
        .where((c) => c.countryCode == _connectedCountry)
        .firstOrNull;
    if (country?.bestServer == null) return;

    final ms = await pingServer(country!.bestServer!);
    _currentPing = ms;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_status == VpnProxyStatus.connected ||
        _status == VpnProxyStatus.connecting) {
      _openvpn.disconnect();
    }
    super.dispose();
  }
}
