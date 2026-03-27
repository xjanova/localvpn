import 'package:flutter/material.dart';

import '../services/sound_service.dart';

/// Cyberpunk-style page transition with glitch + slide + fade.
class CyberPageRoute<T> extends PageRouteBuilder<T> {
  CyberPageRoute({
    required WidgetBuilder builder,
    super.settings,
  }) : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Play swoosh on forward transition start
            if (animation.status == AnimationStatus.forward &&
                animation.value < 0.1) {
              SoundService().play(SfxType.swoosh);
            }

            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );

            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(curvedAnimation),
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
                  ),
                ),
                child: _GlitchTransition(
                  animation: animation,
                  child: child,
                ),
              ),
            );
          },
        );
}

/// Adds a subtle digital glitch effect during page transition
class _GlitchTransition extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;

  const _GlitchTransition({
    required this.animation,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final progress = animation.value;
        // Only apply glitch in the first half of transition
        if (progress > 0.5 || progress < 0.05) {
          return child;
        }

        // Subtle scan-line / offset glitch
        final glitchAmount = (1.0 - progress * 2) * 2.0;
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                Colors.white.withValues(alpha: 0.95),
                Colors.white,
                Colors.white.withValues(alpha: 0.97),
                Colors.white,
              ],
              stops: [
                0.0,
                0.3 + glitchAmount * 0.02,
                0.5,
                0.7 - glitchAmount * 0.02,
                1.0,
              ],
            ).createShader(bounds);
          },
          blendMode: BlendMode.modulate,
          child: child,
        );
      },
    );
  }
}

/// Simple pop transition with scale + fade for dialogs/modals
class CyberPopupRoute<T> extends PageRouteBuilder<T> {
  CyberPopupRoute({
    required WidgetBuilder builder,
    super.settings,
  }) : super(
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedAnimation = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutBack,
              reverseCurve: Curves.easeIn,
            );

            return ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1.0)
                  .animate(curvedAnimation),
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
                  ),
                ),
                child: child,
              ),
            );
          },
        );
}
