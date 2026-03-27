class VpnNetwork {
  final String? id;
  final String name;
  final String slug;
  final String? description;
  final bool isPublic;
  final int memberCount;
  final int onlineCount;
  final String? virtualSubnet;
  final String? createdBy;
  final DateTime? createdAt;

  const VpnNetwork({
    this.id,
    required this.name,
    required this.slug,
    this.description,
    this.isPublic = true,
    this.memberCount = 0,
    this.onlineCount = 0,
    this.virtualSubnet,
    this.createdBy,
    this.createdAt,
  });

  factory VpnNetwork.fromJson(Map<String, dynamic> json) {
    return VpnNetwork(
      id: json['id']?.toString(),
      name: json['name'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      description: json['description'] as String?,
      isPublic: json['is_public'] as bool? ?? true,
      memberCount: json['member_count'] as int? ?? json['members_count'] as int? ?? 0,
      onlineCount: json['online_count'] as int? ?? 0,
      virtualSubnet: json['virtual_subnet'] as String?,
      createdBy: json['created_by'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'slug': slug,
      if (description != null) 'description': description,
      'is_public': isPublic,
      'member_count': memberCount,
      'online_count': onlineCount,
      if (virtualSubnet != null) 'virtual_subnet': virtualSubnet,
      if (createdBy != null) 'created_by': createdBy,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    };
  }
}
