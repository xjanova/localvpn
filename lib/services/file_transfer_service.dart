import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'p2p_service.dart';

/// File transfer state
enum TransferStatus { waiting, transferring, completed, failed, cancelled }

/// Direction of transfer
enum TransferDirection { upload, download }

/// A single file transfer (upload or download)
class FileTransfer {
  final String id;
  final String fileName;
  final int fileSize;
  final String fileHash;
  final TransferDirection direction;
  final String peerVirtualIp;
  final String peerDisplayName;
  TransferStatus status;
  int bytesTransferred;
  DateTime createdAt;
  String? localPath;
  String? error;

  // BitTorrent-style chunking
  final int chunkSize;
  int get totalChunks => (fileSize / chunkSize).ceil();
  final Set<int> completedChunks = {};
  double get progress =>
      totalChunks == 0 ? 0 : completedChunks.length / totalChunks;

  FileTransfer({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.fileHash,
    required this.direction,
    required this.peerVirtualIp,
    required this.peerDisplayName,
    this.status = TransferStatus.waiting,
    this.bytesTransferred = 0,
    this.localPath,
    this.error,
    this.chunkSize = 32768, // 32KB chunks
  }) : createdAt = DateTime.now();

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

/// File shared to the network (available for others to download)
class SharedFile {
  final String id;
  final String fileName;
  final int fileSize;
  final String fileHash;
  final String localPath;
  final String ownerVirtualIp;
  final String ownerDisplayName;
  final DateTime sharedAt;

  SharedFile({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.fileHash,
    required this.localPath,
    required this.ownerVirtualIp,
    required this.ownerDisplayName,
    DateTime? sharedAt,
  }) : sharedAt = sharedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'file_name': fileName,
        'file_size': fileSize,
        'file_hash': fileHash,
        'owner_virtual_ip': ownerVirtualIp,
        'owner_display_name': ownerDisplayName,
        'shared_at': sharedAt.toIso8601String(),
      };

  factory SharedFile.fromJson(Map<String, dynamic> json) => SharedFile(
        id: json['id'] as String,
        fileName: json['file_name'] as String,
        fileSize: json['file_size'] as int,
        fileHash: json['file_hash'] as String,
        localPath: '',
        ownerVirtualIp: json['owner_virtual_ip'] as String,
        ownerDisplayName: json['owner_display_name'] as String? ?? 'Unknown',
        sharedAt: json['shared_at'] != null
            ? DateTime.tryParse(json['shared_at'] as String)
            : null,
      );
}

/// BitTorrent-style file transfer service.
///
/// Protocol messages (sent via P2P UDP):
/// - LVPN_FILE_LIST_REQ     → request shared file list
/// - LVPN_FILE_LIST_RES:{}  → response with file list JSON
/// - LVPN_FILE_REQ:{id}     → request to download a file
/// - LVPN_FILE_ACK:{json}   → file transfer accepted, metadata
/// - LVPN_FILE_CHUNK:{json} → file chunk data
/// - LVPN_FILE_DONE:{id}    → transfer complete
/// - LVPN_FILE_CANCEL:{id}  → cancel transfer
class FileTransferService extends ChangeNotifier {
  static const String _msgPrefix = 'LVPN_FILE_';
  static const int _defaultChunkSize = 32768; // 32KB

  P2pService? _p2pService;
  String? _ownVirtualIp;
  String? _displayName;

  // Shared files (our files available to peers)
  final List<SharedFile> _sharedFiles = [];
  List<SharedFile> get sharedFiles => List.unmodifiable(_sharedFiles);

  // Remote files discovered from peers
  final List<SharedFile> _remoteFiles = [];
  List<SharedFile> get remoteFiles => List.unmodifiable(_remoteFiles);

  // Active transfers
  final List<FileTransfer> _transfers = [];
  List<FileTransfer> get transfers => List.unmodifiable(_transfers);

  // Chunk buffers for incoming files
  final Map<String, Map<int, Uint8List>> _chunkBuffers = {};

  // Pending file list requests
  final Set<String> _pendingListRequests = {};

  void configure({
    required P2pService p2pService,
    required String ownVirtualIp,
    required String displayName,
  }) {
    _p2pService = p2pService;
    _ownVirtualIp = ownVirtualIp;
    _displayName = displayName;
  }

  /// Share a file to the network
  Future<SharedFile?> shareFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes).toString();
    final id = hash.substring(0, 16);

    // Check if already shared
    if (_sharedFiles.any((f) => f.fileHash == hash)) return null;

    final shared = SharedFile(
      id: id,
      fileName: path.basename(filePath),
      fileSize: bytes.length,
      fileHash: hash,
      localPath: filePath,
      ownerVirtualIp: _ownVirtualIp ?? '',
      ownerDisplayName: _displayName ?? 'Unknown',
    );

    _sharedFiles.add(shared);
    notifyListeners();

    // Broadcast file availability to connected peers
    _broadcastFileList();

    return shared;
  }

  /// Remove a shared file
  void unshareFile(String fileId) {
    _sharedFiles.removeWhere((f) => f.id == fileId);
    notifyListeners();
    _broadcastFileList();
  }

  /// Request file list from a specific peer
  void requestFileList(String peerVirtualIp) {
    _pendingListRequests.add(peerVirtualIp);
    _sendMessage(peerVirtualIp, 'LIST_REQ', '');
  }

  /// Request file list from all connected peers
  void discoverFiles() {
    _remoteFiles.clear();
    final peers = _p2pService?.peers ?? {};
    for (final peer in peers.values) {
      requestFileList(peer.virtualIp);
    }
    notifyListeners();
  }

  /// Request to download a file from a peer
  Future<FileTransfer?> downloadFile(SharedFile remoteFile) async {
    final transfer = FileTransfer(
      id: remoteFile.id,
      fileName: remoteFile.fileName,
      fileSize: remoteFile.fileSize,
      fileHash: remoteFile.fileHash,
      direction: TransferDirection.download,
      peerVirtualIp: remoteFile.ownerVirtualIp,
      peerDisplayName: remoteFile.ownerDisplayName,
      chunkSize: _defaultChunkSize,
    );

    // Check for duplicate
    if (_transfers.any((t) =>
        t.id == transfer.id &&
        t.status == TransferStatus.transferring)) {
      return null;
    }

    _transfers.add(transfer);
    _chunkBuffers[transfer.id] = {};
    notifyListeners();

    // Send download request to peer
    _sendMessage(
      remoteFile.ownerVirtualIp,
      'REQ',
      remoteFile.id,
    );

    return transfer;
  }

  /// Cancel a transfer
  void cancelTransfer(String transferId) {
    final transfer = _transfers.where((t) => t.id == transferId).firstOrNull;
    if (transfer == null) return;

    transfer.status = TransferStatus.cancelled;
    _chunkBuffers.remove(transferId);

    _sendMessage(transfer.peerVirtualIp, 'CANCEL', transferId);
    notifyListeners();
  }

  /// Remove completed/failed/cancelled transfer from list
  void removeTransfer(String transferId) {
    _transfers.removeWhere((t) => t.id == transferId);
    _chunkBuffers.remove(transferId);
    notifyListeners();
  }

  /// Handle incoming P2P data for file transfer
  void handleMessage(String fromVirtualIp, Uint8List data) {
    final text = utf8.decode(data, allowMalformed: true);
    if (!text.startsWith(_msgPrefix)) return;

    final withoutPrefix = text.substring(_msgPrefix.length);
    final colonIndex = withoutPrefix.indexOf(':');

    String type;
    String payload;
    if (colonIndex == -1) {
      type = withoutPrefix;
      payload = '';
    } else {
      type = withoutPrefix.substring(0, colonIndex);
      payload = withoutPrefix.substring(colonIndex + 1);
    }

    switch (type) {
      case 'LIST_REQ':
        _handleListRequest(fromVirtualIp);
        break;
      case 'LIST_RES':
        _handleListResponse(fromVirtualIp, payload);
        break;
      case 'REQ':
        _handleFileRequest(fromVirtualIp, payload);
        break;
      case 'ACK':
        _handleFileAck(fromVirtualIp, payload);
        break;
      case 'CHUNK':
        _handleChunk(fromVirtualIp, payload);
        break;
      case 'DONE':
        _handleDone(fromVirtualIp, payload);
        break;
      case 'CANCEL':
        _handleCancel(fromVirtualIp, payload);
        break;
    }
  }

  // ==================== Protocol Handlers ====================

  void _handleListRequest(String fromVirtualIp) {
    final fileListJson = jsonEncode(
      _sharedFiles.map((f) => f.toJson()).toList(),
    );
    _sendMessage(fromVirtualIp, 'LIST_RES', fileListJson);
  }

  void _handleListResponse(String fromVirtualIp, String payload) {
    _pendingListRequests.remove(fromVirtualIp);

    try {
      final files = jsonDecode(payload) as List;
      // Remove old files from this peer
      _remoteFiles.removeWhere((f) => f.ownerVirtualIp == fromVirtualIp);

      for (final f in files) {
        _remoteFiles.add(SharedFile.fromJson(f as Map<String, dynamic>));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('File list parse error: $e');
    }
  }

  void _handleFileRequest(String fromVirtualIp, String fileId) {
    final file = _sharedFiles.where((f) => f.id == fileId).firstOrNull;
    if (file == null) return;

    // Create upload transfer
    final transfer = FileTransfer(
      id: file.id,
      fileName: file.fileName,
      fileSize: file.fileSize,
      fileHash: file.fileHash,
      direction: TransferDirection.upload,
      peerVirtualIp: fromVirtualIp,
      peerDisplayName: _getPeerName(fromVirtualIp),
      localPath: file.localPath,
      chunkSize: _defaultChunkSize,
    );
    transfer.status = TransferStatus.transferring;
    _transfers.add(transfer);
    notifyListeners();

    // Send ACK with metadata
    final ack = jsonEncode({
      'id': file.id,
      'file_name': file.fileName,
      'file_size': file.fileSize,
      'file_hash': file.fileHash,
      'chunk_size': _defaultChunkSize,
      'total_chunks': transfer.totalChunks,
    });
    _sendMessage(fromVirtualIp, 'ACK', ack);

    // Start sending chunks
    _sendFileChunks(transfer);
  }

  void _handleFileAck(String fromVirtualIp, String payload) {
    try {
      final meta = jsonDecode(payload) as Map<String, dynamic>;
      final fileId = meta['id'] as String;

      final transfer =
          _transfers.where((t) => t.id == fileId).firstOrNull;
      if (transfer != null) {
        transfer.status = TransferStatus.transferring;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('File ACK parse error: $e');
    }
  }

  void _handleChunk(String fromVirtualIp, String payload) {
    try {
      // Format: {id}|{chunkIndex}|{base64data}
      final parts = payload.split('|');
      if (parts.length < 3) return;

      final fileId = parts[0];
      final chunkIndex = int.parse(parts[1]);
      final chunkData = base64Decode(parts[2]);

      final transfer =
          _transfers.where((t) => t.id == fileId).firstOrNull;
      if (transfer == null || transfer.status == TransferStatus.cancelled) {
        return;
      }

      transfer.status = TransferStatus.transferring;

      // Store chunk
      _chunkBuffers[fileId] ??= {};
      _chunkBuffers[fileId]![chunkIndex] = chunkData;
      transfer.completedChunks.add(chunkIndex);
      transfer.bytesTransferred += chunkData.length;

      notifyListeners();
    } catch (e) {
      debugPrint('Chunk parse error: $e');
    }
  }

  void _handleDone(String fromVirtualIp, String fileId) {
    final transfer =
        _transfers.where((t) => t.id == fileId).firstOrNull;
    if (transfer == null) return;

    if (transfer.direction == TransferDirection.download) {
      // Assemble file from chunks
      _assembleFile(transfer);
    } else {
      transfer.status = TransferStatus.completed;
      notifyListeners();
    }
  }

  void _handleCancel(String fromVirtualIp, String fileId) {
    final transfer =
        _transfers.where((t) => t.id == fileId).firstOrNull;
    if (transfer == null) return;

    transfer.status = TransferStatus.cancelled;
    _chunkBuffers.remove(fileId);
    notifyListeners();
  }

  // ==================== Transfer Logic ====================

  Future<void> _sendFileChunks(FileTransfer transfer) async {
    if (transfer.localPath == null) return;

    final file = File(transfer.localPath!);
    if (!await file.exists()) {
      transfer.status = TransferStatus.failed;
      transfer.error = 'ไฟล์ไม่พบ';
      notifyListeners();
      return;
    }

    final bytes = await file.readAsBytes();
    final totalChunks = transfer.totalChunks;

    for (int i = 0; i < totalChunks; i++) {
      if (transfer.status == TransferStatus.cancelled) return;

      final start = i * transfer.chunkSize;
      final end = min(start + transfer.chunkSize, bytes.length);
      final chunk = bytes.sublist(start, end);

      final chunkPayload = '${transfer.id}|$i|${base64Encode(chunk)}';
      _sendMessage(transfer.peerVirtualIp, 'CHUNK', chunkPayload);

      transfer.completedChunks.add(i);
      transfer.bytesTransferred += chunk.length;

      // Throttle: small delay between chunks to avoid flooding
      if (i % 10 == 9) {
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    // Send done
    _sendMessage(transfer.peerVirtualIp, 'DONE', transfer.id);
    transfer.status = TransferStatus.completed;
    notifyListeners();
  }

  Future<void> _assembleFile(FileTransfer transfer) async {
    final chunks = _chunkBuffers[transfer.id];
    if (chunks == null) {
      transfer.status = TransferStatus.failed;
      transfer.error = 'ไม่มีข้อมูล chunk';
      notifyListeners();
      return;
    }

    try {
      // Get download directory
      final dir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory('${dir.path}/LocalVPN/Downloads');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }

      // Assemble chunks in order
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
      final file = File(filePath);
      await file.writeAsBytes(assembled);

      transfer.localPath = filePath;
      transfer.status = TransferStatus.completed;
      _chunkBuffers.remove(transfer.id);
      notifyListeners();
    } catch (e) {
      transfer.status = TransferStatus.failed;
      transfer.error = 'บันทึกไฟล์ล้มเหลว: $e';
      notifyListeners();
    }
  }

  // ==================== Helpers ====================

  void _sendMessage(String targetVirtualIp, String type, String payload) {
    final message = utf8.encode('$_msgPrefix$type:$payload');
    _p2pService?.sendToPeer(targetVirtualIp, Uint8List.fromList(message));
  }

  void _broadcastFileList() {
    final peers = _p2pService?.peers ?? {};
    final fileListJson = jsonEncode(
      _sharedFiles.map((f) => f.toJson()).toList(),
    );
    for (final peer in peers.values) {
      _sendMessage(peer.virtualIp, 'LIST_RES', fileListJson);
    }
  }

  String _getPeerName(String virtualIp) {
    final peers = _p2pService?.peers ?? {};
    return peers[virtualIp]?.displayName ?? virtualIp;
  }

  @override
  void dispose() {
    _chunkBuffers.clear();
    super.dispose();
  }
}
