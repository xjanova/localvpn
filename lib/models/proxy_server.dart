/// A VPN proxy server from VPN Gate
class ProxyServer {
  final String hostname;
  final String ip;
  final int score;
  final int ping;
  final int speed;
  final String countryName;
  final String countryCode;
  final int sessions;
  final int uptime;
  final String openvpnConfig; // Base64-encoded OpenVPN config

  const ProxyServer({
    required this.hostname,
    required this.ip,
    required this.score,
    required this.ping,
    required this.speed,
    required this.countryName,
    required this.countryCode,
    required this.sessions,
    required this.uptime,
    required this.openvpnConfig,
  });

  factory ProxyServer.fromJson(Map<String, dynamic> json) => ProxyServer(
        hostname: json['hostname'] as String? ?? '',
        ip: json['ip'] as String? ?? '',
        score: json['score'] as int? ?? 0,
        ping: json['ping'] as int? ?? 0,
        speed: json['speed'] as int? ?? 0,
        countryName: json['country_name'] as String? ?? '',
        countryCode: json['country_code'] as String? ?? '',
        sessions: json['sessions'] as int? ?? 0,
        uptime: json['uptime'] as int? ?? 0,
        openvpnConfig: json['openvpn_config'] as String? ?? '',
      );

  /// Speed in Mbps (API returns bytes/s)
  double get speedMbps => speed / 1000000;

  String get speedLabel {
    if (speedMbps >= 100) return '${speedMbps.toStringAsFixed(0)} Mbps';
    if (speedMbps >= 1) return '${speedMbps.toStringAsFixed(1)} Mbps';
    return '${(speed / 1000).toStringAsFixed(0)} Kbps';
  }
}

/// A country group of VPN servers
class ProxyCountry {
  final String countryCode;
  final String countryName;
  final List<ProxyServer> servers;
  final int serverCount;
  final int bestSpeed;
  final bool locked;

  const ProxyCountry({
    required this.countryCode,
    required this.countryName,
    this.servers = const [],
    this.serverCount = 0,
    this.bestSpeed = 0,
    this.locked = false,
  });

  factory ProxyCountry.fromJson(Map<String, dynamic> json) {
    final serverList = (json['servers'] as List<dynamic>?)
            ?.map((s) => ProxyServer.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [];

    return ProxyCountry(
      countryCode: json['country_code'] as String? ?? '',
      countryName: json['country_name'] as String? ?? '',
      servers: serverList,
      serverCount: json['server_count'] as int? ?? serverList.length,
      bestSpeed: json['best_speed'] as int? ?? 0,
      locked: json['locked'] as bool? ?? false,
    );
  }

  /// Best server by score
  ProxyServer? get bestServer =>
      servers.isNotEmpty ? servers.first : null; // Already sorted by score

  String get bestSpeedLabel {
    final mbps = bestSpeed / 1000000;
    if (mbps >= 100) return '${mbps.toStringAsFixed(0)} Mbps';
    if (mbps >= 1) return '${mbps.toStringAsFixed(1)} Mbps';
    return '${(bestSpeed / 1000).toStringAsFixed(0)} Kbps';
  }

  /// Country flag emoji from country code
  String get flag {
    if (countryCode.length != 2) return '';
    final first = 0x1F1E6 + countryCode.codeUnitAt(0) - 0x41;
    final second = 0x1F1E6 + countryCode.codeUnitAt(1) - 0x41;
    return String.fromCharCodes([first, second]);
  }
}
