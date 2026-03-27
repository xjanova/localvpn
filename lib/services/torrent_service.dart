import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/bt_models.dart';

/// Service for the Global BitTorrent system API calls.
class TorrentService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const Duration _heartbeatInterval = Duration(seconds: 120);

  String? _machineId;
  String? _licenseKey;
  String? _displayName;

  // Public endpoint info for P2P
  String? _publicIp;
  int? _publicPort;

  // Active seeding file hashes
  final Set<String> _seedingFileHashes = {};
  Set<String> get seedingFileHashes => _seedingFileHashes;

  Timer? _heartbeatTimer;
  bool get isSeeding => _seedingFileHashes.isNotEmpty;

  List<BtCategory> _categories = [];
  List<BtCategory> get categories => _categories;

  List<BtFile> _files = [];
  List<BtFile> get files => _files;

  BtPagination _pagination = const BtPagination();
  BtPagination get pagination => _pagination;

  List<BtLeaderboardEntry> _leaderboard = [];
  List<BtLeaderboardEntry> get leaderboard => _leaderboard;

  BtUserStats? _userStats;
  BtUserStats? get userStats => _userStats;

  List<BtTrophy> _userTrophies = [];
  List<BtTrophy> get userTrophies => _userTrophies;

  Map<String, List<BtTrophy>> _allTrophies = {};
  Map<String, List<BtTrophy>> get allTrophies => _allTrophies;

  String? _kycStatus;
  String? get kycStatus => _kycStatus;

  bool _isCategoriesLoading = false;
  bool _isFilesLoading = false;
  bool _isLeaderboardLoading = false;
  bool _isUploading = false;
  bool get isLoading =>
      _isCategoriesLoading || _isFilesLoading || _isLeaderboardLoading;
  bool get isUploading => _isUploading;

  String? _error;
  String? get error => _error;

  void configure({
    required String machineId,
    String? licenseKey,
    String? displayName,
  }) {
    _machineId = machineId;
    _licenseKey = licenseKey;
    _displayName = displayName;
  }

  /// Helper: parse response safely with status code checking.
  Map<String, dynamic>? _parseResponse(http.Response response) {
    if (response.statusCode >= 500) {
      debugPrint('Server error: ${response.statusCode}');
      return null;
    }
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('JSON parse error: $e');
      return null;
    }
  }

  /// Discover own public IP via STUN-like endpoint.
  Future<void> discoverPublicIp() async {
    try {
      final uri = Uri.parse('$_baseUrl/stun').replace(queryParameters: {
        'machine_id': _machineId ?? '',
        'license_key': _licenseKey ?? '',
      });
      final response =
          await http.get(uri).timeout(const Duration(seconds: 10));

      final data = _parseResponse(response);
      if (data != null && data['success'] == true) {
        _publicIp = data['ip'] as String?;
        _publicPort = data['port'] as int?;
      }
    } catch (e) {
      debugPrint('TorrentService.discoverPublicIp error: $e');
    }
  }

  // ─── CATEGORIES ───

  Future<void> fetchCategories() async {
    _isCategoriesLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/torrent/categories').replace(
        queryParameters: {
          if (_machineId != null) 'machine_id': _machineId!,
        },
      );
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data == null) {
        _error = 'เซิร์ฟเวอร์ไม่ตอบสนอง';
      } else if (data['success'] == true) {
        _categories = (data['categories'] as List<dynamic>)
            .map((e) => BtCategory.fromJson(e as Map<String, dynamic>))
            .toList();
      } else {
        _error = data['error'] as String? ?? 'Failed to load categories';
      }
    } catch (e) {
      _error = 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้';
      debugPrint('TorrentService.fetchCategories error: $e');
    }

    _isCategoriesLoading = false;
    notifyListeners();
  }

  // ─── FILES ───

  Future<void> fetchFiles(
    String categorySlug, {
    String sort = 'newest',
    String? search,
    int page = 1,
    bool append = false,
  }) async {
    if (!append) {
      _isFilesLoading = true;
      _error = null;
      notifyListeners();
    }

    try {
      final params = <String, String>{
        'sort': sort,
        'page': page.toString(),
        if (search != null && search.isNotEmpty) 'search': search,
        if (_machineId != null) 'machine_id': _machineId!,
      };

      final uri = Uri.parse('$_baseUrl/torrent/files/$categorySlug')
          .replace(queryParameters: params);

      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data == null) {
        _error = 'เซิร์ฟเวอร์ไม่ตอบสนอง';
      } else if (data['success'] == true) {
        final newFiles = (data['files'] as List<dynamic>)
            .map((e) => BtFile.fromJson(e as Map<String, dynamic>))
            .toList();

        if (append) {
          _files.addAll(newFiles);
        } else {
          _files = newFiles;
        }

        if (data['pagination'] != null) {
          _pagination = BtPagination.fromJson(
              data['pagination'] as Map<String, dynamic>);
        }
      } else {
        _error = data['error'] as String? ?? 'Failed to load files';
      }
    } catch (e) {
      _error = 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้';
      debugPrint('TorrentService.fetchFiles error: $e');
    }

    _isFilesLoading = false;
    notifyListeners();
  }

  // ─── FILE DETAIL ───

  Future<BtFile?> fetchFileDetail(int fileId) async {
    try {
      final params = <String, String>{
        if (_machineId != null) 'machine_id': _machineId!,
      };
      final uri = Uri.parse('$_baseUrl/torrent/file/$fileId')
          .replace(queryParameters: params.isNotEmpty ? params : null);
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data != null && data['success'] == true && data['file'] != null) {
        return BtFile.fromJson(data['file'] as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('TorrentService.fetchFileDetail error: $e');
    }
    return null;
  }

  // ─── SEEDERS ───

  Future<List<BtSeeder>> fetchSeeders(int fileId) async {
    try {
      final params = <String, String>{
        if (_machineId != null) 'machine_id': _machineId!,
        if (_licenseKey != null) 'license_key': _licenseKey!,
      };
      final uri = Uri.parse('$_baseUrl/torrent/file/$fileId/seeders')
          .replace(queryParameters: params.isNotEmpty ? params : null);
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data != null && data['success'] == true) {
        return (data['seeders'] as List<dynamic>)
            .map((e) => BtSeeder.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('TorrentService.fetchSeeders error: $e');
    }
    return [];
  }

  // ─── REGISTER AS SEEDER ───

  /// Register this device as a seeder for a file.
  Future<bool> registerSeeder({
    required String fileHash,
    String chunksBitmap = 'all',
  }) async {
    if (_machineId == null || _licenseKey == null) return false;

    try {
      final body = {
        'machine_id': _machineId!,
        'license_key': _licenseKey!,
        'file_hash': fileHash,
        'chunks_bitmap': chunksBitmap,
        if (_displayName != null) 'display_name': _displayName,
        if (_publicIp != null) 'public_ip': _publicIp,
        if (_publicPort != null) 'public_port': _publicPort,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/torrent/seed'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      final data = _parseResponse(response);
      if (data != null && data['success'] == true) {
        _seedingFileHashes.add(fileHash);
        _ensureHeartbeat();
        return true;
      }
    } catch (e) {
      debugPrint('TorrentService.registerSeeder error: $e');
    }
    return false;
  }

  // ─── HEARTBEAT ───

  /// Start heartbeat timer if not already running.
  void _ensureHeartbeat() {
    if (_heartbeatTimer != null) return;
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _sendHeartbeat();
    });
  }

  /// Stop heartbeat and mark seeders offline.
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _seedingFileHashes.clear();
  }

  /// Send heartbeat to keep seeder status alive.
  Future<void> _sendHeartbeat() async {
    if (_machineId == null || _licenseKey == null) return;
    if (_seedingFileHashes.isEmpty) {
      stopHeartbeat();
      return;
    }

    try {
      final body = {
        'machine_id': _machineId!,
        'license_key': _licenseKey!,
        'file_hashes': _seedingFileHashes.toList(),
        if (_publicIp != null) 'public_ip': _publicIp,
        if (_publicPort != null) 'public_port': _publicPort,
      };

      await http
          .post(
            Uri.parse('$_baseUrl/torrent/heartbeat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('TorrentService.heartbeat error: $e');
    }
  }

  // ─── UPLOAD ───

  Future<BtFile?> uploadFile({
    required String categorySlug,
    required String fileHash,
    required String fileName,
    required int fileSize,
    String? description,
    String? thumbnailData,
    int? chunkSize,
  }) async {
    if (_machineId == null || _licenseKey == null) return null;

    _isUploading = true;
    _error = null;
    notifyListeners();

    try {
      final body = <String, dynamic>{
        'machine_id': _machineId!,
        'license_key': _licenseKey!,
        'category_slug': categorySlug,
        'file_hash': fileHash,
        'file_name': fileName,
        'file_size': fileSize,
        if (description != null) 'description': description,
        if (thumbnailData != null) 'thumbnail_data': thumbnailData,
        if (_displayName != null) 'display_name': _displayName,
        if (chunkSize != null) 'chunk_size': chunkSize,
        if (_publicIp != null) 'public_ip': _publicIp,
        if (_publicPort != null) 'public_port': _publicPort,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/torrent/upload'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      final data = _parseResponse(response);

      if (data != null && data['success'] == true && data['file'] != null) {
        final btFile = BtFile.fromJson(data['file'] as Map<String, dynamic>);
        // Auto-register as seeder for uploaded file
        _seedingFileHashes.add(fileHash);
        _ensureHeartbeat();
        _isUploading = false;
        notifyListeners();
        return btFile;
      } else {
        _error = data?['error'] as String? ?? 'อัพโหลดล้มเหลว';
      }
    } catch (e) {
      _error = 'อัพโหลดล้มเหลว';
      debugPrint('TorrentService.uploadFile error: $e');
    }

    _isUploading = false;
    notifyListeners();
    return null;
  }

  // ─── LEADERBOARD ───

  Future<void> fetchLeaderboard() async {
    _isLeaderboardLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/torrent/leaderboard');
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data != null && data['success'] == true) {
        _leaderboard = (data['leaderboard'] as List<dynamic>)
            .map((e) =>
                BtLeaderboardEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      _error = 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้';
      debugPrint('TorrentService.fetchLeaderboard error: $e');
    }

    _isLeaderboardLoading = false;
    notifyListeners();
  }

  // ─── USER PROFILE ───

  Future<void> fetchUserProfile() async {
    if (_machineId == null || _licenseKey == null) return;

    try {
      // Use POST to avoid exposing license_key in URL
      final response = await http
          .post(
            Uri.parse('$_baseUrl/torrent/profile'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'machine_id': _machineId!,
              'license_key': _licenseKey!,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = _parseResponse(response);

      if (data != null && data['success'] == true) {
        if (data['stats'] != null) {
          _userStats = BtUserStats.fromJson(
              data['stats'] as Map<String, dynamic>);
        }
        if (data['trophies'] != null) {
          _userTrophies = (data['trophies'] as List<dynamic>)
              .map((e) => BtTrophy.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (e) {
      debugPrint('TorrentService.fetchUserProfile error: $e');
    }

    notifyListeners();
  }

  // ─── TROPHIES ───

  Future<void> fetchAllTrophies() async {
    try {
      final uri = Uri.parse('$_baseUrl/torrent/trophies');
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data != null && data['success'] == true && data['trophies'] != null) {
        final trophiesMap = data['trophies'] as Map<String, dynamic>;
        _allTrophies = {};
        trophiesMap.forEach((key, value) {
          _allTrophies[key] = (value as List<dynamic>)
              .map((e) => BtTrophy.fromJson(e as Map<String, dynamic>))
              .toList();
        });
      }
    } catch (e) {
      debugPrint('TorrentService.fetchAllTrophies error: $e');
    }

    notifyListeners();
  }

  // ─── KYC ───

  Future<void> fetchKycStatus() async {
    if (_machineId == null) return;

    try {
      final uri = Uri.parse('$_baseUrl/torrent/kyc/status')
          .replace(queryParameters: {'machine_id': _machineId!});
      final response =
          await http.get(uri).timeout(const Duration(seconds: 15));
      final data = _parseResponse(response);

      if (data != null && data['success'] == true) {
        _kycStatus = data['status'] as String?;
      }
    } catch (e) {
      debugPrint('TorrentService.fetchKycStatus error: $e');
    }

    notifyListeners();
  }

  Future<bool> submitKyc({
    required String displayName,
    required String idCardFrontBase64,
    required String birthDate,
    String? idCardBackBase64,
    String? selfieBase64,
  }) async {
    if (_machineId == null || _licenseKey == null) return false;

    try {
      final body = {
        'machine_id': _machineId!,
        'license_key': _licenseKey!,
        'display_name': displayName,
        'id_card_front': idCardFrontBase64,
        'birth_date': birthDate,
        if (idCardBackBase64 != null) 'id_card_back': idCardBackBase64,
        if (selfieBase64 != null) 'selfie': selfieBase64,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/torrent/kyc/submit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      final data = _parseResponse(response);

      if (data != null && data['success'] == true) {
        _kycStatus = 'pending';
        notifyListeners();
        return true;
      } else {
        _error = data?['error'] as String?;
      }
    } catch (e) {
      _error = 'ส่งข้อมูลล้มเหลว';
      debugPrint('TorrentService.submitKyc error: $e');
    }

    notifyListeners();
    return false;
  }

  // ─── CLEANUP ───

  @override
  void dispose() {
    stopHeartbeat();
    super.dispose();
  }
}
