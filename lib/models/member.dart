class NetworkMember {
  final String? id;
  final String displayName;
  final String? virtualIp;
  final String? publicIp;
  final int? publicPort;
  final String? vpnGatewayCountry;
  final String? vpnGatewayHostname;
  final bool isOnline;
  final DateTime? lastHeartbeat;
  final String? machineId;

  /// Public key for end-to-end encryption, `v<version>:<base64>`.
  final String? p2pKey;

  /// Whether the server sent the `p2p_key` field at all. A server that
  /// stores keys sends it as null for members whose app predates them.
  final bool reportsP2pKey;

  const NetworkMember({
    this.id,
    required this.displayName,
    this.virtualIp,
    this.publicIp,
    this.publicPort,
    this.vpnGatewayCountry,
    this.vpnGatewayHostname,
    this.isOnline = false,
    this.lastHeartbeat,
    this.machineId,
    this.p2pKey,
    this.reportsP2pKey = false,
  });

  /// Whether this member is acting as a VPN gateway for the network
  bool get isVpnGateway => vpnGatewayCountry != null && vpnGatewayCountry!.isNotEmpty;

  /// Country flag emoji from vpnGatewayCountry code
  String get vpnGatewayFlag {
    if (vpnGatewayCountry == null || vpnGatewayCountry!.length != 2) return '';
    final c = vpnGatewayCountry!.toUpperCase();
    final first = 0x1F1E6 + c.codeUnitAt(0) - 0x41;
    final second = 0x1F1E6 + c.codeUnitAt(1) - 0x41;
    return String.fromCharCodes([first, second]);
  }

  factory NetworkMember.fromJson(Map<String, dynamic> json) {
    return NetworkMember(
      id: json['id']?.toString(),
      displayName: json['display_name'] as String? ?? 'Unknown',
      virtualIp: json['virtual_ip'] as String?,
      publicIp: json['public_ip'] as String?,
      publicPort: json['public_port'] as int?,
      vpnGatewayCountry: json['vpn_gateway_country'] as String?,
      vpnGatewayHostname: json['vpn_gateway_hostname'] as String?,
      isOnline: json['is_online'] as bool? ?? false,
      lastHeartbeat: json['last_heartbeat'] != null
          ? DateTime.tryParse(json['last_heartbeat'] as String)
          : (json['last_heartbeat_at'] != null
              ? DateTime.tryParse(json['last_heartbeat_at'] as String)
              : null),
      machineId: json['machine_id'] as String?,
      p2pKey: json['p2p_key'] as String?,
      reportsP2pKey: json.containsKey('p2p_key'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'display_name': displayName,
      if (virtualIp != null) 'virtual_ip': virtualIp,
      if (publicIp != null) 'public_ip': publicIp,
      if (publicPort != null) 'public_port': publicPort,
      if (vpnGatewayCountry != null) 'vpn_gateway_country': vpnGatewayCountry,
      if (vpnGatewayHostname != null) 'vpn_gateway_hostname': vpnGatewayHostname,
      'is_online': isOnline,
      if (lastHeartbeat != null)
        'last_heartbeat': lastHeartbeat!.toIso8601String(),
      if (machineId != null) 'machine_id': machineId,
      if (reportsP2pKey) 'p2p_key': p2pKey,
    };
  }
}
