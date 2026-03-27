import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';

class TrophyScreen extends StatefulWidget {
  final TorrentService torrentService;

  const TrophyScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<TrophyScreen> createState() => _TrophyScreenState();
}

class _TrophyScreenState extends State<TrophyScreen> {
  @override
  void initState() {
    super.initState();
    widget.torrentService.addListener(_onChanged);
    _loadData();
  }

  Future<void> _loadData() async {
    await Future.wait([
      widget.torrentService.fetchAllTrophies(),
      widget.torrentService.fetchUserProfile(),
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

  Color _getDifficultyColor(String difficulty) {
    switch (difficulty) {
      case 'easy':
        return AppColors.success;
      case 'medium':
        return AppColors.warning;
      case 'hard':
        return AppColors.error;
      default:
        return AppColors.textMuted;
    }
  }

  String _getDifficultyLabel(String difficulty) {
    switch (difficulty) {
      case 'easy':
        return 'ง่าย';
      case 'medium':
        return 'ปานกลาง';
      case 'hard':
        return 'ยาก';
      default:
        return difficulty;
    }
  }

  IconData _getDifficultyIcon(String difficulty) {
    switch (difficulty) {
      case 'easy':
        return Icons.star_outline;
      case 'medium':
        return Icons.star_half;
      case 'hard':
        return Icons.star;
      default:
        return Icons.star_outline;
    }
  }

  bool _isTrophyAwarded(int trophyId) {
    return widget.torrentService.userTrophies
        .any((t) => t.id == trophyId);
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
              Expanded(child: _buildContent()),
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
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: const LinearGradient(
                colors: [Color(0xFF7C4DFF), Color(0xFFE040FB)],
              ),
            ),
            child: const Icon(Icons.emoji_events,
                color: Colors.white, size: 20),
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .shimmer(
                duration: 2500.ms,
                color: Colors.white.withValues(alpha: 0.2),
              ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ถ้วยรางวัล',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  'ได้รับ ${widget.torrentService.userTrophies.length} / '
                  '${_totalTrophies()} รางวัล',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().slideY(begin: -0.3, end: 0, duration: 400.ms);
  }

  int _totalTrophies() {
    int total = 0;
    widget.torrentService.allTrophies.forEach((_, list) {
      total += list.length;
    });
    return total;
  }

  Widget _buildContent() {
    final allTrophies = widget.torrentService.allTrophies;

    if (allTrophies.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    final order = ['easy', 'medium', 'hard'];

    return RefreshIndicator(
      onRefresh: _loadData,
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: [
          // Progress bar
          _buildProgressBar(),
          const SizedBox(height: 20),

          for (final difficulty in order)
            if (allTrophies[difficulty] != null) ...[
              _buildDifficultyHeader(difficulty),
              const SizedBox(height: 10),
              ...allTrophies[difficulty]!.asMap().entries.map((entry) {
                return _buildTrophyCard(entry.value, entry.key, difficulty);
              }),
              const SizedBox(height: 16),
            ],
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final total = _totalTrophies();
    final awarded = widget.torrentService.userTrophies.length;
    final progress = total > 0 ? awarded / total : 0.0;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'ความคืบหน้า',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                '$awarded / $total',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: AppColors.surfaceLight,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.primary),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          // Awarded badge icons
          if (widget.torrentService.userTrophies.isNotEmpty)
            Wrap(
              spacing: 4,
              children: widget.torrentService.userTrophies
                  .map((t) => Text(t.badgeText,
                      style: const TextStyle(fontSize: 18)))
                  .toList(),
            ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms);
  }

  Widget _buildDifficultyHeader(String difficulty) {
    final color = _getDifficultyColor(difficulty);
    return Row(
      children: [
        Icon(_getDifficultyIcon(difficulty), color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          _getDifficultyLabel(difficulty),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 1,
            color: color.withValues(alpha: 0.2),
          ),
        ),
      ],
    ).animate().fadeIn(duration: 300.ms, delay: 200.ms);
  }

  Widget _buildTrophyCard(BtTrophy trophy, int index, String difficulty) {
    final isAwarded = _isTrophyAwarded(trophy.id);
    final color = _getDifficultyColor(difficulty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        borderColor: isAwarded ? color.withValues(alpha: 0.3) : null,
        onTap: isAwarded
            ? () {
                SoundService().play(SfxType.coin);
                HapticFeedback.lightImpact();
              }
            : null,
        child: Row(
          children: [
            // Trophy icon
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isAwarded
                    ? color.withValues(alpha: 0.15)
                    : AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(12),
                border: isAwarded
                    ? Border.all(color: color.withValues(alpha: 0.3))
                    : null,
              ),
              child: Center(
                child: Text(
                  trophy.icon,
                  style: TextStyle(
                    fontSize: 22,
                    color: isAwarded ? null : AppColors.textMuted,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Trophy info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          trophy.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isAwarded
                                ? AppColors.textPrimary
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (isAwarded) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.check_circle,
                          color: AppColors.success,
                          size: 16,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    trophy.description,
                    style: TextStyle(
                      fontSize: 12,
                      color: isAwarded
                          ? AppColors.textSecondary
                          : AppColors.textMuted.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),

            // Badge
            if (isAwarded)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  trophy.badgeText,
                  style: const TextStyle(fontSize: 16),
                ),
              )
            else
              Icon(
                Icons.lock_outline,
                color: AppColors.textMuted.withValues(alpha: 0.3),
                size: 18,
              ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(
          duration: 350.ms,
          delay: (250 + index * 50).ms,
        )
        .slideX(begin: 0.03, end: 0);
  }
}
