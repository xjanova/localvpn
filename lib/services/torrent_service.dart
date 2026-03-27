import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/bt_models.dart';

/// Service for the Global BitTorrent system API calls.
class TorrentService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';

  String? _machineId;
  String? _licenseKey;
  String? _displayName;

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

  bool _isLoading = false;
  bool get isLoading => _isLoading;

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

  /// Fetch all categories.
  Future<void> fetchCategories() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/torrent/categories')
          .replace(queryParameters: {
        if (_machineId != null) 'machine_id': _machineId!,
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
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

    _isLoading = false;
    notifyListeners();
  }

  /// Fetch files in a category.
  Future<void> fetchFiles(String categorySlug, {
    String sort = 'newest',
    String? search,
    int page = 1,
    bool append = false,
  }) async {
    if (!append) {
      _isLoading = true;
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

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
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

    _isLoading = false;
    notifyListeners();
  }

  /// Fetch file detail.
  Future<BtFile?> fetchFileDetail(int fileId) async {
    try {
      final uri = Uri.parse('$_baseUrl/torrent/file/$fileId');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true && data['file'] != null) {
        return BtFile.fromJson(data['file'] as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('TorrentService.fetchFileDetail error: $e');
    }
    return null;
  }

  /// Fetch seeders for a file.
  Future<List<BtSeeder>> fetchSeeders(int fileId) async {
    try {
      final uri = Uri.parse('$_baseUrl/torrent/file/$fileId/seeders');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
        return (data['seeders'] as List<dynamic>)
            .map((e) => BtSeeder.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('TorrentService.fetchSeeders error: $e');
    }
    return [];
  }

  /// Fetch leaderboard.
  Future<void> fetchLeaderboard() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/torrent/leaderboard');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
        _leaderboard = (data['leaderboard'] as List<dynamic>)
            .map((e) =>
                BtLeaderboardEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      _error = 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้';
      debugPrint('TorrentService.fetchLeaderboard error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Fetch user profile (stats + trophies).
  Future<void> fetchUserProfile() async {
    if (_machineId == null || _licenseKey == null) return;

    try {
      final uri = Uri.parse('$_baseUrl/torrent/profile')
          .replace(queryParameters: {
        'machine_id': _machineId!,
        'license_key': _licenseKey!,
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
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

  /// Fetch all trophies grouped by difficulty.
  Future<void> fetchAllTrophies() async {
    try {
      final uri = Uri.parse('$_baseUrl/torrent/trophies');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true && data['trophies'] != null) {
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

  /// Upload a file to the global torrent system.
  Future<BtFile?> uploadFile({
    required String categorySlug,
    required String fileHash,
    required String fileName,
    required int fileSize,
    String? description,
    String? thumbnailData,
  }) async {
    if (_machineId == null || _licenseKey == null) return null;

    try {
      final body = {
        'machine_id': _machineId!,
        'license_key': _licenseKey!,
        'category_slug': categorySlug,
        'file_hash': fileHash,
        'file_name': fileName,
        'file_size': fileSize,
        if (description != null) 'description': description,
        if (thumbnailData != null) 'thumbnail_data': thumbnailData,
        if (_displayName != null) 'display_name': _displayName,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/torrent/upload'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true && data['file'] != null) {
        return BtFile.fromJson(data['file'] as Map<String, dynamic>);
      } else {
        _error = data['error'] as String?;
      }
    } catch (e) {
      _error = 'อัพโหลดล้มเหลว';
      debugPrint('TorrentService.uploadFile error: $e');
    }

    notifyListeners();
    return null;
  }

  /// Check KYC status.
  Future<void> fetchKycStatus() async {
    if (_machineId == null) return;

    try {
      final uri = Uri.parse('$_baseUrl/torrent/kyc/status')
          .replace(queryParameters: {'machine_id': _machineId!});

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
        _kycStatus = data['status'] as String?;
      }
    } catch (e) {
      debugPrint('TorrentService.fetchKycStatus error: $e');
    }

    notifyListeners();
  }

  /// Submit KYC verification.
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

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] == true) {
        _kycStatus = 'pending';
        notifyListeners();
        return true;
      } else {
        _error = data['error'] as String?;
      }
    } catch (e) {
      _error = 'ส่งข้อมูลล้มเหลว';
      debugPrint('TorrentService.submitKyc error: $e');
    }

    notifyListeners();
    return false;
  }
}
