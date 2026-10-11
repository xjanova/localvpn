import 'dart:async';
import 'dart:collection';
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

/// SHA-256 of a file, streamed so a multi-GB file never sits in memory
/// (top-level for compute()).
Future<String> _computeFileHash(String filePath) async {
  final digest = await sha256.bind(File(filePath).openRead()).first;
  return digest.toString();
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

  // Each seeder gets a few chunk requests at a time; a chunk that doesn't
  // arrive in time is asked for again, from the next seeder.
  static const int _perSeederWindow = 6;
  static const int _maxWindow = 24;
  static const Duration _chunkTimeout = Duration(seconds: 6);
  static const int _maxChunkAttempts = 8;
  static const int _maxServingPerPeer = 16;

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

  // Downloads in progress, by file hash
  final Map<String, _Download> _downloads = {};
  Timer? _ticker;
  Timer? _notifyTimer;

  // Chunk reads in flight per requesting peer (seeder side)
  final Map<String, int> _servingFor = {};

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
    if (slug != _networkSlug) {
      // The seeders were members of the old network; they can't be reached.
      for (final d in _downloads.values.toList()) {
        _failDownload(d, 'ย้ายวงแล้ว — การดาวน์โหลดถูกหยุด',
            status: TransferStatus.cancelled);
      }
    }
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
    // Already downloading (or queued)?
    if (_transfers.any((t) =>
        t.fileHash == remoteFile.fileHash &&
        (t.status == TransferStatus.transferring ||
            t.status == TransferStatus.waiting))) {
      return null;
    }
    // A retry after a failed/cancelled attempt replaces that attempt, so
    // incoming chunks (matched by hash) land on the new transfer.
    _transfers.removeWhere((t) =>
        t.fileHash == remoteFile.fileHash &&
        t.direction == TransferDirection.download &&
        (t.status == TransferStatus.failed ||
            t.status == TransferStatus.cancelled));

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

        if (transfer.status == TransferStatus.cancelled) return transfer;
        transfer.status = TransferStatus.transferring;
        transfer.activeSeeders
            .addAll(seeders.map((s) => s.virtualIp));
        notifyListeners();

        // Request chunks from multiple seeders
        await _startDownload(transfer, seeders);
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

  /// Opens the .part file and starts asking the seeders for chunks.
  Future<void> _startDownload(
      FileTransfer transfer, List<FileSeeder> seeders) async {
    final String partPath;
    final RandomAccessFile file;
    try {
      final downloadDir = debugDownloadDirectory ??
          Directory(path.join((await getApplicationDocumentsDirectory()).path,
              'LocalVPN', 'Downloads'));
      await downloadDir.create(recursive: true);
      partPath = path.join(
          downloadDir.path, '.${transfer.fileHash.substring(0, 16)}.part');
      file = await File(partPath).open(mode: FileMode.write);
    } catch (e) {
      debugPrint('Download file open error: $e');
      transfer.status = TransferStatus.failed;
      transfer.error = 'สร้างไฟล์ในเครื่องไม่ได้ — ตรวจสอบพื้นที่ว่าง';
      notifyListeners();
      return;
    }
    if (transfer.status != TransferStatus.transferring) {
      await file.close();
      await _deleteQuietly(partPath);
      return;
    }
    final d = _Download(
      transfer,
      [for (final s in seeders) s.virtualIp],
      partPath,
      file,
    );
    for (var i = 0; i < transfer.totalChunks; i++) {
      if (!transfer.completedChunks.contains(i)) d.todo.add(i);
    }
    _downloads[transfer.fileHash] = d;
    if (transfer.totalChunks == 0) {
      unawaited(_finishDownload(d));
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _pump(d);
  }

  /// Keeps each seeder's window full.
  void _pump(_Download d) {
    final t = d.transfer;
    if (t.status != TransferStatus.transferring) return;
    final window = min(_maxWindow, _perSeederWindow * d.seeders.length);
    while (d.inFlight.length < window && d.todo.isNotEmpty) {
      final chunk = d.todo.removeFirst();
      if (t.completedChunks.contains(chunk) || d.inFlight.containsKey(chunk)) {
        continue;
      }
      final seeder = _pickSeeder(d, avoid: d.lastSeeder[chunk]);
      if (seeder == null) {
        d.todo.addFirst(chunk);
        return;
      }
      d.inFlight[chunk] = _InFlight(seeder, DateTime.now());
      d.lastSeeder[chunk] = seeder;
      _sendChunkRequest(seeder, t.fileHash, chunk);
    }
  }

  /// The seeder with the most room, preferring ones we have a path to and,
  /// for a retry, another one than last time.
  String? _pickSeeder(_Download d, {String? avoid}) {
    String? best;
    var bestScore = -1 << 30;
    for (final vip in d.seeders) {
      final busy = d.inFlight.values.where((f) => f.seeder == vip).length;
      if (busy >= _perSeederWindow) continue;
      final path = _p2pService?.pathOf(vip);
      var score = -busy * 10;
      if (path == P2pPath.direct) score += 100;
      if (path == P2pPath.relay) score += 50;
      if (vip == avoid && d.seeders.length > 1) score -= 200;
      if (score > bestScore) {
        bestScore = score;
        best = vip;
      }
    }
    return best;
  }

  /// Once a second: chunks that didn't arrive in time go back in the queue.
  void _tick() {
    final now = DateTime.now();
    for (final d in _downloads.values.toList()) {
      if (d.transfer.status != TransferStatus.transferring || d.finishing) {
        continue;
      }
      for (final e in d.inFlight.entries.toList()) {
        if (now.difference(e.value.sentAt) < _chunkTimeout) continue;
        d.inFlight.remove(e.key);
        final attempts = (d.attempts[e.key] ?? 0) + 1;
        d.attempts[e.key] = attempts;
        if (attempts >= _maxChunkAttempts) {
          _failDownload(
              d, 'เพื่อนที่แชร์ไฟล์ไม่ตอบ — ลองดาวน์โหลดใหม่อีกครั้ง');
          break;
        }
        d.todo.addFirst(e.key);
      }
      _pump(d);
    }
    if (_downloads.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Send a chunk request to a specific peer
  void _sendChunkRequest(String peerVip, String fileHash, int chunkIndex) {
    final msg = utf8.encode('LVPN_FILE_CHUNK_REQ:$fileHash|$chunkIndex');
    _p2pService?.sendFileMessage(peerVip, Uint8List.fromList(msg));
  }

  /// Cancel a transfer
  void cancelTransfer(String fileHash) {
    final transfer =
        _transfers.where((t) => t.fileHash == fileHash).firstOrNull;
    if (transfer == null) return;

    final d = _downloads[fileHash];
    if (d != null) {
      _failDownload(d, null, status: TransferStatus.cancelled);
    } else {
      transfer.status = TransferStatus.cancelled;
      _notifySeedersCancelled(transfer);
    }
    notifyListeners();
  }

  /// Remove transfer from list
  void removeTransfer(String fileHash) {
    final d = _downloads[fileHash];
    if (d != null) {
      _failDownload(d, null, status: TransferStatus.cancelled);
    }
    _transfers.removeWhere((t) => t.fileHash == fileHash);
    notifyListeners();
  }

  void _notifySeedersCancelled(FileTransfer transfer) {
    for (final vip in transfer.activeSeeders) {
      final msg = utf8.encode('LVPN_FILE_CANCEL:${transfer.fileHash}');
      _p2pService?.sendFileMessage(vip, Uint8List.fromList(msg));
    }
  }

  /// Stops a download, deletes its .part file and records why.
  void _failDownload(
    _Download d,
    String? error, {
    TransferStatus status = TransferStatus.failed,
  }) {
    final t = d.transfer;
    if (_downloads[t.fileHash] == d) _downloads.remove(t.fileHash);
    t.status = status;
    t.error = error;
    d.todo.clear();
    d.inFlight.clear();
    _notifySeedersCancelled(t);
    d.writes = d.writes.then((_) async {
      try {
        await d.file.close();
      } catch (_) {}
      await _deleteQuietly(d.partPath);
    });
    notifyListeners();
  }

  static Future<void> _deleteQuietly(String filePath) async {
    try {
      await File(filePath).delete();
    } catch (_) {}
  }

  // ==================== P2P Message Handling ====================

  /// Handle incoming P2P file message
  void handleMessage(String fromVirtualIp, Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);

    if (text.startsWith('LVPN_FILE_CHUNK_REQ:')) {
      _handleChunkRequest(fromVirtualIp, text.substring(20));
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
    if (chunkIndex == null || chunkIndex < 0) return;

    final filePath = _localFilePaths[fileHash];
    if (filePath == null) return;

    // A peer gets a bounded number of reads at a time.
    final serving = _servingFor[fromVip] ?? 0;
    if (serving >= _maxServingPerPeer) return;
    _servingFor[fromVip] = serving + 1;
    _sendChunkData(fromVip, fileHash, chunkIndex, filePath).whenComplete(() {
      final n = (_servingFor[fromVip] ?? 1) - 1;
      if (n <= 0) {
        _servingFor.remove(fromVip);
      } else {
        _servingFor[fromVip] = n;
      }
    });
  }

  /// Read a chunk from local file and send to requester
  Future<void> _sendChunkData(
    String targetVip,
    String fileHash,
    int chunkIndex,
    String filePath,
  ) async {
    RandomAccessFile? raf;
    try {
      raf = await File(filePath).open();
      final fileLength = await raf.length();
      final start = chunkIndex * _defaultChunkSize;
      if (start >= fileLength) return;
      await raf.setPosition(start);
      final end = min(start + _defaultChunkSize, fileLength);
      final chunk = await raf.read(end - start);

      final chunkB64 = base64Encode(chunk);
      final msg =
          utf8.encode('LVPN_FILE_CHUNK_RES:$fileHash|$chunkIndex|$chunkB64');
      await _p2pService?.sendFileMessage(targetVip, Uint8List.fromList(msg));

      // Track upload
      final uploadTransfer = _transfers
          .where((t) =>
              t.fileHash == fileHash &&
              t.direction == TransferDirection.upload)
          .firstOrNull;
      if (uploadTransfer != null) {
        uploadTransfer.bytesTransferred += chunk.length;
        uploadTransfer.completedChunks.add(chunkIndex);
        _notifySoon();
      }
    } catch (e) {
      debugPrint('Send chunk error: $e');
    } finally {
      await raf?.close();
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
    final d = _downloads[fileHash];
    if (chunkIndex == null || d == null || d.finishing) return;
    final t = d.transfer;
    if (t.status != TransferStatus.transferring ||
        chunkIndex < 0 ||
        chunkIndex >= t.totalChunks ||
        t.completedChunks.contains(chunkIndex) ||
        !d.seeders.contains(fromVip)) {
      return;
    }

    Uint8List chunkData;
    try {
      chunkData = base64Decode(payload.substring(secondPipe + 1));
    } catch (_) {
      return;
    }
    final expected = chunkIndex < t.totalChunks - 1
        ? t.chunkSize
        : t.fileSize - t.chunkSize * (t.totalChunks - 1);
    if (chunkData.length != expected) return; // asked again on timeout

    t.completedChunks.add(chunkIndex);
    t.bytesTransferred += chunkData.length;
    d.inFlight.remove(chunkIndex);
    d.writes = d.writes.then((_) async {
      await d.file.setPosition(chunkIndex * t.chunkSize);
      await d.file.writeFrom(chunkData);
    }).catchError((Object e) {
      debugPrint('Chunk write error: $e');
      if (_downloads[fileHash] == d) {
        _failDownload(d, 'บันทึกไฟล์ไม่ได้ — ตรวจสอบพื้นที่ว่าง');
      }
    });

    if (t.completedChunks.length >= t.totalChunks) {
      unawaited(_finishDownload(d));
    } else {
      _pump(d);
      _notifySoon();
    }
  }

  /// All chunks are on disk: check the hash, then give the file its name.
  Future<void> _finishDownload(_Download d) async {
    if (d.finishing) return;
    d.finishing = true;
    final t = d.transfer;
    try {
      await d.writes;
      if (t.status != TransferStatus.transferring) return;
      await d.file.flush();
      await d.file.close();

      final hash = await compute(_computeFileHash, d.partPath);
      if (_downloads[t.fileHash] != d) return; // cancelled meanwhile
      if (hash != t.fileHash) {
        _downloads.remove(t.fileHash);
        await _deleteQuietly(d.partPath);
        t.status = TransferStatus.failed;
        t.error = 'ไฟล์เสียหาย (hash ไม่ตรง) — ลองดาวน์โหลดใหม่';
        notifyListeners();
        return;
      }

      // The name comes from whoever shared it: keep only a safe base name
      // (no "..\\" escapes, no drive or device names) and never overwrite
      // an existing file.
      final filePath = await _uniquePath(
          path.dirname(d.partPath), _safeFileName(t.fileName));
      await File(d.partPath).rename(filePath);
      _downloads.remove(t.fileHash);

      t.localPath = filePath;
      t.status = TransferStatus.completed;

      // Become a seeder! (BitTorrent style)
      _localFilePaths[t.fileHash] = filePath;
      _registerAsSeeder(t.fileHash);

      notifyListeners();
    } catch (e) {
      debugPrint('Finish download error: $e');
      _downloads.remove(t.fileHash);
      await _deleteQuietly(d.partPath);
      t.status = TransferStatus.failed;
      t.error = 'บันทึกไฟล์ล้มเหลว — ตรวจสอบพื้นที่ว่างแล้วลองใหม่';
      notifyListeners();
    }
  }

  /// Progress updates at most five times a second, not once per chunk.
  void _notifySoon() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 200), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  static const _reservedNames = {
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };

  /// A file name that cannot leave the download folder on any platform.
  static String _safeFileName(String raw) {
    var name = raw.split(RegExp(r'[\\/]')).last;
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_').trim();
    name = name.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    if (name.isEmpty) name = 'file';
    final stem = name.split('.').first.toLowerCase();
    if (_reservedNames.contains(stem)) name = '_$name';
    if (name.length > 180) {
      final ext = path.extension(name);
      name = name.substring(0, 180 - ext.length) + ext;
    }
    return name;
  }

  /// "dir/name.ext", or "dir/name (2).ext" … when the name is taken.
  static Future<String> _uniquePath(String dir, String name) async {
    var candidate = path.join(dir, name);
    final ext = path.extension(name);
    final stem = name.substring(0, name.length - ext.length);
    var n = 2;
    while (await File(candidate).exists()) {
      candidate = path.join(dir, '$stem ($n)$ext');
      n++;
    }
    return candidate;
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

  // ── Tests only ──
  @visibleForTesting
  Directory? debugDownloadDirectory;

  @visibleForTesting
  void debugSeedLocalFile(String fileHash, String filePath) =>
      _localFilePaths[fileHash] = filePath;

  /// [downloadFile] without the server: the seeders are given.
  @visibleForTesting
  Future<FileTransfer> debugDownloadFrom(
      SharedFile file, List<String> seeders) async {
    final transfer = FileTransfer(
      fileHash: file.fileHash,
      fileName: file.fileName,
      fileSize: file.fileSize,
      direction: TransferDirection.download,
      peerDisplayName: '${seeders.length} seeders',
      chunkSize: file.chunkSize,
      totalChunks: file.totalChunks,
    )..status = TransferStatus.transferring;
    _transfers.add(transfer);
    await _startDownload(transfer, [
      for (final vip in seeders) FileSeeder(virtualIp: vip, displayName: vip),
    ]);
    return transfer;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _notifyTimer?.cancel();
    for (final d in _downloads.values) {
      d.file.close().catchError((_) => d.file);
    }
    _downloads.clear();
    _p2pService = null;
    super.dispose();
  }
}

class _InFlight {
  _InFlight(this.seeder, this.sentAt);
  final String seeder;
  final DateTime sentAt;
}

/// One download: chunks still to ask for, chunks asked for, the .part file.
class _Download {
  _Download(this.transfer, this.seeders, this.partPath, this.file);

  final FileTransfer transfer;
  final List<String> seeders;
  final String partPath;
  final RandomAccessFile file;
  final Queue<int> todo = Queue();
  final Map<int, _InFlight> inFlight = {};
  final Map<int, int> attempts = {};
  final Map<int, String> lastSeeder = {};

  /// Writes run one after another (a RandomAccessFile takes one at a time).
  Future<void> writes = Future.value();
  bool finishing = false;
}
