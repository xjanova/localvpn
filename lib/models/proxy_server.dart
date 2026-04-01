/// A WireGuard VPN server from the backend
class WireguardServer {
  final int id;
  final String name;
  final String countryCode;
  final String countryName;
  final String endpoint;
  final int load; // 0-100 percentage
  final bool isHealthy;

  WireguardServer({
    required this.id,
    required this.name,
    required this.countryCode,
    required this.countryName,
    required this.endpoint,
    required this.load,
    required this.isHealthy,
  });

  factory WireguardServer.fromJson(Map<String, dynamic> json) => WireguardServer(
        id: json['id'] as int? ?? 0,
        name: json['name'] as String? ?? '',
        countryCode: json['country_code'] as String? ?? '',
        countryName: json['country_name'] as String? ?? '',
        endpoint: json['endpoint'] as String? ?? '',
        load: json['load'] as int? ?? 0,
        isHealthy: json['is_healthy'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'country_code': countryCode,
        'country_name': countryName,
        'endpoint': endpoint,
        'load': load,
        'is_healthy': isHealthy,
      };

  /// Measured latency (set by client after ping test)
  int? measuredPing;

  /// Load label for display
  String get loadLabel {
    if (load < 30) return 'Low';
    if (load < 70) return 'Medium';
    return 'High';
  }
}

/// A country group of WireGuard servers
class ServerCountry {
  final String countryCode;
  final String countryName;
  final List<WireguardServer> servers;
  final bool locked;

  const ServerCountry({
    required this.countryCode,
    required this.countryName,
    this.servers = const [],
    this.locked = false,
  });

  factory ServerCountry.fromJson(Map<String, dynamic> json) {
    final serverList = (json['servers'] as List<dynamic>?)
            ?.map((s) => WireguardServer.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [];

    return ServerCountry(
      countryCode: json['country_code'] as String? ?? '',
      countryName: json['country_name'] as String? ?? '',
      servers: serverList,
      locked: json['locked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'country_code': countryCode,
        'country_name': countryName,
        'servers': servers.map((s) => s.toJson()).toList(),
        'locked': locked,
      };

  /// Best server by lowest load among healthy servers
  WireguardServer? get bestServer {
    if (servers.isEmpty) return null;
    final healthy = servers.where((s) => s.isHealthy).toList();
    if (healthy.isEmpty) return servers.first;
    healthy.sort((a, b) => a.load.compareTo(b.load));
    return healthy.first;
  }

  /// Server count
  int get serverCount => servers.length;

  /// Best load label (from best server)
  String get bestLoadLabel => bestServer?.loadLabel ?? '';

  /// Country flag emoji from country code
  String get flag {
    if (countryCode.length != 2) return '';
    final upper = countryCode.toUpperCase();
    final first = 0x1F1E6 + upper.codeUnitAt(0) - 0x41;
    final second = 0x1F1E6 + upper.codeUnitAt(1) - 0x41;
    return String.fromCharCodes([first, second]);
  }
}
