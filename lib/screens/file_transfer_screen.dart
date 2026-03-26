import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:open_file/open_file.dart';

import '../services/file_transfer_service.dart';
import '../services/p2p_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';

class FileTransferScreen extends StatefulWidget {
  final FileTransferService fileTransferService;
  final P2pService p2pService;

  const FileTransferScreen({
    super.key,
    required this.fileTransferService,
    required this.p2pService,
  });

  @override
  State<FileTransferScreen> createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    widget.fileTransferService.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.dispose();
    widget.fileTransferService.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _pickAndShareFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) return;

    final shared = await widget.fileTransferService.shareFile(filePath);

    if (!mounted) return;

    if (shared != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('แชร์ไฟล์ "${shared.fileName}" แล้ว'),
          backgroundColor: AppColors.success.withValues(alpha: 0.9),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'ส่งไฟล์ P2P',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                // Discover button
                IconButton(
                  onPressed: () {
                    widget.fileTransferService.discoverFiles();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('กำลังค้นหาไฟล์จากอุปกรณ์อื่น...'),
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.9),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.refresh, color: AppColors.primary),
                  tooltip: 'ค้นหาไฟล์',
                ),
              ],
            ),
          ).animate().fadeIn(duration: 300.ms),
          const SizedBox(height: 8),

          // P2P status banner
          if (!widget.p2pService.isActive)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.3),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: AppColors.warning, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'เชื่อมต่อเครือข่ายก่อนเพื่อส่งไฟล์ P2P',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 8),

          // Tabs
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              indicator: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              labelColor: Colors.white,
              unselectedLabelColor: AppColors.textMuted,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.cloud_upload, size: 16),
                      const SizedBox(width: 4),
                      const Text('แชร์'),
                      if (widget.fileTransferService.sharedFiles.isNotEmpty)
                        _buildBadge(
                            widget.fileTransferService.sharedFiles.length),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.cloud_download, size: 16),
                      const SizedBox(width: 4),
                      const Text('ดาวน์โหลด'),
                      if (widget.fileTransferService.remoteFiles.isNotEmpty)
                        _buildBadge(
                            widget.fileTransferService.remoteFiles.length),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.swap_vert, size: 16),
                      const SizedBox(width: 4),
                      const Text('กำลังส่ง'),
                      if (widget.fileTransferService.transfers.isNotEmpty)
                        _buildBadge(
                            widget.fileTransferService.transfers.length),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSharedTab(),
                _buildRemoteTab(),
                _buildTransfersTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(int count) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: const TextStyle(fontSize: 10),
      ),
    );
  }

  // ==================== Shared Files Tab ====================
  Widget _buildSharedTab() {
    final files = widget.fileTransferService.sharedFiles;

    return Column(
      children: [
        // Share button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SizedBox(
            width: double.infinity,
            child: NeonButton(
              text: 'เลือกไฟล์เพื่อแชร์',
              icon: Icons.add,
              onPressed: _pickAndShareFile,
            ),
          ),
        ),
        const SizedBox(height: 12),

        if (files.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open,
                      size: 64,
                      color: AppColors.textMuted.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  const Text(
                    'ยังไม่ได้แชร์ไฟล์',
                    style: TextStyle(
                        fontSize: 16, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'กดปุ่มด้านบนเพื่อเลือกไฟล์แชร์ให้อุปกรณ์อื่น',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: files.length,
              itemBuilder: (context, index) => _buildSharedFileCard(files[index]),
            ),
          ),
      ],
    );
  }

  Widget _buildSharedFileCard(SharedFile file) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        borderColor: AppColors.primary.withValues(alpha: 0.2),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                _getFileIcon(file.fileName),
                color: AppColors.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _formatSize(file.fileSize),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () {
                widget.fileTransferService.unshareFile(file.id);
              },
              icon: const Icon(Icons.close, color: AppColors.error, size: 20),
              tooltip: 'เลิกแชร์',
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Remote Files Tab ====================
  Widget _buildRemoteTab() {
    final files = widget.fileTransferService.remoteFiles;

    if (files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 64,
                color: AppColors.textMuted.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            const Text(
              'ไม่พบไฟล์จากอุปกรณ์อื่น',
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            NeonButton(
              text: 'ค้นหาไฟล์',
              icon: Icons.refresh,
              outlined: true,
              onPressed: () => widget.fileTransferService.discoverFiles(),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: files.length,
      itemBuilder: (context, index) => _buildRemoteFileCard(files[index]),
    );
  }

  Widget _buildRemoteFileCard(SharedFile file) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        borderColor: AppColors.secondary.withValues(alpha: 0.2),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                _getFileIcon(file.fileName),
                color: AppColors.secondary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${_formatSize(file.fileSize)} • ${file.ownerDisplayName}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () {
                widget.fileTransferService.downloadFile(file);
                _tabController.animateTo(2); // Switch to transfers tab
              },
              icon: const Icon(Icons.download,
                  color: AppColors.primary, size: 22),
              tooltip: 'ดาวน์โหลด',
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Transfers Tab ====================
  Widget _buildTransfersTab() {
    final transfers = widget.fileTransferService.transfers;

    if (transfers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert,
                size: 64,
                color: AppColors.textMuted.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            const Text(
              'ไม่มีการถ่ายโอนไฟล์',
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: transfers.length,
      itemBuilder: (context, index) => _buildTransferCard(transfers[index]),
    );
  }

  Widget _buildTransferCard(FileTransfer transfer) {
    final isUpload = transfer.direction == TransferDirection.upload;
    final color = isUpload ? AppColors.primary : AppColors.secondary;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (transfer.status) {
      case TransferStatus.waiting:
        statusColor = AppColors.warning;
        statusText = 'รอ...';
        statusIcon = Icons.hourglass_empty;
        break;
      case TransferStatus.transferring:
        statusColor = color;
        statusText = '${(transfer.progress * 100).toStringAsFixed(0)}%';
        statusIcon = isUpload ? Icons.upload : Icons.download;
        break;
      case TransferStatus.completed:
        statusColor = AppColors.success;
        statusText = 'เสร็จ';
        statusIcon = Icons.check_circle;
        break;
      case TransferStatus.failed:
        statusColor = AppColors.error;
        statusText = 'ล้มเหลว';
        statusIcon = Icons.error;
        break;
      case TransferStatus.cancelled:
        statusColor = AppColors.textMuted;
        statusText = 'ยกเลิก';
        statusIcon = Icons.cancel;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        borderColor: statusColor.withValues(alpha: 0.2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        transfer.fileName,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${isUpload ? "→" : "←"} ${transfer.peerDisplayName} • '
                        '${transfer.fileSizeFormatted}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ],
            ),

            // Progress bar
            if (transfer.status == TransferStatus.transferring) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: transfer.progress,
                  backgroundColor: AppColors.surfaceLight,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    transfer.speedFormatted,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMuted),
                  ),
                  Text(
                    '${transfer.completedChunks.length}/${transfer.totalChunks} chunks',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],

            // Error message
            if (transfer.error != null) ...[
              const SizedBox(height: 6),
              Text(
                transfer.error!,
                style: const TextStyle(fontSize: 12, color: AppColors.error),
              ),
            ],

            // Actions
            if (transfer.status == TransferStatus.transferring ||
                transfer.status == TransferStatus.waiting) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () =>
                      widget.fileTransferService.cancelTransfer(transfer.id),
                  icon: const Icon(Icons.cancel, size: 16),
                  label: const Text('ยกเลิก'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.error,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],

            // Open file / Remove
            if (transfer.status == TransferStatus.completed ||
                transfer.status == TransferStatus.failed ||
                transfer.status == TransferStatus.cancelled) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (transfer.status == TransferStatus.completed &&
                      transfer.localPath != null &&
                      transfer.direction == TransferDirection.download)
                    TextButton.icon(
                      onPressed: () =>
                          OpenFile.open(transfer.localPath!),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('เปิดไฟล์'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () =>
                        widget.fileTransferService.removeTransfer(transfer.id),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('ลบ'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textMuted,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== Helpers ====================

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'bmp' => Icons.image,
      'mp4' || 'avi' || 'mov' || 'mkv' || 'wmv' => Icons.movie,
      'mp3' || 'wav' || 'flac' || 'aac' || 'ogg' => Icons.music_note,
      'pdf' => Icons.picture_as_pdf,
      'doc' || 'docx' => Icons.description,
      'xls' || 'xlsx' => Icons.table_chart,
      'ppt' || 'pptx' => Icons.slideshow,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.archive,
      'apk' => Icons.android,
      'txt' || 'md' || 'log' => Icons.text_snippet,
      _ => Icons.insert_drive_file,
    };
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
