import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AnimatedBackground extends StatefulWidget {
  final Widget child;

  const AnimatedBackground({
    super.key,
    required this.child,
  });

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with TickerProviderStateMixin {
  late AnimationController _controller1;
  late AnimationController _controller2;

  @override
  void initState() {
    super.initState();
    _controller1 = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    )..repeat();

    _controller2 = AnimationController(
      duration: const Duration(seconds: 12),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller1.dispose();
    _controller2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: AppTheme.backgroundGradient,
          ),
        ),
        AnimatedBuilder(
          animation: _controller1,
          builder: (context, child) {
            return CustomPaint(
              painter: _ParticlePainter(
                progress: _controller1.value,
                color: AppColors.primary,
              ),
              size: Size.infinite,
            );
          },
        ),
        AnimatedBuilder(
          animation: _controller2,
          builder: (context, child) {
            return CustomPaint(
              painter: _ParticlePainter(
                progress: _controller2.value,
                color: AppColors.secondary,
                offset: 0.5,
              ),
              size: Size.infinite,
            );
          },
        ),
        // Gradient overlay for readability
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.background.withValues(alpha: 0.3),
                AppColors.background.withValues(alpha: 0.7),
                AppColors.background.withValues(alpha: 0.9),
              ],
            ),
          ),
        ),
        // Faint logo watermark
        Center(
          child: Opacity(
            opacity: 0.04,
            child: Image.asset(
              'assets/logo.webp',
              width: MediaQuery.of(context).size.width * 0.7,
              fit: BoxFit.contain,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final double progress;
  final Color color;
  final double offset;

  _ParticlePainter({
    required this.progress,
    required this.color,
    this.offset = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill;

    final random = Random(42);
    const particleCount = 20;

    for (var i = 0; i < particleCount; i++) {
      final baseX = random.nextDouble() * size.width;
      final baseY = random.nextDouble() * size.height;
      final radius = random.nextDouble() * 3 + 1;
      final speed = random.nextDouble() * 0.5 + 0.5;
      final phase = random.nextDouble() * 2 * pi;

      final x = baseX + sin((progress * speed * 2 * pi) + phase + offset) * 30;
      final y = baseY + cos((progress * speed * 2 * pi) + phase + offset) * 20;

      final alpha = (sin((progress * 2 * pi) + phase) * 0.3 + 0.3)
          .clamp(0.0, 1.0);

      paint.color = color.withValues(alpha: alpha * 0.15);

      canvas.drawCircle(Offset(x, y), radius, paint);

      // Draw subtle connecting lines to nearby particles
      if (i > 0 && i % 3 == 0) {
        final prevX = random.nextDouble() * size.width +
            sin((progress * 0.8 * 2 * pi) + phase + offset) * 30;
        final prevY = random.nextDouble() * size.height +
            cos((progress * 0.8 * 2 * pi) + phase + offset) * 20;

        final linePaint = Paint()
          ..color = color.withValues(alpha: alpha * 0.05)
          ..strokeWidth = 0.5
          ..style = PaintingStyle.stroke;

        canvas.drawLine(
          Offset(x, y),
          Offset(prevX, prevY),
          linePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
