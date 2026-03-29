import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
    if (_machineId == null || _licenseKey == null) {
      _error = 'ยังไม่ได้ตั้งค่า machine_id หรือ license_key';
      debugPrint('TorrentService.registerSeeder: machineId=$_machineId, licenseKey=${_licenseKey != null ? '***' : 'null'}');
      return false;
    }

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
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('TorrentService.registerSeeder response: ${response.statusCode} ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}');

      final data = _parseResponse(response);
      if (data != null && data['success'] == true) {
        _seedingFileHashes.add(fileHash);
        _ensureHeartbeat();
        _error = null;
        return true;
      } else {
        _error = data?['error'] as String? ?? 'ลงทะเบียน Seeder ล้มเหลว (${response.statusCode})';
        debugPrint('TorrentService.registerSeeder failed: $_error');
      }
    } catch (e) {
      _error = 'ลงทะเบียน Seeder ล้มเหลว: $e';
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
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
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
    String? title,
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
        if (title != null) 'title': title,
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
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
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
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
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
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
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

  // ─── DOWNLOAD VIA SERVER RELAY ───

  bool _isDownloading = false;
  bool get isDownloadingFile => _isDownloading;

  double _downloadProgress = 0;
  double get downloadProgress => _downloadProgress;

  String? _downloadError;
  String? get downloadError => _downloadError;

  /// Download a file via server relay.
  /// Flow: request chunks → seeder uploads to server → we fetch from server.
  Future<String?> downloadFile(BtFile file, List<BtSeeder> seeders) async {
    if (_machineId == null || _licenseKey == null) return null;
    if (_isDownloading) return null;

    final onlineSeeder = seeders.where((s) => s.isOnline).firstOrNull;
    if (onlineSeeder == null) {
      _error = 'ไม่มี Seeder ออนไลน์';
      notifyListeners();
      return null;
    }

    _isDownloading = true;
    _downloadProgress = 0;
    _downloadError = null;
    _error = null;
    notifyListeners();

    try {
      final chunkSize = (file.chunkSize != null && file.chunkSize! > 0)
          ? file.chunkSize!
          : 32768;
      final totalChunks = (file.totalChunks != null && file.totalChunks! > 0)
          ? file.totalChunks!
          : (file.fileSize / chunkSize).ceil();

      final chunks = <int, Uint8List>{};

      // Process in batches of 5 chunks
      for (int batchStart = 0; batchStart < totalChunks; batchStart += 5) {
        final batchEnd = (batchStart + 5).clamp(0, totalChunks);
        final indices = List.generate(batchEnd - batchStart, (i) => batchStart + i);

        // 1. Request chunks from seeder via relay
        await http.post(
          Uri.parse('$_baseUrl/torrent/relay/request'),
          headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
          body: jsonEncode({
            'machine_id': _machineId,
            'license_key': _licenseKey,
            'file_hash': file.fileHash,
            'chunk_indices': indices,
            'target_machine_id': onlineSeeder.machineId,
          }),
        ).timeout(const Duration(seconds: 10));

        // 2. Wait for seeder to relay chunks (poll with timeout)
        for (int attempt = 0; attempt < 15; attempt++) {
          await Future.delayed(const Duration(seconds: 2));

          final fetchResponse = await http.post(
            Uri.parse('$_baseUrl/torrent/relay/fetch'),
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({
              'machine_id': _machineId,
              'license_key': _licenseKey,
              'file_hash': file.fileHash,
              'chunk_indices': indices.where((i) => !chunks.containsKey(i)).toList(),
            }),
          ).timeout(const Duration(seconds: 10));

          if (fetchResponse.statusCode == 200) {
            final data = jsonDecode(fetchResponse.body) as Map<String, dynamic>;
            final received = data['chunks'] as List? ?? [];

            for (final c in received) {
              final idx = c['chunk_index'] as int;
              final b64 = c['data'] as String;
              chunks[idx] = base64Decode(b64);
            }
          }

          _downloadProgress = chunks.length / totalChunks;
          notifyListeners();

          // Check if all chunks in this batch received
          if (indices.every((i) => chunks.containsKey(i))) break;
        }

        // Check if batch failed
        final missing = indices.where((i) => !chunks.containsKey(i)).toList();
        if (missing.isNotEmpty) {
          throw Exception('Chunk ${missing.first} ไม่ได้รับจาก seeder (timeout)');
        }
      }

      // Assemble file
      final buffer = BytesBuilder();
      for (int i = 0; i < totalChunks; i++) {
        final chunk = chunks[i];
        if (chunk == null) throw Exception('Missing chunk $i');
        buffer.add(chunk);
      }

      final assembled = buffer.toBytes();

      // Verify hash
      final hash = sha256.convert(assembled).toString();
      if (hash != file.fileHash) {
        throw Exception('ไฟล์เสียหาย (hash ไม่ตรง)');
      }

      // Save file
      final dir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory('${dir.path}/LocalVPN/Torrent');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      final filePath = '${downloadDir.path}/${file.fileName}';
      await File(filePath).writeAsBytes(assembled);

      _downloadProgress = 1.0;
      _isDownloading = false;
      notifyListeners();

      // Auto-register as seeder
      _seedingFileHashes.add(file.fileHash);
      _ensureHeartbeat();
      await registerSeeder(fileHash: file.fileHash);

      return filePath;
    } catch (e) {
      _downloadError = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      _isDownloading = false;
      _downloadProgress = 0;
      notifyListeners();
      debugPrint('TorrentService.downloadFile error: $e');
      return null;
    }
  }

  // ─── SEEDER RELAY POLL (background) ───

  Timer? _relayPollTimer;

  /// Start polling for relay requests (when seeding files).
  void startRelayPoll() {
    _relayPollTimer?.cancel();
    _relayPollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollRelayRequests());
  }

  void stopRelayPoll() {
    _relayPollTimer?.cancel();
    _relayPollTimer = null;
  }

  /// Poll for chunk requests and respond with data.
  Future<void> _pollRelayRequests() async {
    if (_machineId == null || _licenseKey == null) return;
    if (_seedingFileHashes.isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/torrent/relay/poll'),
        headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'license_key': _licenseKey,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final requests = data['requests'] as List? ?? [];

      for (final req in requests) {
        final fileHash = req['file_hash'] as String;
        final chunkIndex = req['chunk_index'] as int;
        final requester = req['requester'] as String;

        // Read chunk from local file (if we have it)
        final chunkData = await _readLocalChunk(fileHash, chunkIndex);
        if (chunkData == null) continue;

        // Upload chunk to server for relay
        await http.post(
          Uri.parse('$_baseUrl/torrent/relay/chunk'),
          headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
          body: jsonEncode({
            'machine_id': _machineId,
            'license_key': _licenseKey,
            'file_hash': fileHash,
            'chunk_index': chunkIndex,
            'data': base64Encode(chunkData),
            'target_machine_id': requester,
          }),
        ).timeout(const Duration(seconds: 15));
      }
    } catch (e) {
      debugPrint('TorrentService.pollRelay error: $e');
    }
  }

  /// Read a chunk from a locally stored file.
  Future<Uint8List?> _readLocalChunk(String fileHash, int chunkIndex) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final torrentDir = Directory('${dir.path}/LocalVPN/Torrent');
      if (!await torrentDir.exists()) return null;

      // Find file by checking hash of each file in torrent dir
      // For efficiency, cache file paths by hash
      final files = torrentDir.listSync().whereType<File>();
      for (final file in files) {
        // Check if this file matches the hash (simplified: read entire file)
        // In production, should cache hash→path mapping
        final bytes = await file.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        if (hash == fileHash) {
          final chunkSize = 32768;
          final start = chunkIndex * chunkSize;
          if (start >= bytes.length) return null;
          final end = (start + chunkSize).clamp(0, bytes.length);
          return Uint8List.fromList(bytes.sublist(start, end));
        }
      }
    } catch (e) {
      debugPrint('Read chunk error: $e');
    }
    return null;
  }

  // ─── CLEANUP ───

  @override
  void dispose() {
    stopHeartbeat();
    stopRelayPoll();
    super.dispose();
  }
}
