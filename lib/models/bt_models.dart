// Models for the Global BitTorrent system.

class BtCategory {
  final int id;
  final String name;
  final String slug;
  final String icon;
  final String? description;
  final bool isAdult;
  final int sortOrder;
  final int fileCount;

  const BtCategory({
    required this.id,
    required this.name,
    required this.slug,
    required this.icon,
    this.description,
    this.isAdult = false,
    this.sortOrder = 0,
    this.fileCount = 0,
  });

  factory BtCategory.fromJson(Map<String, dynamic> json) {
    return BtCategory(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      icon: json['icon'] as String? ?? 'folder',
      description: json['description'] as String?,
      isAdult: json['is_adult'] == true || json['is_adult'] == 1,
      sortOrder: json['sort_order'] as int? ?? 0,
      fileCount: json['file_count'] as int? ?? 0,
    );
  }
}

class BtFile {
  final int id;
  final String fileHash;
  final String fileName;
  final String? title;
  final int fileSize;
  final String? description;
  final String? thumbnailUrl;
  final int? chunkSize;
  final int? totalChunks;
  final int downloadCount;
  final String? uploaderDisplayName;
  final int onlineSeedersCount;
  final DateTime? createdAt;
  final BtCategoryInfo? category;

  const BtFile({
    required this.id,
    required this.fileHash,
    required this.fileName,
    this.title,
    required this.fileSize,
    this.description,
    this.thumbnailUrl,
    this.chunkSize,
    this.totalChunks,
    this.downloadCount = 0,
    this.uploaderDisplayName,
    this.onlineSeedersCount = 0,
    this.createdAt,
    this.category,
  });

  factory BtFile.fromJson(Map<String, dynamic> json) {
    return BtFile(
      id: json['id'] as int,
      fileHash: json['file_hash'] as String? ?? '',
      fileName: json['file_name'] as String? ?? '',
      title: json['title'] as String?,
      fileSize: json['file_size'] as int? ?? 0,
      description: json['description'] as String?,
      thumbnailUrl: json['thumbnail_url'] as String?,
      chunkSize: json['chunk_size'] as int?,
      totalChunks: json['total_chunks'] as int?,
      downloadCount: json['download_count'] as int? ?? 0,
      uploaderDisplayName: json['uploader_display_name'] as String?,
      onlineSeedersCount: json['online_seeders_count'] as int? ?? 0,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
      category: json['category'] != null
          ? BtCategoryInfo.fromJson(json['category'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Display title: use title if available, otherwise file_name.
  String get displayTitle => (title != null && title!.isNotEmpty) ? title! : fileName;

  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class BtCategoryInfo {
  final String slug;
  final String name;
  final String icon;
  final bool? isAdult;

  const BtCategoryInfo({
    required this.slug,
    required this.name,
    required this.icon,
    this.isAdult,
  });

  factory BtCategoryInfo.fromJson(Map<String, dynamic> json) {
    return BtCategoryInfo(
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String? ?? '',
      icon: json['icon'] as String? ?? 'folder',
      isAdult: json['is_adult'] as bool?,
    );
  }
}

class BtSeeder {
  final String machineId;
  final String? displayName;
  final bool isOnline;
  final String? publicIp;
  final int? publicPort;
  final String? lastSeenAt;
  final String? chunksBitmap;

  const BtSeeder({
    required this.machineId,
    this.displayName,
    this.isOnline = false,
    this.publicIp,
    this.publicPort,
    this.lastSeenAt,
    this.chunksBitmap,
  });

  factory BtSeeder.fromJson(Map<String, dynamic> json) {
    return BtSeeder(
      machineId: json['machine_id'] as String? ?? '',
      displayName: json['display_name'] as String?,
      isOnline: json['is_online'] == true || json['is_online'] == 1,
      publicIp: json['public_ip'] as String?,
      publicPort: json['public_port'] as int?,
      lastSeenAt: json['last_seen_at'] as String?,
      chunksBitmap: json['chunks_bitmap'] as String?,
    );
  }
}

class BtUserStats {
  final String? displayName;
  final int totalUploadedBytes;
  final int totalDownloadedBytes;
  final int totalFilesShared;
  final int totalFilesDownloaded;
  final int seedTimeSeconds;
  final int score;
  final int rankPosition;

  const BtUserStats({
    this.displayName,
    this.totalUploadedBytes = 0,
    this.totalDownloadedBytes = 0,
    this.totalFilesShared = 0,
    this.totalFilesDownloaded = 0,
    this.seedTimeSeconds = 0,
    this.score = 0,
    this.rankPosition = 0,
  });

  factory BtUserStats.fromJson(Map<String, dynamic> json) {
    return BtUserStats(
      displayName: json['display_name'] as String?,
      totalUploadedBytes: json['total_uploaded_bytes'] as int? ?? 0,
      totalDownloadedBytes: json['total_downloaded_bytes'] as int? ?? 0,
      totalFilesShared: json['total_files_shared'] as int? ?? 0,
      totalFilesDownloaded: json['total_files_downloaded'] as int? ?? 0,
      seedTimeSeconds: json['seed_time_seconds'] as int? ?? 0,
      score: json['score'] as int? ?? 0,
      rankPosition: json['rank_position'] as int? ?? 0,
    );
  }

  String get uploadFormatted => _formatBytes(totalUploadedBytes);
  String get downloadFormatted => _formatBytes(totalDownloadedBytes);

  String get seedTimeFormatted {
    final hours = seedTimeSeconds ~/ 3600;
    final minutes = (seedTimeSeconds % 3600) ~/ 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  double get ratio {
    if (totalDownloadedBytes == 0) return totalUploadedBytes > 0 ? 999.0 : 0.0;
    return totalUploadedBytes / totalDownloadedBytes;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class BtTrophy {
  final int id;
  final String slug;
  final String name;
  final String description;
  final String icon;
  final String badgeText;
  final String difficulty;
  final String requirementType;
  final int requirementValue;
  final int sortOrder;
  final String? awardedAt;

  const BtTrophy({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.icon,
    required this.badgeText,
    required this.difficulty,
    required this.requirementType,
    required this.requirementValue,
    this.sortOrder = 0,
    this.awardedAt,
  });

  factory BtTrophy.fromJson(Map<String, dynamic> json) {
    return BtTrophy(
      id: json['id'] as int,
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      badgeText: json['badge_text'] as String? ?? '',
      difficulty: json['difficulty'] as String? ?? 'easy',
      requirementType: json['requirement_type'] as String? ?? '',
      requirementValue: json['requirement_value'] as int? ?? 0,
      sortOrder: json['sort_order'] as int? ?? 0,
      awardedAt: json['awarded_at'] as String?,
    );
  }

  bool get isAwarded => awardedAt != null;
}

class BtLeaderboardEntry {
  final int rank;
  final String displayName;
  final String machineId;
  final int score;
  final int totalUploadedBytes;
  final int totalFilesShared;
  final int seedTimeSeconds;
  final List<String> trophies;

  const BtLeaderboardEntry({
    required this.rank,
    required this.displayName,
    required this.machineId,
    this.score = 0,
    this.totalUploadedBytes = 0,
    this.totalFilesShared = 0,
    this.seedTimeSeconds = 0,
    this.trophies = const [],
  });

  factory BtLeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return BtLeaderboardEntry(
      rank: json['rank'] as int? ?? 0,
      displayName: json['display_name'] as String? ?? 'Unknown',
      machineId: json['machine_id'] as String? ?? '',
      score: json['score'] as int? ?? 0,
      totalUploadedBytes: json['total_uploaded_bytes'] as int? ?? 0,
      totalFilesShared: json['total_files_shared'] as int? ?? 0,
      seedTimeSeconds: json['seed_time_seconds'] as int? ?? 0,
      trophies: (json['trophies'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  String get uploadFormatted {
    final bytes = totalUploadedBytes;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String get seedTimeFormatted {
    final hours = seedTimeSeconds ~/ 3600;
    if (hours > 0) return '${hours}h';
    return '${(seedTimeSeconds % 3600) ~/ 60}m';
  }
}

class BtPagination {
  final int currentPage;
  final int perPage;
  final int total;
  final int lastPage;

  const BtPagination({
    this.currentPage = 1,
    this.perPage = 20,
    this.total = 0,
    this.lastPage = 1,
  });

  factory BtPagination.fromJson(Map<String, dynamic> json) {
    return BtPagination(
      currentPage: json['current_page'] as int? ?? 1,
      perPage: json['per_page'] as int? ?? 20,
      total: json['total'] as int? ?? 0,
      lastPage: json['last_page'] as int? ?? 1,
    );
  }

  bool get hasMore => currentPage < lastPage;
}
