import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cyber_page_route.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/neon_button.dart';
import 'kyc_verification_screen.dart';
import 'trophy_screen.dart';

class UserProfileScreen extends StatefulWidget {
  final TorrentService torrentService;

  const UserProfileScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  @override
  void initState() {
    super.initState();
    widget.torrentService.addListener(_onChanged);
    _loadData();
  }

  Future<void> _loadData() async {
    await Future.wait([
      widget.torrentService.fetchUserProfile(),
      widget.torrentService.fetchKycStatus(),
    ]);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.torrentService.removeListener(_onChanged);
    super.dispose();
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
                child: RefreshIndicator(
                  onRefresh: _loadData,
                  color: AppColors.primary,
                  backgroundColor: AppColors.surface,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildProfileHeader(),
                        const SizedBox(height: 16),
                        _buildStatsGrid(),
                        const SizedBox(height: 16),
                        _buildTrophySection(),
                        const SizedBox(height: 16),
                        _buildKycSection(),
                      ],
                    ),
                  ),
                ),
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
              'โปรไฟล์',
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

  Widget _buildProfileHeader() {
    final stats = widget.torrentService.userStats;
    final trophies = widget.torrentService.userTrophies;

    return GlassCard(
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.person,
                  color: Colors.white,
                  size: 28,
                ),
              )
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .shimmer(
                    duration: 3000.ms,
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            stats?.displayName ?? 'Unknown',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (trophies.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            trophies
                                .map((t) => t.badgeText)
                                .take(5)
                                .join(''),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:
                                AppColors.warning.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'อันดับ #${stats?.rankPosition ?? '-'}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:
                                AppColors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'สกอร์ ${stats?.score ?? 0}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms);
  }

  Widget _buildStatsGrid() {
    final stats = widget.torrentService.userStats;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'สถิติ',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ).animate().fadeIn(duration: 300.ms, delay: 150.ms),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                Icons.upload,
                'อัพโหลด',
                stats?.uploadFormatted ?? '0 B',
                AppColors.success,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                Icons.download,
                'ดาวน์โหลด',
                stats?.downloadFormatted ?? '0 B',
                AppColors.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                Icons.file_upload,
                'ไฟล์แชร์',
                '${stats?.totalFilesShared ?? 0}',
                const Color(0xFFFF6B6B),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                Icons.file_download,
                'ไฟล์ดาวน์โหลด',
                '${stats?.totalFilesDownloaded ?? 0}',
                const Color(0xFF45B7D1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                Icons.timer,
                'เวลา Seed',
                stats?.seedTimeFormatted ?? '0m',
                AppColors.warning,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                Icons.sync,
                'Ratio',
                stats?.ratio.toStringAsFixed(2) ?? '0.00',
                AppColors.secondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(
      IconData icon, String label, String value, Color color) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
  }

  Widget _buildTrophySection() {
    final trophies = widget.torrentService.userTrophies;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events,
                  color: AppColors.warning, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'ถ้วยรางวัล',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                '${trophies.length} รางวัล',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (trophies.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'ยังไม่มีรางวัล เริ่มแชร์ไฟล์เลย!',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: trophies.map((trophy) {
                return Tooltip(
                  message: '${trophy.name} - ${trophy.description}',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(trophy.badgeText,
                            style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        Text(
                          trophy.name,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: NeonButton(
              text: 'ดูทั้งหมด',
              icon: Icons.emoji_events,
              color: AppColors.secondary,
              outlined: true,
              onPressed: () {
                SoundService().play(SfxType.tap);
                Navigator.of(context).push(
                  CyberPageRoute(
                    builder: (_) => TrophyScreen(
                      torrentService: widget.torrentService,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 300.ms);
  }

  Widget _buildKycSection() {
    final kycStatus = widget.torrentService.kycStatus;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (kycStatus) {
      case 'approved':
        statusColor = AppColors.success;
        statusText = 'ยืนยันตัวตนแล้ว';
        statusIcon = Icons.verified;
        break;
      case 'pending':
        statusColor = AppColors.warning;
        statusText = 'รอการอนุมัติ';
        statusIcon = Icons.hourglass_top;
        break;
      case 'rejected':
        statusColor = AppColors.error;
        statusText = 'ถูกปฏิเสธ';
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = AppColors.textMuted;
        statusText = 'ยังไม่ได้ยืนยัน';
        statusIcon = Icons.shield_outlined;
    }

    return GlassCard(
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
                    const Text(
                      'ยืนยันตัวตน (KYC)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 12,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'ยืนยันตัวตนเพื่อเข้าถึงเนื้อหา 18+ ต้องมีอายุ 18 ปีขึ้นไป',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
          ),
          if (kycStatus != 'approved' && kycStatus != 'pending') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: NeonButton(
                text: 'ยืนยันตัวตน',
                icon: Icons.badge,
                color: AppColors.primary,
                outlined: true,
                onPressed: () {
                  SoundService().play(SfxType.tapHeavy);
                  HapticFeedback.mediumImpact();
                  Navigator.of(context).push(
                    CyberPageRoute(
                      builder: (_) => KycVerificationScreen(
                        torrentService: widget.torrentService,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 400.ms);
  }
}
