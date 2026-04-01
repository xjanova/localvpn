import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';

import '../models/proxy_server.dart';

enum VpnProxyStatus { disconnected, connecting, connected, disconnecting, error }

class VpnProxyService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const String _prefLastCountry = 'vpn_proxy_last_country';
  static const String _prefPrivateKey = 'wg_private_key';
  static const String _prefPublicKey = 'wg_public_key';
  static const String _prefCachedServers = 'wg_cached_servers';
  static const String _prefCachedConfig = 'wg_cached_config';
  static const String _prefCachedServerName = 'wg_cached_server_name';
  static const String _prefCachedCountryCode = 'wg_cached_country_code';
  static const String _prefCachedCountryName = 'wg_cached_country_name';

  String? _deviceId;
  String? _licenseKey;
  bool _disposed = false;

  late WireGuardFlutterInterface _wireguard;
  StreamSubscription<VpnStage>? _stageSubscription;
  StreamSubscription<Map<String, dynamic>>? _trafficSubscription;

  VpnProxyStatus _status = VpnProxyStatus.disconnected;
  VpnProxyStatus get status => _status;

  String? _error;
  String? get error => _error;

  String? _connectedCountry;
  String? get connectedCountry => _connectedCountry;

  String? _connectedServerName;
  String? get connectedHostname => _connectedServerName;

  String? _connectedIp;
  String? get connectedIp => _connectedIp;

  Duration? _duration;
  Duration? get duration => _duration;

  String? _byteIn;
  String? get byteIn => _byteIn;

  String? _byteOut;
  String? get byteOut => _byteOut;

  List<ServerCountry> _countries = [];
  List<ServerCountry> get countries => _countries;

  List<ServerCountry> _lockedCountries = [];
  List<ServerCountry> get lockedCountries => _lockedCountries;

  bool _isPremium = false;
  bool get isPremium => _isPremium;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  int? _currentPing;
  int? get currentPing => _currentPing;

  String? _lastCountryCode;
  String? get lastCountryCode => _lastCountryCode;

  /// WireGuard key pair
  String? _privateKey;
  String? _publicKey;

  /// Cached WireGuard config parts for reconnection (no private key)
  Map<String, dynamic>? _cachedConfigParts;

  /// Current server index for fallback retry within a country
  int _currentServerIndex = 0;

  /// Total attempts made across all rounds (for cycle limit)
  int _totalAttempts = 0;

  /// The country we're trying to connect to (for fallback retry)
  ServerCountry? _connectingCountry;

  /// Connection timeout timer
  Timer? _connectionTimer;

  /// Max rounds to cycle through all servers before giving up
  static const int _maxRounds = 2;

  /// Connection timeout duration
  static const Duration _connectionTimeout = Duration(seconds: 20);

  void configure({required String deviceId, String? licenseKey}) {
    _deviceId = deviceId;
    _licenseKey = licenseKey;

    _wireguard = WireGuardFlutter.instance;
    _wireguard.initialize(
      interfaceName: 'wg_localvpn',
      vpnName: 'LocalVPN Proxy',
    );

    _stageSubscription = _wireguard.vpnStageSnapshot.listen(_onStageChanged);
    _trafficSubscription = _wireguard.trafficSnapshot.listen(_onTrafficChanged);

    _loadKeys();
    _loadLastCountry();
    _loadCachedServers();
  }

  // ─── Key Management ────────────────────────────────────────────────

  Future<void> _loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    _privateKey = prefs.getString(_prefPrivateKey);
    _publicKey = prefs.getString(_prefPublicKey);

    if (_privateKey == null || _publicKey == null) {
      await _generateKeyPair();
    }
  }

  /// Generate a WireGuard Curve25519 key pair.
  /// Private key: 32 random bytes with clamping, base64 encoded.
  /// Public key: derived via Curve25519 scalar multiplication, base64 encoded.
  Future<void> _generateKeyPair() async {
    final random = Random.secure();
    final privateBytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      privateBytes[i] = random.nextInt(256);
    }

    // Curve25519 clamping
    privateBytes[0] &= 248;
    privateBytes[31] &= 127;
    privateBytes[31] |= 64;

    _privateKey = base64Encode(privateBytes);

    // Compute public key via Curve25519 scalar multiplication with basepoint
    final publicBytes = _curve25519ScalarMultBase(privateBytes);
    _publicKey = base64Encode(publicBytes);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefPrivateKey, _privateKey!);
    await prefs.setString(_prefPublicKey, _publicKey!);
  }

  /// Curve25519 scalar multiplication with the standard basepoint (9).
  /// Implements the Montgomery ladder algorithm for X25519.
  Uint8List _curve25519ScalarMultBase(Uint8List scalar) {
    // Field prime: 2^255 - 19
    final p = BigInt.two.pow(255) - BigInt.from(19);

    BigInt fieldAdd(BigInt a, BigInt b) => (a + b) % p;
    BigInt fieldSub(BigInt a, BigInt b) => (a - b + p) % p;
    BigInt fieldMul(BigInt a, BigInt b) => (a * b) % p;

    BigInt fieldInv(BigInt a) {
      // Fermat's little theorem: a^(p-2) mod p
      return a.modPow(p - BigInt.two, p);
    }

    // Basepoint u = 9
    BigInt u = BigInt.from(9);

    // Montgomery ladder
    BigInt x1 = u;
    BigInt x2 = BigInt.one;
    BigInt z2 = BigInt.zero;
    BigInt x3 = u;
    BigInt z3 = BigInt.one;
    int swap = 0;

    // Decode scalar (little-endian)
    final k = Uint8List.fromList(scalar);

    for (int t = 254; t >= 0; t--) {
      final kt = (k[t >> 3] >> (t & 7)) & 1;
      swap ^= kt;
      // Conditional swap
      if (swap == 1) {
        final tmpX = x2;
        x2 = x3;
        x3 = tmpX;
        final tmpZ = z2;
        z2 = z3;
        z3 = tmpZ;
      }
      swap = kt;

      final a24 = BigInt.from(121666);

      final A = fieldAdd(x2, z2);
      final AA = fieldMul(A, A);
      final B = fieldSub(x2, z2);
      final BB = fieldMul(B, B);
      final E = fieldSub(AA, BB);
      final C = fieldAdd(x3, z3);
      final D = fieldSub(x3, z3);
      final DA = fieldMul(D, A);
      final CB = fieldMul(C, B);
      x3 = fieldMul(fieldAdd(DA, CB), fieldAdd(DA, CB));
      z3 = fieldMul(x1, fieldMul(fieldSub(DA, CB), fieldSub(DA, CB)));
      x2 = fieldMul(AA, BB);
      z2 = fieldMul(E, fieldAdd(AA, fieldMul(a24, E)));
    }

    if (swap == 1) {
      final tmpX = x2;
      x2 = x3;
      x3 = tmpX;
      final tmpZ = z2;
      z2 = z3;
      z3 = tmpZ;
    }

    final result = fieldMul(x2, fieldInv(z2));

    // Encode result as 32 bytes little-endian
    final out = Uint8List(32);
    var r = result;
    for (int i = 0; i < 32; i++) {
      out[i] = (r & BigInt.from(0xFF)).toInt();
      r >>= 8;
    }
    return out;
  }

  // ─── Caching ───────────────────────────────────────────────────────

  Future<void> _loadLastCountry() async {
    final prefs = await SharedPreferences.getInstance();
    _lastCountryCode = prefs.getString(_prefLastCountry);
  }

  Future<void> _saveLastCountry(String code) async {
    _lastCountryCode = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLastCountry, code);
  }

  Future<void> _loadCachedServers() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_prefCachedServers);
    if (cached != null) {
      try {
        final data = jsonDecode(cached) as Map<String, dynamic>;
        _countries = (data['countries'] as List<dynamic>?)
                ?.map((c) => ServerCountry.fromJson(c as Map<String, dynamic>))
                .toList() ??
            [];
        _lockedCountries = (data['locked_countries'] as List<dynamic>?)
                ?.map((c) => ServerCountry.fromJson(c as Map<String, dynamic>))
                .toList() ??
            [];
        if (_countries.isNotEmpty) {
          notifyListeners();
        }
      } catch (_) {}
    }

    // Load cached config parts (no private key stored)
    final cachedParts = prefs.getString(_prefCachedConfig);
    if (cachedParts != null) {
      try {
        _cachedConfigParts =
            jsonDecode(cachedParts) as Map<String, dynamic>;
      } catch (_) {}
    }
  }

  Future<void> _cacheServers() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'countries': _countries.map((c) => c.toJson()).toList(),
      'locked_countries': _lockedCountries.map((c) => c.toJson()).toList(),
    };
    await prefs.setString(_prefCachedServers, jsonEncode(data));
  }

  /// Cache config parts (without private key) for reconnection
  Future<void> _cacheConfig(Map<String, dynamic> configParts,
      String serverName, String countryCode, String countryName) async {
    _cachedConfigParts = configParts;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCachedConfig, jsonEncode(configParts));
    await prefs.setString(_prefCachedServerName, serverName);
    await prefs.setString(_prefCachedCountryCode, countryCode);
    await prefs.setString(_prefCachedCountryName, countryName);
  }

  // ─── VPN Stage & Traffic Callbacks ─────────────────────────────────

  void _onStageChanged(VpnStage stage) {
    debugPrint('WireGuard stage: ${stage.name} [status=$_status, '
        'connectingCountry=${_connectingCountry?.countryCode}]');

    // Don't override disconnecting state with connected (race condition)
    if (_status == VpnProxyStatus.disconnecting && stage == VpnStage.connected) {
      return;
    }

    switch (stage) {
      case VpnStage.connected:
        _connectionTimer?.cancel();
        _connectingCountry = null;
        _status = VpnProxyStatus.connected;
        _error = null;
        break;
      case VpnStage.disconnected:
        // Ignore stale disconnect callbacks during connecting
        if (_status == VpnProxyStatus.connecting) {
          debugPrint('WireGuard ignoring stale disconnect callback (already connecting)');
          break;
        }
        _connectionTimer?.cancel();
        _status = VpnProxyStatus.disconnected;
        _clearConnectionState();
        _connectingCountry = null;
        break;
      case VpnStage.denied:
        _connectionTimer?.cancel();
        _status = VpnProxyStatus.error;
        _error = 'VPN permission denied';
        _clearConnectionState();
        _connectingCountry = null;
        break;
      case VpnStage.noConnection:
        // If we're still connecting and have more servers, try next
        if (_status == VpnProxyStatus.connecting && _connectingCountry != null) {
          _connectionTimer?.cancel();
          debugPrint('WireGuard noConnection — trying next server...');
          _tryNextServer();
          return;
        }
        _connectionTimer?.cancel();
        _status = VpnProxyStatus.error;
        _error = 'VPN connection failed';
        _clearConnectionState();
        _connectingCountry = null;
        break;
      case VpnStage.connecting:
      case VpnStage.waitingConnection:
      case VpnStage.authenticating:
      case VpnStage.reconnect:
      case VpnStage.preparing:
        _status = VpnProxyStatus.connecting;
        break;
      case VpnStage.disconnecting:
      case VpnStage.exiting:
        _status = VpnProxyStatus.disconnecting;
        break;
    }

    notifyListeners();
  }

  void _onTrafficChanged(Map<String, dynamic> data) {
    final dl = data['totalDownload'];
    final ul = data['totalUpload'];
    _byteIn = dl != null ? _formatBytes(double.tryParse(dl.toString()) ?? 0) : null;
    _byteOut = ul != null ? _formatBytes(double.tryParse(ul.toString()) ?? 0) : null;

    final dur = data['duration']?.toString();
    if (dur != null) {
      _duration = _parseDuration(dur);
    }

    notifyListeners();
  }

  String _formatBytes(double bytes) {
    if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Clear all connection-related state fields.
  void _clearConnectionState() {
    _connectedCountry = null;
    _connectedServerName = null;
    _connectedIp = null;
    _currentPing = null;
    _duration = null;
    _byteIn = null;
    _byteOut = null;
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

  // ─── Fetch Servers ─────────────────────────────────────────────────

  /// Fetch WireGuard server list from backend
  Future<void> fetchServers() async {
    if (_deviceId == null) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/wireguard/servers').replace(
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

          final serverList = (data['servers'] as List<dynamic>?)
                  ?.map((s) =>
                      WireguardServer.fromJson(s as Map<String, dynamic>))
                  .toList() ??
              [];

          final lockedServerList = (data['locked_servers'] as List<dynamic>?)
                  ?.map((s) =>
                      WireguardServer.fromJson(s as Map<String, dynamic>))
                  .toList() ??
              [];

          // Group servers by country
          _countries = _groupByCountry(serverList);
          _lockedCountries = _groupByCountry(lockedServerList, locked: true);

          // Cache for offline use
          await _cacheServers();
        } else {
          _error = data['message'] as String? ??
              'Failed to load server list';
        }
      } else {
        _error = 'Server error (${response.statusCode})';
      }
    } catch (e) {
      debugPrint('VpnProxyService.fetchServers error: $e');
      // If we have cached servers, use them silently
      if (_countries.isEmpty) {
        _error = 'Could not load VPN servers';
      }
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Group a flat list of servers into country groups
  List<ServerCountry> _groupByCountry(List<WireguardServer> servers,
      {bool locked = false}) {
    final grouped = <String, List<WireguardServer>>{};
    for (final s in servers) {
      grouped.putIfAbsent(s.countryCode, () => []).add(s);
    }

    return grouped.entries.map((e) {
      // Sort by load ascending (lowest load = best)
      final sorted = e.value..sort((a, b) => a.load.compareTo(b.load));
      return ServerCountry(
        countryCode: e.key,
        countryName: sorted.first.countryName,
        servers: sorted,
        locked: locked,
      );
    }).toList()
      ..sort((a, b) => a.countryName.compareTo(b.countryName));
  }

  // ─── Connection ────────────────────────────────────────────────────

  /// Info about current connection attempt (for UI display)
  String? get connectingServerInfo {
    final country = _connectingCountry;
    if (country == null || _status != VpnProxyStatus.connecting) return null;
    final round = (_totalAttempts ~/ country.servers.length) + 1;
    final serverNum = _currentServerIndex + 1;
    final total = country.servers.length;
    if (round > 1) {
      return 'server $serverNum/$total (round $round)';
    }
    return 'server $serverNum/$total';
  }

  /// Connect to the best server in a country (with auto-fallback)
  Future<bool> connectToCountry(ServerCountry country) async {
    if (country.servers.isEmpty) {
      _error = 'No servers available for this country';
      notifyListeners();
      return false;
    }
    _connectingCountry = country;
    _currentServerIndex = 0;
    _totalAttempts = 0;
    return _connectToServerAt(country, 0);
  }

  /// Switch to a different country
  Future<void> switchToCountry(ServerCountry country) async {
    if (country.servers.isEmpty) {
      _error = 'No servers available for this country';
      notifyListeners();
      return;
    }

    if (_status == VpnProxyStatus.connected ||
        _status == VpnProxyStatus.connecting) {
      await disconnect();
    }
    await connectToCountry(country);
  }

  /// Connect to server at given index within the country
  Future<bool> _connectToServerAt(ServerCountry country, int index,
      {bool isRetry = false}) async {
    _currentServerIndex = index % country.servers.length;
    _totalAttempts++;

    // Check if we've exhausted all rounds
    final maxAttempts = country.servers.length * _maxRounds;
    if (_totalAttempts > maxAttempts) {
      _status = VpnProxyStatus.error;
      _error =
          'Tried ${country.servers.length} servers across $_maxRounds rounds, could not connect';
      _clearConnectionState();
      _connectingCountry = null;
      notifyListeners();
      return false;
    }

    return connect(country.servers[_currentServerIndex], isRetry: isRetry);
  }

  /// Try the next server in the current country
  void _tryNextServer() {
    final country = _connectingCountry;
    if (country == null || country.servers.isEmpty) return;

    final maxAttempts = country.servers.length * _maxRounds;
    if (_totalAttempts >= maxAttempts) {
      _status = VpnProxyStatus.error;
      _error =
          'Tried ${country.servers.length} servers across $_maxRounds rounds, could not connect';
      _clearConnectionState();
      _connectingCountry = null;
      notifyListeners();
      _wireguard.stopVpn();
      return;
    }

    final nextIndex = (_currentServerIndex + 1) % country.servers.length;
    _currentServerIndex = nextIndex;
    debugPrint(
        'WireGuard retry — server ${nextIndex + 1}/${country.servers.length}');

    // Disconnect first, then reconnect
    _wireguard.stopVpn().then((_) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_connectingCountry != null && !_disposed) {
          _connectToServerAt(country, nextIndex, isRetry: true);
        }
      });
    });
  }

  /// Connect to a specific server.
  Future<bool> connect(WireguardServer server, {bool isRetry = false}) async {
    if (!isRetry && _status == VpnProxyStatus.connecting) return false;
    if (_privateKey == null || _publicKey == null) {
      await _loadKeys();
    }

    _connectionTimer?.cancel();

    _status = VpnProxyStatus.connecting;
    _error = null;
    _connectedCountry = server.countryCode;
    _connectedServerName = server.name;
    notifyListeners();

    try {
      // Register with backend to get WireGuard config
      final response = await http.post(
        Uri.parse('$_baseUrl/wireguard/register'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'machine_id': _deviceId,
          'public_key': _publicKey,
          if (_licenseKey != null) 'license_key': _licenseKey,
          'country_code': server.countryCode,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('WireGuard register failed: ${response.statusCode} ${response.body}');
        _tryNextServer();
        return false;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['success'] != true) {
        debugPrint('WireGuard register error: ${data['message']}');
        _tryNextServer();
        return false;
      }

      final config = data['config'] as Map<String, dynamic>;
      final iface = config['interface'] as Map<String, dynamic>;
      final peer = config['peer'] as Map<String, dynamic>;

      final address = iface['address'] as String;
      final dns = iface['dns'] as String;
      final serverPubKey = peer['public_key'] as String;
      final endpoint = peer['endpoint'] as String;
      final allowedIPs = peer['allowed_ips'] as String;
      final keepalive = peer['persistent_keepalive'] as int? ?? 25;

      // Build WireGuard config string (private key added in-memory only)
      final configParts = {
        'address': address,
        'dns': dns,
        'server_pub_key': serverPubKey,
        'endpoint': endpoint,
        'allowed_ips': allowedIPs,
        'keepalive': keepalive,
      };
      final wgConfig = _buildWgConfig(configParts);

      // Extract server IP from endpoint for ping
      _connectedIp = endpoint.split(':').first;

      // Cache config parts (without private key) for reconnection
      final serverInfo = data['server'] as Map<String, dynamic>?;
      final serverName = serverInfo?['name'] as String? ?? server.name;
      final countryCode =
          serverInfo?['country_code'] as String? ?? server.countryCode;
      final countryName =
          serverInfo?['country_name'] as String? ?? server.countryName;
      await _cacheConfig(configParts, serverName, countryCode, countryName);

      debugPrint(
          'WireGuard connect: $serverName | $endpoint | $address');

      await _wireguard.startVpn(
        serverAddress: endpoint,
        wgQuickConfig: wgConfig,
        providerBundleIdentifier: 'com.xjanova.localvpn.WGExtension',
      );

      // Start connection timeout
      _connectionTimer = Timer(_connectionTimeout, () {
        if (_status == VpnProxyStatus.connecting) {
          debugPrint('WireGuard connection timeout for ${server.name}');
          _tryNextServer();
        }
      });

      await _saveLastCountry(server.countryCode);
      return true;
    } on TimeoutException {
      debugPrint('WireGuard register timeout for ${server.name}');
      _tryNextServer();
      return false;
    } catch (e) {
      debugPrint('WireGuard connect error: $e');
      // If backend is unreachable, try cached config
      if (_cachedConfigParts != null && !isRetry) {
        return _connectWithCachedConfig();
      }
      _connectionTimer?.cancel();
      _status = VpnProxyStatus.error;
      _error = 'Could not connect to VPN. Please try again.';
      _clearConnectionState();
      _connectingCountry = null;
      notifyListeners();
      return false;
    }
  }

  /// Build WireGuard config string from parts + private key
  String _buildWgConfig(Map<String, dynamic> parts) {
    return '[Interface]\n'
        'PrivateKey = $_privateKey\n'
        'Address = ${parts['address']}\n'
        'DNS = ${parts['dns']}\n'
        '\n'
        '[Peer]\n'
        'PublicKey = ${parts['server_pub_key']}\n'
        'Endpoint = ${parts['endpoint']}\n'
        'AllowedIPs = ${parts['allowed_ips']}\n'
        'PersistentKeepalive = ${parts['keepalive'] ?? 25}\n';
  }

  /// Reconnect using cached config parts (when backend is unreachable)
  Future<bool> _connectWithCachedConfig() async {
    if (_cachedConfigParts == null || _privateKey == null) return false;

    debugPrint('WireGuard reconnecting with cached config');

    final prefs = await SharedPreferences.getInstance();
    final serverName = prefs.getString(_prefCachedServerName) ?? 'cached';
    final countryCode = prefs.getString(_prefCachedCountryCode) ?? '';

    _connectedCountry = countryCode;
    _connectedServerName = serverName;

    final endpoint = _cachedConfigParts!['endpoint'] as String? ?? '';

    if (endpoint.isEmpty) {
      _status = VpnProxyStatus.error;
      _error = 'Cached config is invalid';
      _clearConnectionState();
      notifyListeners();
      return false;
    }

    _connectedIp = endpoint.split(':').first;
    final wgConfig = _buildWgConfig(_cachedConfigParts!);

    try {
      await _wireguard.startVpn(
        serverAddress: endpoint,
        wgQuickConfig: wgConfig,
        providerBundleIdentifier: 'com.xjanova.localvpn.WGExtension',
      );

      _connectionTimer = Timer(_connectionTimeout, () {
        if (_status == VpnProxyStatus.connecting) {
          _status = VpnProxyStatus.error;
          _error = 'Connection timeout (cached config)';
          _clearConnectionState();
          _connectingCountry = null;
          notifyListeners();
          _wireguard.stopVpn();
        }
      });

      return true;
    } catch (e) {
      _status = VpnProxyStatus.error;
      _error = 'Could not reconnect to VPN. Please try again.';
      _clearConnectionState();
      notifyListeners();
      return false;
    }
  }

  /// Disconnect from VPN
  Future<void> disconnect() async {
    _connectionTimer?.cancel();
    _connectingCountry = null;
    _status = VpnProxyStatus.disconnecting;
    notifyListeners();

    try {
      // Notify backend
      if (_deviceId != null) {
        http
            .post(
              Uri.parse('$_baseUrl/wireguard/disconnect'),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({'machine_id': _deviceId}),
            )
            .timeout(const Duration(seconds: 5))
            .catchError((_) => http.Response('', 200)); // Ignore errors
      }

      await _wireguard.stopVpn();
    } catch (e) {
      debugPrint('WireGuard disconnect error: $e');
    }

    // Wait briefly for the stage callback
    await Future.delayed(const Duration(milliseconds: 500));

    if (_status == VpnProxyStatus.disconnecting) {
      _status = VpnProxyStatus.disconnected;
      _clearConnectionState();
      notifyListeners();
    }
  }

  // ─── Server Lookup ─────────────────────────────────────────────────

  /// Find a server by name across all countries
  WireguardServer? findServerByHostname(String hostname) {
    for (final country in _countries) {
      for (final server in country.servers) {
        if (server.name == hostname) return server;
      }
    }
    return null;
  }

  /// Find a country by code
  ServerCountry? findCountryByCode(String code) {
    final upper = code.toUpperCase();
    for (final country in _countries) {
      if (country.countryCode.toUpperCase() == upper) return country;
    }
    return null;
  }

  // ─── Ping ──────────────────────────────────────────────────────────

  /// Ping a server to measure latency (ICMP-like via UDP)
  Future<int?> pingServer(WireguardServer server) async {
    try {
      final host = server.endpoint.split(':').first;
      final sw = Stopwatch()..start();
      // Use InternetAddress.lookup as a proxy for latency (DNS/reachability)
      await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 3));
      sw.stop();
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
          if (ms != null &&
              _status == VpnProxyStatus.connected &&
              _connectedCountry == country.countryCode) {
            _currentPing = ms;
          }
        }));
      }
    }
    await Future.wait(futures);
    notifyListeners();
  }

  /// Continuously ping the actually connected server
  Future<void> pingConnected() async {
    if (_connectedServerName == null || _connectedCountry == null) return;

    WireguardServer? server = findServerByHostname(_connectedServerName!);
    if (server == null) {
      final country = _countries
          .where((c) => c.countryCode == _connectedCountry)
          .firstOrNull;
      server = country?.bestServer;
    }
    if (server == null) return;

    final ms = await pingServer(server);
    _currentPing = ms;
    notifyListeners();
  }

  // ─── Utility ───────────────────────────────────────────────────────

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionTimer?.cancel();
    _connectionTimer = null;
    _stageSubscription?.cancel();
    _trafficSubscription?.cancel();
    _connectingCountry = null;
    if (_status == VpnProxyStatus.connected ||
        _status == VpnProxyStatus.connecting) {
      _wireguard.stopVpn();
    }
    super.dispose();
  }
}
