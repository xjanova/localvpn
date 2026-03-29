import 'dart:async';
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

  /// Pending reconnect target — set when switching servers to avoid
  /// the disconnected-stage callback clearing state mid-reconnect.
  ProxyServer? _pendingReconnect;

  /// Connection timeout timer — auto-disconnects and tries next server
  /// if connection is not established within the timeout period.
  Timer? _connectionTimer;

  /// Current server index for fallback retry within a country
  int _currentServerIndex = 0;

  /// Total attempts made across all rounds (for cycle limit)
  int _totalAttempts = 0;

  /// The country we're trying to connect to (for fallback retry)
  ProxyCountry? _connectingCountry;

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
        _connectionTimer?.cancel();
        _connectingCountry = null;
        _status = VpnProxyStatus.connected;
        _error = null;
        break;
      case VPNStage.disconnected:
        _connectionTimer?.cancel();
        // If a reconnect is pending (server switch or auto-retry), auto-connect
        // instead of clearing state. This prevents the race where disconnect's
        // callback fires before the retry/switch can start.
        if (_pendingReconnect != null) {
          final server = _pendingReconnect!;
          _pendingReconnect = null;
          // If this is an auto-retry (same country), count the attempt
          if (_connectingCountry != null) {
            _totalAttempts++;
          }
          connect(server, isRetry: true);
          return; // don't clear state or notify — connect() handles it
        }
        _status = VpnProxyStatus.disconnected;
        _clearConnectionState();
        _connectingCountry = null;
        break;
      case VPNStage.error:
        // If we're still in connecting phase and have more servers, try next
        if (_status == VpnProxyStatus.connecting && _connectingCountry != null) {
          _connectionTimer?.cancel();
          debugPrint('VPN error on server — trying next...');
          _tryNextServer();
          return;
        }
        _connectionTimer?.cancel();
        _status = VpnProxyStatus.error;
        _error = raw.isNotEmpty ? raw : 'VPN connection failed';
        _clearConnectionState();
        _connectingCountry = null;
        break;
      case VPNStage.denied:
        _connectionTimer?.cancel();
        _status = VpnProxyStatus.error;
        _error = 'VPN permission denied';
        _clearConnectionState();
        _connectingCountry = null;
        break;
      default:
        _status = VpnProxyStatus.connecting;
    }

    notifyListeners();
  }

  /// Clear all connection-related state fields.
  void _clearConnectionState() {
    _connectedCountry = null;
    _connectedHostname = null;
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

  /// Fetch server list from backend, with client-side VPN Gate fallback
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
          // Backend returned error (e.g. 503 VPN Gate blocked) — try client-side
          await _fetchVpnGateDirect();
        }
      } else {
        // Server error — try client-side fallback
        await _fetchVpnGateDirect();
      }
    } catch (e) {
      // Network error — try client-side fallback
      debugPrint('VpnProxyService.fetchServers error: $e');
      await _fetchVpnGateDirect();
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Direct client-side fetch from VPN Gate API as fallback
  Future<void> _fetchVpnGateDirect() async {
    debugPrint('Trying client-side VPN Gate fetch...');
    const apis = [
      'https://www.vpngate.net/api/iphone/',
    ];

    String? csv;
    for (final apiUrl in apis) {
      try {
        final resp = await http.get(
          Uri.parse(apiUrl),
          headers: {'User-Agent': 'Mozilla/5.0'},
        ).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200 && resp.body.length > 100) {
          csv = resp.body;
          break;
        }
      } catch (_) {
        continue;
      }
    }

    if (csv == null) {
      _error = 'ไม่สามารถโหลดรายการ VPN servers ได้';
      return;
    }

    // Parse VPN Gate CSV
    final lines = csv.split('\n');
    final servers = <ProxyServer>[];
    bool headerSkipped = false;

    // Free countries only for non-premium
    const freeCountries = ['TH', 'JP', 'US', 'KR', 'SG', 'IN', 'GB', 'DE', 'AU', 'CA'];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('*')) continue;
      if (!headerSkipped) {
        headerSkipped = true;
        continue;
      }

      final fields = _parseCsvLine(trimmed);
      if (fields.length < 15) continue;

      final openvpnConfig = fields[14];
      if (openvpnConfig.isEmpty) continue;

      final speed = int.tryParse(fields[4]) ?? 0;
      if (speed <= 0) continue;

      final countryCode = (fields[6]).toUpperCase();

      servers.add(ProxyServer(
        hostname: fields[0],
        ip: fields[1],
        score: int.tryParse(fields[2]) ?? 0,
        ping: int.tryParse(fields[3]) ?? 0,
        speed: speed,
        countryName: fields[5],
        countryCode: countryCode,
        sessions: int.tryParse(fields[7]) ?? 0,
        uptime: int.tryParse(fields[8]) ?? 0,
        openvpnConfig: openvpnConfig,
      ));
    }

    if (servers.isEmpty) {
      _error = 'ไม่พบ VPN servers';
      return;
    }

    // Group by country
    final grouped = <String, List<ProxyServer>>{};
    final allCountryCodes = <String>{};

    for (final s in servers) {
      allCountryCodes.add(s.countryCode);
      if (!_isPremium && !freeCountries.contains(s.countryCode)) continue;
      grouped.putIfAbsent(s.countryCode, () => []).add(s);
    }

    // Sort each group by score descending (consistent with backend)
    _countries = grouped.entries.map((e) {
      final sorted = e.value..sort((a, b) => b.score.compareTo(a.score));
      final bestSpd = sorted.map((s) => s.speed).reduce((a, b) => a > b ? a : b);
      return ProxyCountry(
        countryCode: e.key,
        countryName: sorted.first.countryName,
        servers: sorted.toList(),
        serverCount: sorted.length,
        bestSpeed: bestSpd,
      );
    }).toList()
      ..sort((a, b) => b.bestSpeed.compareTo(a.bestSpeed));

    // Locked countries
    final unlockedCodes = grouped.keys.toSet();
    _lockedCountries = allCountryCodes
        .where((c) => !unlockedCodes.contains(c))
        .map((c) {
      final sample = servers.firstWhere((s) => s.countryCode == c);
      return ProxyCountry(
        countryCode: c,
        countryName: sample.countryName,
        locked: true,
      );
    }).toList();

    _error = null;
  }

  /// Simple CSV line parser that handles quoted fields
  List<String> _parseCsvLine(String line) {
    final fields = <String>[];
    bool inQuotes = false;
    final current = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        fields.add(current.toString());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    fields.add(current.toString());
    return fields;
  }

  /// Max rounds to cycle through all servers before giving up
  static const int _maxRounds = 2;

  /// Info about current connection attempt (for UI display)
  String? get connectingServerInfo {
    final country = _connectingCountry;
    if (country == null || _status != VpnProxyStatus.connecting) return null;
    final round = (_totalAttempts ~/ country.servers.length) + 1;
    final serverNum = _currentServerIndex + 1;
    final total = country.servers.length;
    if (round > 1) {
      return 'server $serverNum/$total (รอบ $round)';
    }
    return 'server $serverNum/$total';
  }

  /// Connection timeout duration — if not connected within this time,
  /// try the next server in the country.
  static const Duration _connectionTimeout = Duration(seconds: 30);

  /// Connect to the best server in a country (with auto-fallback to next server)
  Future<bool> connectToCountry(ProxyCountry country) async {
    if (country.servers.isEmpty) {
      _error = 'ไม่มี server สำหรับประเทศนี้';
      notifyListeners();
      return false;
    }
    _connectingCountry = country;
    _currentServerIndex = 0;
    _totalAttempts = 0;
    return _connectToServerAt(country, 0);
  }

  /// Switch to a different country — disconnects fully, then connects.
  /// Uses sequential disconnect→connect instead of _pendingReconnect
  /// to avoid race conditions with user-initiated disconnect.
  Future<void> switchToCountry(ProxyCountry country) async {
    if (country.servers.isEmpty) {
      _error = 'ไม่มี server สำหรับประเทศนี้';
      notifyListeners();
      return;
    }

    if (_status == VpnProxyStatus.connected ||
        _status == VpnProxyStatus.connecting) {
      await disconnect();
    }
    await connectToCountry(country);
  }

  /// Connect to server at given index within the country, with timeout fallback
  Future<bool> _connectToServerAt(ProxyCountry country, int index, {bool isRetry = false}) async {
    _currentServerIndex = index % country.servers.length;
    _totalAttempts++;

    // Check if we've exhausted all rounds
    final maxAttempts = country.servers.length * _maxRounds;
    if (_totalAttempts > maxAttempts) {
      _status = VpnProxyStatus.error;
      _error = 'ลอง ${country.servers.length} servers ครบ $_maxRounds รอบแล้ว ไม่สามารถเชื่อมต่อได้';
      _clearConnectionState();
      _connectingCountry = null;
      notifyListeners();
      return false;
    }

    return connect(country.servers[_currentServerIndex], isRetry: isRetry);
  }

  /// Try the next server in the current country (called on timeout or error).
  /// Wraps around to the first server when reaching the end — keeps cycling
  /// until [_maxRounds] full rounds are exhausted.
  ///
  /// Uses [_pendingReconnect] to survive _onStageChanged(disconnected) clearing
  /// state when _openvpn.disconnect() fires the callback.
  void _tryNextServer() {
    final country = _connectingCountry;
    if (country == null || country.servers.isEmpty) return;

    // Check if we've exhausted all rounds
    final maxAttempts = country.servers.length * _maxRounds;
    if (_totalAttempts >= maxAttempts) {
      _status = VpnProxyStatus.error;
      _error = 'ลอง ${country.servers.length} servers ครบ $_maxRounds รอบแล้ว ไม่สามารถเชื่อมต่อได้';
      _clearConnectionState();
      _connectingCountry = null;
      notifyListeners();
      _openvpn.disconnect();
      return;
    }

    final nextIndex = (_currentServerIndex + 1) % country.servers.length;
    _currentServerIndex = nextIndex;
    final round = (_totalAttempts ~/ country.servers.length) + 1;
    debugPrint('VPN retry — server ${nextIndex + 1}/${country.servers.length} (รอบ $round)');

    // Use _pendingReconnect so that _onStageChanged(disconnected) auto-connects
    // instead of clearing state. This avoids the race where disconnect's callback
    // fires before our retry can start.
    _pendingReconnect = country.servers[nextIndex];
    _openvpn.disconnect();
    // _onStageChanged(disconnected) will pick up _pendingReconnect → connect()
  }

  /// Connect to a specific server.
  /// [isRetry] is used internally for server fallback — skips the
  /// "already connecting" guard.
  Future<bool> connect(ProxyServer server, {bool isRetry = false}) async {
    if (!isRetry && _status == VpnProxyStatus.connecting) return false;

    // Cancel any existing connection timeout
    _connectionTimer?.cancel();

    _status = VpnProxyStatus.connecting;
    _error = null;
    _connectedCountry = server.countryCode;
    _connectedHostname = server.hostname;
    _connectedIp = server.ip;
    notifyListeners();

    try {
      // Decode base64 OpenVPN config (strip whitespace/newlines from base64)
      final cleanBase64 = server.openvpnConfig.replaceAll(RegExp(r'\s'), '');
      final configData = utf8.decode(base64Decode(cleanBase64));

      // Use filteredConfig to pick one random remote if config has multiple
      // remote lines (prevents ANR from plugin trying all remotes sequentially).
      // Wrapped in try-catch because the plugin's filteredConfig() crashes with
      // Random().nextInt(0) when there's only 1 remote line.
      String filteredData = configData;
      try {
        filteredData = await OpenVPN.filteredConfig(configData) ?? configData;
      } catch (_) {
        // Single remote or parse error — use original config
      }

      // Ensure config ends with newline (plugin appends directives without \n)
      final normalizedConfig = filteredData.endsWith('\n')
          ? filteredData
          : '$filteredData\n';

      _openvpn.connect(
        normalizedConfig,
        server.hostname,
        username: '',
        password: '',
        // VPN Gate configs already include <ca> certs but don't need client certs.
        // Set true to prevent plugin from appending "client-cert-not-required"
        // without a newline (which corrupts the config).
        certIsRequired: true,
      );

      // Start connection timeout — if not connected within the timeout,
      // try the next server in the country automatically.
      _connectionTimer = Timer(_connectionTimeout, () {
        if (_status == VpnProxyStatus.connecting) {
          debugPrint('VPN connection timeout for ${server.hostname}');
          _tryNextServer();
        }
      });

      await _saveLastCountry(server.countryCode);
      return true;
    } catch (e) {
      _connectionTimer?.cancel();
      _status = VpnProxyStatus.error;
      _error = 'ไม่สามารถเชื่อมต่อ VPN ได้: $e';
      _clearConnectionState();
      _connectingCountry = null;
      notifyListeners();
      return false;
    }
  }

  /// Disconnect from VPN — clears all pending state.
  /// Safe to call from user-initiated disconnect (power button).
  /// Auto-retry uses _pendingReconnect which is preserved inside
  /// _tryNextServer → _onStageChanged, not across disconnect() calls.
  Future<void> disconnect() async {
    _connectionTimer?.cancel();
    _pendingReconnect = null;
    _connectingCountry = null;
    _status = VpnProxyStatus.disconnecting;
    notifyListeners();

    _openvpn.disconnect();

    // Wait briefly for the stage callback
    await Future.delayed(const Duration(milliseconds: 500));

    if (_status == VpnProxyStatus.disconnecting) {
      _status = VpnProxyStatus.disconnected;
      _clearConnectionState();
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

  /// Continuously ping the actually connected server (found by hostname)
  Future<void> pingConnected() async {
    if (_connectedHostname == null || _connectedCountry == null) return;

    // Find the actual connected server by hostname, not just bestServer
    ProxyServer? server = findServerByHostname(_connectedHostname!);
    if (server == null) {
      // Fallback to bestServer if hostname not found
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

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
    if (_status == VpnProxyStatus.connected ||
        _status == VpnProxyStatus.connecting) {
      _openvpn.disconnect();
    }
    super.dispose();
  }
}
