import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cyber_page_route.dart';
import '../../widgets/glass_card.dart';
import 'category_files_screen.dart';
import 'leaderboard_screen.dart';
import 'trophy_screen.dart';
import 'user_profile_screen.dart';

class GlobalTorrentScreen extends StatefulWidget {
  final TorrentService torrentService;

  const GlobalTorrentScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<GlobalTorrentScreen> createState() => _GlobalTorrentScreenState();
}

class _GlobalTorrentScreenState extends State<GlobalTorrentScreen> {
  @override
  void initState() {
    super.initState();
    widget.torrentService.addListener(_onChanged);
    _loadData();
  }

  Future<void> _loadData() async {
    await Future.wait([
      widget.torrentService.fetchCategories(),
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

  IconData _getCategoryIcon(String iconName) {
    switch (iconName) {
      case 'movie':
        return Icons.movie;
      case 'music_note':
        return Icons.music_note;
      case 'sports_esports':
        return Icons.sports_esports;
      case 'apps':
        return Icons.apps;
      case 'menu_book':
        return Icons.menu_book;
      case 'image':
        return Icons.image;
      case 'computer':
        return Icons.computer;
      case 'school':
        return Icons.school;
      case 'folder':
        return Icons.folder;
      case '18_up_rating':
        return Icons.eighteen_up_rating;
      default:
        return Icons.folder;
    }
  }

  Color _getCategoryColor(int index) {
    final colors = [
      const Color(0xFFFF6B6B),
      const Color(0xFF4ECDC4),
      const Color(0xFF45B7D1),
      const Color(0xFF96CEB4),
      const Color(0xFFFECE4D),
      const Color(0xFFFF85A2),
      const Color(0xFF6C5CE7),
      const Color(0xFF00B894),
      const Color(0xFFBDB2FF),
      const Color(0xFFFF6348),
    ];
    return colors[index % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
              _buildHeader(),
              const SizedBox(height: 20),
              _buildQuickStats(),
              const SizedBox(height: 20),
              _buildQuickActions(),
              const SizedBox(height: 24),
              _buildCategoriesGrid(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: [Color(0xFFFF6B6B), Color(0xFFFF8E53)],
            ),
          ),
          child: const Icon(
            Icons.cloud_download,
            color: Colors.white,
            size: 22,
          ),
        )
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .shimmer(
              duration: 3000.ms,
              color: Colors.white.withValues(alpha: 0.15),
            ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Global Torrent',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                'แชร์ไฟล์ทั่วโลก',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        // Trophy badge count
        if (widget.torrentService.userTrophies.isNotEmpty)
          GestureDetector(
            onTap: () {
              SoundService().play(SfxType.tap);
              HapticFeedback.lightImpact();
              Navigator.of(context).push(
                CyberPageRoute(
                  builder: (_) => UserProfileScreen(
                    torrentService: widget.torrentService,
                  ),
                ),
              );
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.torrentService.userTrophies
                        .map((t) => t.badgeText)
                        .take(3)
                        .join(''),
                    style: const TextStyle(fontSize: 14),
                  ),
                  if (widget.torrentService.userTrophies.length > 3) ...[
                    const SizedBox(width: 2),
                    Text(
                      '+${widget.torrentService.userTrophies.length - 3}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.warning,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            )
                .animate()
                .fadeIn(duration: 400.ms)
                .shimmer(duration: 2000.ms, delay: 500.ms),
          ),
      ],
    ).animate().fadeIn(duration: 400.ms);
  }

  Widget _buildQuickStats() {
    final stats = widget.torrentService.userStats;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _buildStatItem(
            Icons.upload,
            stats?.uploadFormatted ?? '0 B',
            'อัพโหลด',
            AppColors.success,
          ),
          _buildStatDivider(),
          _buildStatItem(
            Icons.download,
            stats?.downloadFormatted ?? '0 B',
            'ดาวน์โหลด',
            AppColors.primary,
          ),
          _buildStatDivider(),
          _buildStatItem(
            Icons.emoji_events,
            '#${stats?.rankPosition ?? '-'}',
            'อันดับ',
            AppColors.warning,
          ),
          _buildStatDivider(),
          _buildStatItem(
            Icons.score,
            '${stats?.score ?? 0}',
            'สกอร์',
            AppColors.secondary,
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms);
  }

  Widget _buildStatItem(
      IconData icon, String value, String label, Color color) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatDivider() {
    return Container(
      width: 1,
      height: 36,
      color: AppColors.cardBorder,
    );
  }

  Widget _buildQuickActions() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            icon: Icons.leaderboard,
            label: 'อันดับ',
            color: AppColors.warning,
            onTap: () {
              SoundService().play(SfxType.tap);
              HapticFeedback.lightImpact();
              Navigator.of(context).push(
                CyberPageRoute(
                  builder: (_) => LeaderboardScreen(
                    torrentService: widget.torrentService,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildActionButton(
            icon: Icons.emoji_events,
            label: 'ถ้วยรางวัล',
            color: AppColors.secondary,
            onTap: () {
              SoundService().play(SfxType.tap);
              HapticFeedback.lightImpact();
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
        const SizedBox(width: 10),
        Expanded(
          child: _buildActionButton(
            icon: Icons.person,
            label: 'โปรไฟล์',
            color: AppColors.success,
            onTap: () {
              SoundService().play(SfxType.tap);
              HapticFeedback.lightImpact();
              Navigator.of(context).push(
                CyberPageRoute(
                  builder: (_) => UserProfileScreen(
                    torrentService: widget.torrentService,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ).animate().fadeIn(duration: 400.ms, delay: 150.ms);
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 12),
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoriesGrid() {
    if (widget.torrentService.isLoading && widget.torrentService.categories.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 40),
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    if (widget.torrentService.categories.isEmpty) {
      return Center(
        child: Column(
          children: [
            const SizedBox(height: 40),
            const Icon(
              Icons.cloud_off,
              size: 64,
              color: AppColors.textMuted,
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .moveY(begin: 0, end: -8, duration: 2500.ms),
            const SizedBox(height: 16),
            const Text(
              'ไม่สามารถโหลดหมวดหมู่ได้',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
              ),
            ),
            if (widget.torrentService.error != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.torrentService.error!,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'หมวดหมู่',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ).animate().fadeIn(duration: 300.ms, delay: 200.ms),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.5,
          ),
          itemCount: widget.torrentService.categories.length,
          itemBuilder: (context, index) {
            final cat = widget.torrentService.categories[index];
            final color = _getCategoryColor(index);

            return GlassCard(
              padding: const EdgeInsets.all(14),
              borderColor: color.withValues(alpha: 0.2),
              onTap: () {
                SoundService().play(SfxType.tapHeavy);
                HapticFeedback.mediumImpact();
                Navigator.of(context).push(
                  CyberPageRoute(
                    builder: (_) => CategoryFilesScreen(
                      torrentService: widget.torrentService,
                      category: cat,
                    ),
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _getCategoryIcon(cat.icon),
                          color: color,
                          size: 20,
                        ),
                      ),
                      const Spacer(),
                      if (cat.isAdult)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '18+',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: AppColors.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cat.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${cat.fileCount} ไฟล์',
                        style: TextStyle(
                          fontSize: 11,
                          color: color.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
                .animate()
                .fadeIn(
                  duration: 400.ms,
                  delay: (200 + index.clamp(0, 8) * 60).ms,
                )
                .scale(
                  begin: const Offset(0.9, 0.9),
                  end: const Offset(1, 1),
                  duration: 400.ms,
                  delay: (200 + index.clamp(0, 8) * 60).ms,
                );
          },
        ),
      ],
    );
  }
}
