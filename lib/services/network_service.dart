import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../database/database_helper.dart';
import '../models/member.dart';
import '../models/network.dart';
import 'p2p_service.dart';

class NetworkService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';

  final DatabaseHelper _db = DatabaseHelper();
  P2pService? _p2pService;
  String? _vpnGatewayCountry;

  List<VpnNetwork> _publicNetworks = [];
  List<VpnNetwork> get publicNetworks => _publicNetworks;

  VpnNetwork? _currentNetwork;
  VpnNetwork? get currentNetwork => _currentNetwork;

  List<NetworkMember> _members = [];
  List<NetworkMember> get members => _members;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  Timer? _heartbeatTimer;
  String? _deviceId;
  String? _displayName;
  String? _licenseKey;
  String? _ownVirtualIp;

  /// The virtual IP assigned to this device in the current network
  String? get ownVirtualIp => _ownVirtualIp;

  void configure({required String deviceId, String? displayName, String? licenseKey}) {
    _deviceId = deviceId;
    _displayName = displayName?.isNotEmpty == true
        ? displayName
        : 'Device-${deviceId.length >= 8 ? deviceId.substring(0, 8) : deviceId}';
    _licenseKey = licenseKey;
  }

  /// Attach a P2P service for direct peer connections
  void attachP2p(P2pService p2p) {
    _p2pService = p2p;
    _p2pService!.configure(
      deviceId: _deviceId ?? '',
      licenseKey: _licenseKey ?? '',
    );
  }

  /// Get the attached P2P service
  P2pService? get p2pService => _p2pService;

  /// Set VPN gateway country (called by VpnProxyService when connected)
  void setVpnGateway(String? countryCode) {
    _vpnGatewayCountry = countryCode;
  }

  /// Get the current VPN gateway member in the network (if any)
  NetworkMember? get vpnGatewayMember =>
      _members.where((m) => m.isVpnGateway).firstOrNull;

  Map<String, String> get _headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_deviceId != null) {
      h['X-Device-Id'] = _deviceId!;
    }
    return h;
  }

  Future<void> listNetworks() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/networks'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> networkList =
            data is List ? data : (data['networks'] as List? ?? []);

        _publicNetworks =
            networkList.map((n) => VpnNetwork.fromJson(n)).toList();
      } else {
        _error = 'ไม่สามารถโหลดรายการเครือข่ายได้';
      }
    } catch (e) {
      _error = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> createNetwork({
    required String name,
    String? description,
    bool isPublic = true,
    String? password,
    int? maxMembers,
  }) async {
    if (name.trim().isEmpty) return false;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final body = <String, dynamic>{
        'name': name.trim(),
        'is_public': isPublic,
        'machine_id': _deviceId ?? '',
        'display_name': _displayName ?? 'Owner',
        'license_key': _licenseKey ?? '',
      };

      if (description != null && description.trim().isNotEmpty) {
        body['description'] = description.trim();
      }

      if (password != null && password.isNotEmpty) {
        final hash = sha256.convert(utf8.encode(password));
        body['password'] = hash.toString();
      }

      if (maxMembers != null) {
        body['max_members'] = maxMembers;
      }

      final response = await http
          .post(
            Uri.parse('$_baseUrl/networks'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final network = VpnNetwork.fromJson(
            data['network'] as Map<String, dynamic>? ?? data);

        _currentNetwork = network;

        // Parse own virtual IP from member info
        final memberData = data['member'] as Map<String, dynamic>?;
        if (memberData != null) {
          _ownVirtualIp = memberData['virtual_ip'] as String?;
        }

        String? passwordHash;
        if (password != null && password.isNotEmpty) {
          passwordHash = sha256.convert(utf8.encode(password)).toString();
        }
        await _db.saveNetwork(
          slug: network.slug,
          name: network.name,
          passwordHash: passwordHash,
        );

        _startHeartbeat();
        notifyListeners();
        return true;
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _error = data['error'] as String? ?? data['message'] as String? ?? 'ไม่สามารถสร้างเครือข่ายได้';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> joinNetwork(String slug, {String? password}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final body = <String, dynamic>{
        'slug': slug,
        'machine_id': _deviceId,
        'display_name': _displayName,
        'license_key': _licenseKey ?? '',
      };

      if (password != null && password.isNotEmpty) {
        final hash = sha256.convert(utf8.encode(password));
        body['password'] = hash.toString();
      }

      final response = await http
          .post(
            Uri.parse('$_baseUrl/networks/join'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final network = VpnNetwork.fromJson(
            data['network'] as Map<String, dynamic>? ?? data);

        _currentNetwork = network;

        // Parse own virtual IP from member info
        final memberData = data['member'] as Map<String, dynamic>?;
        if (memberData != null) {
          _ownVirtualIp = memberData['virtual_ip'] as String?;
        }

        String? passwordHash;
        if (password != null && password.isNotEmpty) {
          passwordHash = sha256.convert(utf8.encode(password)).toString();
        }
        await _db.saveNetwork(
          slug: network.slug,
          name: network.name,
          passwordHash: passwordHash,
        );

        _startHeartbeat();
        notifyListeners();
        return true;
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _error = data['message'] as String? ?? data['error'] as String? ?? 'ไม่สามารถเข้าร่วมเครือข่ายได้';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Join network with a pre-hashed password (for auto-rejoin from saved networks)
  Future<bool> joinNetworkRaw(String slug, {String? passwordHash}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final body = <String, dynamic>{
        'slug': slug,
        'machine_id': _deviceId,
        'display_name': _displayName,
        'license_key': _licenseKey ?? '',
      };

      if (passwordHash != null && passwordHash.isNotEmpty) {
        body['password'] = passwordHash;
      }

      final response = await http
          .post(
            Uri.parse('$_baseUrl/networks/join'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final network = VpnNetwork.fromJson(
            data['network'] as Map<String, dynamic>? ?? data);

        _currentNetwork = network;

        final memberData = data['member'] as Map<String, dynamic>?;
        if (memberData != null) {
          _ownVirtualIp = memberData['virtual_ip'] as String?;
        }

        await _db.updateLastConnected(slug);

        _startHeartbeat();
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Auto-rejoin error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    return false;
  }

  Future<bool> leaveNetwork(String slug) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/networks/leave'),
            headers: _headers,
            body: jsonEncode({
              'slug': slug,
              'machine_id': _deviceId,
              'license_key': _licenseKey ?? '',
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        _stopHeartbeat();

        if (_currentNetwork?.slug == slug) {
          _currentNetwork = null;
          _members = [];
          _ownVirtualIp = null;
        }

        await _db.deleteSavedNetwork(slug);
        notifyListeners();
        return true;
      } else {
        _error = 'ไม่สามารถออกจากเครือข่ายได้';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> getMembers(String slug) async {
    try {
      final uri = Uri.parse('$_baseUrl/networks/${Uri.encodeComponent(slug)}/members').replace(
        queryParameters: {
          'machine_id': _deviceId ?? '',
          'license_key': _licenseKey ?? '',
        },
      );
      final response = await http
          .get(
            uri,
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> memberList =
            data is List ? data : (data['members'] as List? ?? []);

        _members =
            memberList.map((m) => NetworkMember.fromJson(m)).toList();

        // Save known devices
        for (final member in _members) {
          if (member.machineId != null) {
            await _db.saveDevice(
              machineId: member.machineId!,
              displayName: member.displayName,
              virtualIp: member.virtualIp,
            );
          }
        }

        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error fetching members: $e');
    }
  }

  Future<bool> deleteNetwork(String slug) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final request = http.Request('DELETE', Uri.parse('$_baseUrl/networks/${Uri.encodeComponent(slug)}'));
      request.headers.addAll(_headers);
      request.body = jsonEncode({'license_key': _licenseKey ?? '', 'machine_id': _deviceId ?? ''});
      final streamed = await request.send().timeout(const Duration(seconds: 15));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode == 200) {
        _stopHeartbeat();

        if (_currentNetwork?.slug == slug) {
          _currentNetwork = null;
          _members = [];
          _ownVirtualIp = null;
        }

        await _db.deleteSavedNetwork(slug);
        notifyListeners();
        return true;
      } else {
        _error = 'ไม่สามารถลบเครือข่ายได้';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _startHeartbeat() async {
    _stopHeartbeat();

    // Start P2P service if attached — await to ensure it's ready before heartbeat
    if (_p2pService != null && _currentNetwork != null) {
      await _p2pService!.start(_currentNetwork!.slug);
    }

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _sendHeartbeat(),
    );
    await _sendHeartbeat();
  }

  Future<void> _stopHeartbeat() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _p2pService?.stop();
  }

  Future<void> _sendHeartbeat() async {
    if (_currentNetwork == null || _deviceId == null) return;

    try {
      final body = <String, dynamic>{
        'slug': _currentNetwork!.slug,
        'machine_id': _deviceId,
        'display_name': _displayName,
        'license_key': _licenseKey ?? '',
      };

      // Include P2P endpoint info if available
      if (_p2pService != null) {
        if (_p2pService!.publicIp != null) {
          body['public_ip'] = _p2pService!.publicIp;
        }
        if (_p2pService!.publicPort != null) {
          body['public_port'] = _p2pService!.publicPort;
        }
      }

      // VPN gateway info — tells other members this host is routing via VPN
      if (_vpnGatewayCountry != null) {
        body['vpn_gateway_country'] = _vpnGatewayCountry;
      }

      final response = await http
          .post(
            Uri.parse('$_baseUrl/heartbeat'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final peers = data['peers'] as List?;
        if (peers != null) {
          try {
            _members =
                peers.map((m) => NetworkMember.fromJson(m as Map<String, dynamic>)).toList();
          } catch (e) {
            debugPrint('Heartbeat peer parse error: $e');
            return;
          }

          // Feed peer list to P2P service for hole punching
          _p2pService?.updatePeers(_members);

          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getSavedNetworks() async {
    return await _db.getSavedNetworks();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void disconnectFromNetwork() {
    _stopHeartbeat();
    _currentNetwork = null;
    _members = [];
    _ownVirtualIp = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopHeartbeat();
    super.dispose();
  }
}
