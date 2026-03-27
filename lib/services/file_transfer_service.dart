import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'p2p_service.dart';

/// Compute SHA256 hash of a file in a separate isolate (top-level for compute())
Future<String> _computeFileHash(String filePath) async {
  final bytes = await File(filePath).readAsBytes();
  return sha256.convert(bytes).toString();
}

/// File transfer state
enum TransferStatus { waiting, transferring, completed, failed, cancelled }

/// Direction of transfer
enum TransferDirection { upload, download }

/// Seeder info for a file
class FileSeeder {
  final String virtualIp;
  final String? publicIp;
  final int? publicPort;
  final String displayName;
  final bool hasAll;
  final String chunksBitmap;

  FileSeeder({
    required this.virtualIp,
    this.publicIp,
    this.publicPort,
    required this.displayName,
    this.hasAll = false,
    this.chunksBitmap = '',
  });

  factory FileSeeder.fromJson(Map<String, dynamic> json) => FileSeeder(
        virtualIp: json['virtual_ip'] as String,
        publicIp: json['public_ip'] as String?,
        publicPort: json['public_port'] as int?,
        displayName: json['display_name'] as String? ?? 'Unknown',
        hasAll: json['has_all'] as bool? ?? false,
        chunksBitmap: json['chunks_bitmap'] as String? ?? '',
      );
}

/// A file shared to the network (registered on server)
class SharedFile {
  final int id;
  final String fileHash;
  final String fileName;
  final int fileSize;
  final int chunkSize;
  final int totalChunks;
  final String ownerDisplayName;
  final String? ownerVirtualIp;
  final int seedersCount;
  final int onlineSeedersCount;
  final DateTime? createdAt;
  String? localPath; // non-null if we have the file locally

  SharedFile({
    required this.id,
    required this.fileHash,
    required this.fileName,
    required this.fileSize,
    this.chunkSize = 32768,
    this.totalChunks = 0,
    required this.ownerDisplayName,
    this.ownerVirtualIp,
    this.seedersCount = 0,
    this.onlineSeedersCount = 0,
    this.createdAt,
    this.localPath,
  });

  factory SharedFile.fromJson(Map<String, dynamic> json) => SharedFile(
        id: json['id'] as int,
        fileHash: json['file_hash'] as String,
        fileName: json['file_name'] as String,
        fileSize: json['file_size'] as int,
        chunkSize: json['chunk_size'] as int? ?? 32768,
        totalChunks: json['total_chunks'] as int? ?? 0,
        ownerDisplayName: json['owner_display_name'] as String? ?? 'Unknown',
        ownerVirtualIp: json['owner_virtual_ip'] as String?,
        seedersCount: json['seeders_count'] as int? ?? 0,
        onlineSeedersCount: json['online_seeders_count'] as int? ?? 0,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
      );

  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// A single file transfer (upload or download)
class FileTransfer {
  final String fileHash;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final String peerDisplayName;
  TransferStatus status;
  int bytesTransferred;
  DateTime createdAt;
  String? localPath;
  String? error;

  // BitTorrent-style chunking
  final int chunkSize;
  final int totalChunks;
  final Set<int> completedChunks = {};
  double get progress =>
      totalChunks == 0 ? 0 : completedChunks.length / totalChunks;

  // Multi-peer: which peers we're downloading from
  final List<String> activeSeeders = [];

  FileTransfer({
    required this.fileHash,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.peerDisplayName,
    this.status = TransferStatus.waiting,
    this.bytesTransferred = 0,
    this.localPath,
    this.error,
    this.chunkSize = 32768,
    int? totalChunks,
  })  : totalChunks = totalChunks ?? (fileSize / 32768).ceil(),
        createdAt = DateTime.now();

  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get speedFormatted {
    final elapsed = DateTime.now().difference(createdAt).inSeconds;
    if (elapsed == 0 || bytesTransferred == 0) return '---';
    final bps = bytesTransferred / elapsed;
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}

/// Network-wide P2P file sharing service (BitTorrent-style).
///
/// Flow:
/// 1. User shares a file → registers on server registry
/// 2. All members see shared files via API
/// 3. Download requests go to server for seeder list
/// 4. Chunks are requested from MULTIPLE seeders simultaneously
/// 5. After download, device becomes a seeder too
///
/// Protocol messages (via P2P UDP):
/// - LVPN_FILE_CHUNK_REQ:{hash}|{chunkIndex}  → request chunk
/// - LVPN_FILE_CHUNK_RES:{hash}|{chunkIndex}|{base64data} → chunk data
/// - LVPN_FILE_CANCEL:{hash} → cancel transfer
class FileTransferService extends ChangeNotifier {
  static const String _baseUrl = 'https://xman4289.com/api/v1/localvpn';
  static const int _defaultChunkSize = 32768;
  static const int _maxConcurrentChunkRequests = 8;

  P2pService? _p2pService;
  String? _deviceId;
  String? _licenseKey;
  String? _networkSlug;
  // Network-wide shared files (from server registry)
  final List<SharedFile> _networkFiles = [];
  List<SharedFile> get networkFiles => List.unmodifiable(_networkFiles);

  // Our locally shared files
  final Map<String, String> _localFilePaths = {}; // hash → path

  // Active transfers
  final List<FileTransfer> _transfers = [];
  List<FileTransfer> get transfers => List.unmodifiable(_transfers);

  // Chunk buffers for incoming files
  final Map<String, Map<int, Uint8List>> _chunkBuffers = {};

  // Pending chunk requests (for multi-peer scheduling)
  final Map<String, Set<int>> _pendingChunks = {};

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_deviceId case final id?) 'X-Device-Id': id,
      };

  Map<String, dynamic> get _authBody => {
        'machine_id': _deviceId ?? '',
        'license_key': _licenseKey ?? '',
        if (_networkSlug case final slug?) 'slug': slug,
      };

  void configure({
    required P2pService p2pService,
    required String deviceId,
    required String licenseKey,
  }) {
    _p2pService = p2pService;
    _deviceId = deviceId;
    _licenseKey = licenseKey;
  }

  void setNetwork(String? slug) {
    _networkSlug = slug;
    if (slug == null) {
      _networkFiles.clear();
      notifyListeners();
    }
  }

  // ==================== Server Registry ====================

  /// Share a file → register on server so all members see it
  Future<bool> shareFile(String filePath) async {
    if (_networkSlug == null) return false;

    final file = File(filePath);
    if (!await file.exists()) return false;

    final fileSize = await file.length();

    // Compute SHA256 hash (use compute for large files to avoid blocking UI)
    final hash = await compute(_computeFileHash, filePath);

    // Store locally
    _localFilePaths[hash] = filePath;

    // Register on server
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/files/share'),
            headers: _headers,
            body: jsonEncode({
              ..._authBody,
              'file_hash': hash,
              'file_name': path.basename(filePath),
              'file_size': fileSize,
              'chunk_size': _defaultChunkSize,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        await refreshFileList();
        return true;
      }
    } catch (e) {
      debugPrint('Share file error: $e');
    }
    return false;
  }

  /// Unshare a file (remove from server registry)
  Future<void> unshareFile(int fileId, String fileHash) async {
    _localFilePaths.remove(fileHash);

    try {
      final request = http.Request(
        'DELETE',
        Uri.parse('$_baseUrl/files/$fileId'),
      );
      request.headers.addAll(_headers);
      request.body = jsonEncode(_authBody);
      await request.send().timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Unshare error: $e');
    }

    await refreshFileList();
  }

  /// Refresh the file list from server
  Future<void> refreshFileList() async {
    if (_networkSlug == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/files/$_networkSlug'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final files = data['files'] as List? ?? [];

        _networkFiles.clear();
        for (final f in files) {
          final sf = SharedFile.fromJson(f as Map<String, dynamic>);
          // Mark if we have it locally
          if (_localFilePaths.containsKey(sf.fileHash)) {
            sf.localPath = _localFilePaths[sf.fileHash];
          }
          _networkFiles.add(sf);
        }
      }
    } catch (e) {
      debugPrint('Refresh file list error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  // ==================== Swarm Download ====================

  /// Download a file using BitTorrent-style multi-peer swarm
  Future<FileTransfer?> downloadFile(SharedFile remoteFile) async {
    // Already downloading?
    if (_transfers.any((t) =>
        t.fileHash == remoteFile.fileHash &&
        t.status == TransferStatus.transferring)) {
      return null;
    }

    // Already have it?
    if (_localFilePaths.containsKey(remoteFile.fileHash)) return null;

    final transfer = FileTransfer(
      fileHash: remoteFile.fileHash,
      fileName: remoteFile.fileName,
      fileSize: remoteFile.fileSize,
      direction: TransferDirection.download,
      peerDisplayName: '${remoteFile.onlineSeedersCount} seeders',
      chunkSize: remoteFile.chunkSize,
      totalChunks: remoteFile.totalChunks,
    );
    _transfers.add(transfer);
    _chunkBuffers[remoteFile.fileHash] = {};
    notifyListeners();

    // Get seeders from server
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/files/${remoteFile.id}/seeders'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final seeders = (data['seeders'] as List? ?? [])
            .map((s) => FileSeeder.fromJson(s as Map<String, dynamic>))
            .toList();

        if (seeders.isEmpty) {
          transfer.status = TransferStatus.failed;
          transfer.error = 'ไม่มี seeder ออนไลน์';
          notifyListeners();
          return transfer;
        }

        transfer.status = TransferStatus.transferring;
        transfer.activeSeeders
            .addAll(seeders.map((s) => s.virtualIp));
        notifyListeners();

        // Request chunks from multiple seeders
        _requestChunksFromSwarm(transfer, seeders);
      } else {
        transfer.status = TransferStatus.failed;
        transfer.error = 'ไม่สามารถดึงรายชื่อ seeder ได้';
        notifyListeners();
      }
    } catch (e) {
      transfer.status = TransferStatus.failed;
      transfer.error = 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้';
      notifyListeners();
    }

    return transfer;
  }

  /// Request chunks from multiple seeders (round-robin)
  void _requestChunksFromSwarm(
      FileTransfer transfer, List<FileSeeder> seeders) {
    if (seeders.isEmpty) return;

    final remainingChunks = <int>[];
    for (int i = 0; i < transfer.totalChunks; i++) {
      if (!transfer.completedChunks.contains(i)) {
        remainingChunks.add(i);
      }
    }

    _pendingChunks[transfer.fileHash] = remainingChunks.toSet();

    // Distribute chunks across seeders (round-robin)
    int seederIndex = 0;
    int concurrent = 0;

    for (final chunkIndex in remainingChunks) {
      if (transfer.status == TransferStatus.cancelled) return;
      if (concurrent >= _maxConcurrentChunkRequests) break;

      final seeder = seeders[seederIndex % seeders.length];
      seederIndex++;
      concurrent++;

      _sendChunkRequest(
        seeder.virtualIp,
        transfer.fileHash,
        chunkIndex,
      );
    }
  }

  /// Send a chunk request to a specific peer
  void _sendChunkRequest(String peerVip, String fileHash, int chunkIndex) {
    final msg = utf8.encode('LVPN_FILE_CHUNK_REQ:$fileHash|$chunkIndex');
    _p2pService?.sendToPeer(peerVip, Uint8List.fromList(msg));
  }

  /// Cancel a transfer
  void cancelTransfer(String fileHash) {
    final transfer =
        _transfers.where((t) => t.fileHash == fileHash).firstOrNull;
    if (transfer == null) return;

    transfer.status = TransferStatus.cancelled;
    _chunkBuffers.remove(fileHash);
    _pendingChunks.remove(fileHash);

    // Notify seeders
    for (final vip in transfer.activeSeeders) {
      final msg = utf8.encode('LVPN_FILE_CANCEL:$fileHash');
      _p2pService?.sendToPeer(vip, Uint8List.fromList(msg));
    }
    notifyListeners();
  }

  /// Remove transfer from list
  void removeTransfer(String fileHash) {
    _transfers.removeWhere((t) => t.fileHash == fileHash);
    _chunkBuffers.remove(fileHash);
    _pendingChunks.remove(fileHash);
    notifyListeners();
  }

  // ==================== P2P Message Handling ====================

  /// Handle incoming P2P file message
  void handleMessage(String fromVirtualIp, Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);

    if (text.startsWith('LVPN_FILE_CHUNK_REQ:')) {
      _handleChunkRequest(fromVirtualIp, text.substring(19));
    } else if (text.startsWith('LVPN_FILE_CHUNK_RES:')) {
      _handleChunkResponse(fromVirtualIp, text.substring(20));
    } else if (text.startsWith('LVPN_FILE_CANCEL:')) {
      // Peer cancelled - we just ignore further requests
    }
  }

  /// Peer requests a chunk from us (we are seeder)
  void _handleChunkRequest(String fromVip, String payload) {
    final parts = payload.split('|');
    if (parts.length < 2) return;

    final fileHash = parts[0];
    final chunkIndex = int.tryParse(parts[1]);
    if (chunkIndex == null) return;

    final filePath = _localFilePaths[fileHash];
    if (filePath == null) return;

    // Read chunk and send
    _sendChunkData(fromVip, fileHash, chunkIndex, filePath);
  }

  /// Read a chunk from local file and send to requester
  Future<void> _sendChunkData(
    String targetVip,
    String fileHash,
    int chunkIndex,
    String filePath,
  ) async {
    try {
      final file = File(filePath);
      final raf = await file.open();

      final start = chunkIndex * _defaultChunkSize;
      await raf.setPosition(start);

      final fileLength = await raf.length();
      final end = min(start + _defaultChunkSize, fileLength);
      final chunk = await raf.read(end - start);
      await raf.close();

      final chunkB64 = base64Encode(chunk);
      final msg =
          utf8.encode('LVPN_FILE_CHUNK_RES:$fileHash|$chunkIndex|$chunkB64');
      _p2pService?.sendToPeer(targetVip, Uint8List.fromList(msg));

      // Track upload
      final uploadTransfer = _transfers
          .where((t) =>
              t.fileHash == fileHash &&
              t.direction == TransferDirection.upload)
          .firstOrNull;
      if (uploadTransfer != null) {
        uploadTransfer.bytesTransferred += chunk.length;
        uploadTransfer.completedChunks.add(chunkIndex);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Send chunk error: $e');
    }
  }

  /// Received a chunk from a seeder
  void _handleChunkResponse(String fromVip, String payload) {
    // Format: {hash}|{chunkIndex}|{base64data}
    final firstPipe = payload.indexOf('|');
    if (firstPipe == -1) return;
    final secondPipe = payload.indexOf('|', firstPipe + 1);
    if (secondPipe == -1) return;

    final fileHash = payload.substring(0, firstPipe);
    final chunkIndex =
        int.tryParse(payload.substring(firstPipe + 1, secondPipe));
    if (chunkIndex == null) return;

    final chunkB64 = payload.substring(secondPipe + 1);

    Uint8List chunkData;
    try {
      chunkData = base64Decode(chunkB64);
    } catch (_) {
      return;
    }

    final transfer = _transfers
        .where((t) =>
            t.fileHash == fileHash &&
            t.direction == TransferDirection.download)
        .firstOrNull;
    if (transfer == null || transfer.status == TransferStatus.cancelled) return;

    // Store chunk
    _chunkBuffers[fileHash] ??= {};
    _chunkBuffers[fileHash]![chunkIndex] = chunkData;
    transfer.completedChunks.add(chunkIndex);
    transfer.bytesTransferred += chunkData.length;

    // Remove from pending
    _pendingChunks[fileHash]?.remove(chunkIndex);

    // Request next pending chunk from this seeder (keep pipeline full)
    final remaining = _pendingChunks[fileHash];
    if (remaining != null && remaining.isNotEmpty) {
      final nextChunk = remaining.first;
      _sendChunkRequest(fromVip, fileHash, nextChunk);
    }

    // Check if all chunks received
    if (transfer.completedChunks.length >= transfer.totalChunks) {
      _assembleFile(transfer);
    } else {
      notifyListeners();
    }
  }

  /// Assemble downloaded chunks into final file
  Future<void> _assembleFile(FileTransfer transfer) async {
    final chunks = _chunkBuffers[transfer.fileHash];
    if (chunks == null) {
      transfer.status = TransferStatus.failed;
      transfer.error = 'ไม่มีข้อมูล chunk';
      notifyListeners();
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory('${dir.path}/LocalVPN/Downloads');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }

      // Assemble in order
      final buffer = BytesBuilder();
      for (int i = 0; i < transfer.totalChunks; i++) {
        final chunk = chunks[i];
        if (chunk == null) {
          transfer.status = TransferStatus.failed;
          transfer.error = 'chunk $i หายไป';
          notifyListeners();
          return;
        }
        buffer.add(chunk);
      }

      final assembled = buffer.toBytes();

      // Verify hash
      final hash = sha256.convert(assembled).toString();
      if (hash != transfer.fileHash) {
        transfer.status = TransferStatus.failed;
        transfer.error = 'ไฟล์เสียหาย (hash ไม่ตรง)';
        notifyListeners();
        return;
      }

      // Save file
      final filePath = '${downloadDir.path}/${transfer.fileName}';
      await File(filePath).writeAsBytes(assembled);

      transfer.localPath = filePath;
      transfer.status = TransferStatus.completed;
      _chunkBuffers.remove(transfer.fileHash);
      _pendingChunks.remove(transfer.fileHash);

      // Become a seeder! (BitTorrent style)
      _localFilePaths[transfer.fileHash] = filePath;
      _registerAsSeeder(transfer.fileHash);

      notifyListeners();
    } catch (e) {
      transfer.status = TransferStatus.failed;
      transfer.error = 'บันทึกไฟล์ล้มเหลว: $e';
      notifyListeners();
    }
  }

  /// Register ourselves as seeder on the server
  Future<void> _registerAsSeeder(String fileHash) async {
    if (_networkSlug == null) return;

    try {
      await http
          .post(
            Uri.parse('$_baseUrl/files/seed'),
            headers: _headers,
            body: jsonEncode({
              ..._authBody,
              'file_hash': fileHash,
              'chunks_bitmap': 'all',
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Register seeder error: $e');
    }
  }

  /// Check if we have a file locally (are seeder)
  bool isSeeder(String fileHash) => _localFilePaths.containsKey(fileHash);

  @override
  void dispose() {
    _chunkBuffers.clear();
    _pendingChunks.clear();
    super.dispose();
  }
}
