import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/member.dart';
import '../theme/app_theme.dart';
import 'status_indicator.dart';

class MemberTile extends StatelessWidget {
  final NetworkMember member;
  final int index;

  const MemberTile({
    super.key,
    required this.member,
    this.index = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: member.isOnline
              ? AppColors.success.withValues(alpha: 0.2)
              : AppColors.cardBorder,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: member.isOnline
                  ? AppColors.success.withValues(alpha: 0.1)
                  : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Icon(
                Icons.devices,
                color: member.isOnline
                    ? AppColors.success
                    : AppColors.textMuted,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (member.virtualIp != null)
                  Text(
                    member.virtualIp!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ),
          StatusIndicator(isOnline: member.isOnline),
        ],
      ),
    )
        .animate()
        .fadeIn(
          duration: 300.ms,
          delay: (index * 60).ms,
        )
        .slideX(
          begin: 0.05,
          end: 0,
          duration: 300.ms,
          delay: (index * 60).ms,
        );
  }
}
