class NetworkMember {
  final String? id;
  final String displayName;
  final String? virtualIp;
  final String? publicIp;
  final bool isOnline;
  final DateTime? lastHeartbeat;
  final String? machineId;

  const NetworkMember({
    this.id,
    required this.displayName,
    this.virtualIp,
    this.publicIp,
    this.isOnline = false,
    this.lastHeartbeat,
    this.machineId,
  });

  factory NetworkMember.fromJson(Map<String, dynamic> json) {
    return NetworkMember(
      id: json['id']?.toString(),
      displayName: json['display_name'] as String? ?? 'Unknown',
      virtualIp: json['virtual_ip'] as String?,
      publicIp: json['public_ip'] as String?,
      isOnline: json['is_online'] as bool? ?? false,
      lastHeartbeat: json['last_heartbeat'] != null
          ? DateTime.tryParse(json['last_heartbeat'] as String)
          : null,
      machineId: json['machine_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'display_name': displayName,
      if (virtualIp != null) 'virtual_ip': virtualIp,
      if (publicIp != null) 'public_ip': publicIp,
      'is_online': isOnline,
      if (lastHeartbeat != null)
        'last_heartbeat': lastHeartbeat!.toIso8601String(),
      if (machineId != null) 'machine_id': machineId,
    };
  }
}
