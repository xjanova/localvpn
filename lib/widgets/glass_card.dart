import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sound_service.dart';
import '../theme/app_theme.dart';

class GlassCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blurAmount;
  final Color? borderColor;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16,
    this.blurAmount = 10,
    this.borderColor,
    this.onTap,
  });

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pressController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOutCubic),
    );
    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.onTap != null) {
      _pressController.forward();
    }
  }

  void _onTapUp(TapUpDetails _) {
    if (widget.onTap != null) {
      _pressController.reverse();
    }
  }

  void _onTapCancel() {
    if (widget.onTap != null) {
      _pressController.reverse();
    }
  }

  void _onTap() {
    if (widget.onTap != null) {
      HapticFeedback.lightImpact();
      SoundService().play(SfxType.tap);
      widget.onTap!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderCol = widget.borderColor ?? AppColors.cardBorder;

    final card = AnimatedBuilder(
      animation: _pressController,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            margin: widget.margin,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: Color.lerp(
                      borderCol,
                      AppColors.primary,
                      _glowAnimation.value * 0.3,
                    ) ??
                    borderCol,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary
                      .withValues(alpha: 0.05 + _glowAnimation.value * 0.08),
                  blurRadius: 20 + _glowAnimation.value * 8,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: widget.blurAmount,
                  sigmaY: widget.blurAmount,
                ),
                child: Container(
                  padding: widget.padding ?? const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppColors.surface.withValues(alpha: 0.8),
                        AppColors.surface.withValues(alpha: 0.5),
                      ],
                    ),
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),
        );
      },
    );

    if (widget.onTap != null) {
      return GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        onTap: _onTap,
        child: card,
      );
    }

    return card;
  }
}
