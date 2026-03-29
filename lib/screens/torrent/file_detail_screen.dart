import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

class FileDetailScreen extends StatefulWidget {
  final TorrentService torrentService;
  final int fileId;
  final BtFile? initialFile;

  const FileDetailScreen({
    super.key,
    required this.torrentService,
    required this.fileId,
    this.initialFile,
  });

  @override
  State<FileDetailScreen> createState() => _FileDetailScreenState();
}

class _FileDetailScreenState extends State<FileDetailScreen> {
  BtFile? _file;
  List<BtSeeder> _seeders = [];
  bool _isLoading = true;

  bool _isRegistering = false;

  @override
  void initState() {
    super.initState();
    _file = widget.initialFile;
    widget.torrentService.addListener(_onServiceChanged);
    _loadDetail();
  }

  @override
  void dispose() {
    widget.torrentService.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDetail() async {
    setState(() => _isLoading = true);

    final results = await Future.wait([
      widget.torrentService.fetchFileDetail(widget.fileId),
      widget.torrentService.fetchSeeders(widget.fileId),
    ]);

    if (mounted) {
      setState(() {
        _file = results[0] as BtFile? ?? _file;
        _seeders = results[1] as List<BtSeeder>;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              Expanded(
                child: _isLoading && _file == null
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary),
                      )
                    : _file == null
                        ? const Center(
                            child: Text(
                              'ไม่พบไฟล์',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          )
                        : _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios,
                color: AppColors.primary, size: 20),
            onPressed: () {
              SoundService().play(SfxType.swoosh);
              Navigator.pop(context);
            },
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Text(
              'รายละเอียดไฟล์',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    ).animate().slideY(begin: -0.3, end: 0, duration: 400.ms);
  }

  Widget _buildContent() {
    final file = _file!;

    return RefreshIndicator(
      onRefresh: _loadDetail,
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File info card
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Thumbnail
                  if (file.thumbnailUrl != null)
                    Container(
                      width: double.infinity,
                      height: 180,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(12),
                        image: !file.thumbnailUrl!.startsWith('data:')
                            ? DecorationImage(
                                image: NetworkImage(file.thumbnailUrl!),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                    ),

                  // Title / File name
                  Text(
                    file.displayTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (file.title != null && file.title!.isNotEmpty && file.title != file.fileName) ...[
                    const SizedBox(height: 4),
                    Text(
                      file.fileName,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 12),

                  // Stats row
                  Row(
                    children: [
                      _buildStatBadge(
                        Icons.storage,
                        file.fileSizeFormatted,
                        AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      _buildStatBadge(
                        Icons.download,
                        '${file.downloadCount} ดาวน์โหลด',
                        AppColors.success,
                      ),
                      const SizedBox(width: 8),
                      _buildStatBadge(
                        Icons.people,
                        '${file.onlineSeedersCount} seeders',
                        file.onlineSeedersCount > 0
                            ? AppColors.success
                            : AppColors.error,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Description
                  if (file.description != null &&
                      file.description!.isNotEmpty) ...[
                    const Text(
                      'รายละเอียด',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      file.description!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Meta info
                  _buildMetaRow('ผู้อัพโหลด',
                      file.uploaderDisplayName ?? 'Unknown'),
                  if (file.chunkSize != null)
                    _buildMetaRow('Chunk Size', '${file.chunkSize} bytes'),
                  if (file.totalChunks != null)
                    _buildMetaRow('Total Chunks', '${file.totalChunks}'),
                  _buildMetaRow('Hash', file.fileHash.length >= 16
                    ? '${file.fileHash.substring(0, 16)}...'
                    : file.fileHash),
                  if (file.category != null)
                    _buildMetaRow('หมวดหมู่', file.category!.name),
                  if (file.createdAt != null)
                    _buildMetaRow(
                      'อัพโหลดเมื่อ',
                      '${file.createdAt!.day}/${file.createdAt!.month}/${file.createdAt!.year}',
                    ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 100.ms),

            const SizedBox(height: 16),

            // Copy hash button
            GlassCard(
              onTap: () {
                Clipboard.setData(ClipboardData(text: file.fileHash));
                SoundService().play(SfxType.coin);
                HapticFeedback.lightImpact();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('คัดลอก File Hash แล้ว'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              padding: const EdgeInsets.all(14),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.copy, color: AppColors.primary, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'คัดลอก File Hash',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 200.ms),

            const SizedBox(height: 12),

            // Download / Seed action
            _buildDownloadSeedCard(file),

            const SizedBox(height: 12),

            // Copy Magnet Link
            GlassCard(
              onTap: () {
                final magnetParts = <String>[
                  'hash:${file.fileHash}',
                  'name:${file.fileName}',
                ];
                for (final seeder in _seeders.where((s) => s.isOnline)) {
                  if (seeder.publicIp != null && seeder.publicPort != null) {
                    magnetParts.add('peer:${seeder.publicIp}:${seeder.publicPort}');
                  }
                }
                final magnetLink = 'magnet:?${magnetParts.join('&')}';
                Clipboard.setData(ClipboardData(text: magnetLink));
                SoundService().play(SfxType.coin);
                HapticFeedback.lightImpact();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('คัดลอก Magnet Link แล้ว'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              padding: const EdgeInsets.all(14),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.link, color: AppColors.secondary, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'คัดลอก Magnet Link',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondary,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 250.ms),

            const SizedBox(height: 20),

            // Seeders section
            const Text(
              'Seeders',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ).animate().fadeIn(duration: 300.ms, delay: 250.ms),
            const SizedBox(height: 12),

            if (_seeders.isEmpty)
              GlassCard(
                child: const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Icon(Icons.cloud_off,
                            color: AppColors.textMuted, size: 40),
                        SizedBox(height: 8),
                        Text(
                          'ไม่มี seeder ออนไลน์',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ).animate().fadeIn(duration: 400.ms, delay: 300.ms)
            else
              ...List.generate(_seeders.length, (index) {
                final seeder = _seeders[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    padding: const EdgeInsets.all(12),
                    borderColor: seeder.isOnline
                        ? AppColors.success.withValues(alpha: 0.2)
                        : AppColors.cardBorder,
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: seeder.isOnline
                                ? AppColors.success.withValues(alpha: 0.1)
                                : AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            seeder.isOnline
                                ? Icons.cloud_done
                                : Icons.cloud_off,
                            color: seeder.isOnline
                                ? AppColors.success
                                : AppColors.textMuted,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                seeder.displayName ?? seeder.machineId,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              if (seeder.publicIp != null &&
                                  seeder.publicPort != null)
                                Text(
                                  '${seeder.publicIp}:${seeder.publicPort}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              Text(
                                seeder.machineId,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: AppColors.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                seeder.isOnline ? 'ออนไลน์' : 'ออฟไลน์',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: seeder.isOnline
                                      ? AppColors.success
                                      : AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (seeder.chunksBitmap == 'all')
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color:
                                  AppColors.success.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Full',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                )
                    .animate()
                    .fadeIn(
                      duration: 300.ms,
                      delay: (300 + index.clamp(0, 10) * 50).ms,
                    )
                    .slideX(begin: 0.05, end: 0);
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadSeedCard(BtFile file) {
    final onlineSeeders = _seeders.where((s) => s.isOnline).toList();
    final hasOnlineSeeders = onlineSeeders.isNotEmpty;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderColor: hasOnlineSeeders
          ? AppColors.success.withValues(alpha: 0.3)
          : AppColors.cardBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Download button (via server relay)
          if (hasOnlineSeeders && !widget.torrentService.isDownloadingFile)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final path = await widget.torrentService.downloadFile(file, onlineSeeders);
                    if (!mounted) return;
                    if (path != null) {
                      SoundService().play(SfxType.coin);
                      HapticFeedback.heavyImpact();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('ดาวน์โหลดสำเร็จ: ${file.displayTitle}'),
                          backgroundColor: AppColors.success,
                        ),
                      );
                      _loadDetail();
                    } else if (widget.torrentService.downloadError != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(widget.torrentService.downloadError!),
                          backgroundColor: AppColors.error,
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.download, color: Colors.white, size: 20),
                  label: Text('ดาวน์โหลด (${onlineSeeders.length} seeders)'),
                ),
              ),
            ),

          // Download progress
          if (widget.torrentService.isDownloadingFile)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: widget.torrentService.downloadProgress,
                    backgroundColor: AppColors.surfaceLight,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.success),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'กำลังดาวน์โหลด ${(widget.torrentService.downloadProgress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),

          if (!hasOnlineSeeders && !widget.torrentService.isDownloadingFile)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'ต้องมี Seeder ออนไลน์จึงจะดาวน์โหลดได้ (ผ่าน server relay)',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),

          // Seed button (register yourself as seeder for a file you have)
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _isRegistering
                  ? null
                  : () async {
                      setState(() => _isRegistering = true);
                      try {
                        final success =
                            await widget.torrentService.registerSeeder(
                          fileHash: file.fileHash,
                        );
                        if (!mounted) return;
                        if (success) {
                          SoundService().play(SfxType.coin);
                          HapticFeedback.mediumImpact();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('ลงทะเบียนเป็น Seeder แล้ว'),
                              backgroundColor: AppColors.success,
                            ),
                          );
                          _loadDetail();
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                widget.torrentService.error ??
                                    'ลงทะเบียนไม่สำเร็จ',
                              ),
                              backgroundColor: AppColors.error,
                            ),
                          );
                        }
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'เกิดข้อผิดพลาด: ${e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '')}',
                            ),
                            backgroundColor: AppColors.error,
                          ),
                        );
                      } finally {
                        if (mounted) {
                          setState(() => _isRegistering = false);
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    hasOnlineSeeders ? AppColors.success : AppColors.primary,
                disabledBackgroundColor:
                    AppColors.primary.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isRegistering
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_upload_outlined, color: Colors.white, size: 20),
              label: Text(
                widget.torrentService.seedingFileHashes.contains(file.fileHash)
                    ? 'กำลัง Seed อยู่'
                    : 'ลงทะเบียนเป็น Seeder',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),

          // Show online seeder IPs
          if (hasOnlineSeeders) ...[
            const SizedBox(height: 12),
            const Text(
              'P2P Peers',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            ...onlineSeeders.map((seeder) {
              final addr = seeder.publicIp != null && seeder.publicPort != null
                  ? '${seeder.publicIp}:${seeder.publicPort}'
                  : 'ไม่ทราบ IP';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      addr,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 220.ms);
  }

  Widget _buildStatBadge(IconData icon, String text, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
