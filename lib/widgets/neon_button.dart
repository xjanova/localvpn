import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sound_service.dart';
import '../theme/app_theme.dart';

class NeonButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final Color color;
  final IconData? icon;
  final bool isLoading;
  final bool outlined;
  final double? width;

  const NeonButton({
    super.key,
    required this.text,
    this.onPressed,
    this.color = AppColors.primary,
    this.icon,
    this.isLoading = false,
    this.outlined = false,
    this.width,
  });

  @override
  State<NeonButton> createState() => _NeonButtonState();
}

class _NeonButtonState extends State<NeonButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;
  bool _pressing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _glowAnimation = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handlePress() {
    if (widget.onPressed == null || widget.isLoading) return;
    HapticFeedback.mediumImpact();
    SoundService().play(SfxType.tapHeavy);
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressing = true),
      onTapUp: (_) => setState(() => _pressing = false),
      onTapCancel: () => setState(() => _pressing = false),
      child: AnimatedBuilder(
        animation: _glowAnimation,
        builder: (context, child) {
          return AnimatedScale(
            scale: _pressing ? 0.96 : 1.0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOutCubic,
            child: Container(
              width: widget.width,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: widget.onPressed != null
                    ? [
                        BoxShadow(
                          color: widget.color.withValues(
                              alpha: _glowAnimation.value *
                                  (_pressing ? 0.5 : 0.3)),
                          blurRadius: _pressing ? 18 : 12,
                          spreadRadius: _pressing ? 1 : 0,
                        ),
                      ]
                    : null,
              ),
              child: widget.outlined
                  ? OutlinedButton(
                      onPressed:
                          widget.isLoading ? null : _handlePress,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: widget.color,
                        side: BorderSide(
                          color: widget.color.withValues(alpha: 0.7),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _buildChild(),
                    )
                  : ElevatedButton(
                      onPressed:
                          widget.isLoading ? null : _handlePress,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.color,
                        foregroundColor: AppColors.background,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _buildChild(),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildChild() {
    if (widget.isLoading) {
      return SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(
            widget.outlined ? widget.color : AppColors.background,
          ),
        ),
      );
    }

    if (widget.icon != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: 20),
          const SizedBox(width: 8),
          Text(
            widget.text,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    return Text(
      widget.text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
