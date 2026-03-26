import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/network.dart';
import '../theme/app_theme.dart';
import 'glass_card.dart';

class NetworkCard extends StatelessWidget {
  final VpnNetwork network;
  final VoidCallback? onTap;
  final VoidCallback? onJoin;
  final int index;

  const NetworkCard({
    super.key,
    required this.network,
    this.onTap,
    this.onJoin,
    this.index = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  network.isPublic ? Icons.public : Icons.lock,
                  color: network.isPublic
                      ? AppColors.primary
                      : AppColors.secondary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      network.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (network.description != null &&
                        network.description!.isNotEmpty)
                      Text(
                        network.description!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: network.isPublic
                      ? AppColors.primary.withValues(alpha: 0.1)
                      : AppColors.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  network.isPublic ? 'สาธารณะ' : 'ส่วนตัว',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: network.isPublic
                        ? AppColors.primary
                        : AppColors.secondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildStat(
                Icons.people,
                '${network.memberCount} สมาชิก',
              ),
              const SizedBox(width: 16),
              _buildStat(
                Icons.circle,
                '${network.onlineCount} ออนไลน์',
                color: AppColors.success,
              ),
              const Spacer(),
              if (onJoin != null)
                SizedBox(
                  height: 32,
                  child: ElevatedButton(
                    onPressed: onJoin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.background,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'เข้าร่วม',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
          delay: (index * 80).ms,
        )
        .slideX(
          begin: 0.1,
          end: 0,
          duration: 400.ms,
          delay: (index * 80).ms,
          curve: Curves.easeOut,
        );
  }

  Widget _buildStat(IconData icon, String text, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 12,
          color: color ?? AppColors.textMuted,
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: color ?? AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}
