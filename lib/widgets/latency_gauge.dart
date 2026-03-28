import 'dart:math';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Animated arc gauge showing latency in milliseconds
class LatencyGauge extends StatefulWidget {
  final int? pingMs;
  final double size;

  const LatencyGauge({super.key, this.pingMs, this.size = 120});

  @override
  State<LatencyGauge> createState() => _LatencyGaugeState();
}

class _LatencyGaugeState extends State<LatencyGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _needleAnimation;
  double _currentValue = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _needleAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _updateTarget();
  }

  @override
  void didUpdateWidget(LatencyGauge old) {
    super.didUpdateWidget(old);
    if (old.pingMs != widget.pingMs) {
      _updateTarget();
    }
  }

  void _updateTarget() {
    final target = _pingToNormalized(widget.pingMs);
    _needleAnimation = Tween<double>(begin: _currentValue, end: target).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward(from: 0).then((_) {
      if (mounted) _currentValue = target;
    });
  }

  double _pingToNormalized(int? ping) {
    if (ping == null) return 0;
    // Map 0-300ms to 0-1.0 (capped)
    return (ping / 300).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size * 0.65,
      child: AnimatedBuilder(
        animation: _needleAnimation,
        builder: (context, _) {
          return CustomPaint(
            painter: _GaugePainter(
              value: _needleAnimation.value,
              pingMs: widget.pingMs,
            ),
          );
        },
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double value;
  final int? pingMs;

  _GaugePainter({required this.value, this.pingMs});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.85;
    final radius = size.width * 0.42;
    final strokeWidth = size.width * 0.06;

    const startAngle = pi; // left
    const sweepAngle = pi; // half circle

    // === Background arc ===
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      startAngle,
      sweepAngle,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = AppColors.surfaceLight,
    );

    // === Gradient arc (filled portion) ===
    if (value > 0) {
      final arcSweep = sweepAngle * value;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: startAngle,
          endAngle: startAngle + sweepAngle,
          colors: const [
            Color(0xFF69F0AE), // green
            Color(0xFFFFD740), // yellow
            Color(0xFFFF5252), // red
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius));

      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        startAngle,
        arcSweep,
        false,
        arcPaint,
      );
    }

    // === Tick marks ===
    final tickPaint = Paint()
      ..color = AppColors.textMuted.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (int i = 0; i <= 6; i++) {
      final angle = startAngle + (sweepAngle * i / 6);
      final outerR = radius + strokeWidth * 0.8;
      final innerR = radius - strokeWidth * 0.8;
      canvas.drawLine(
        Offset(cx + outerR * cos(angle), cy + outerR * sin(angle)),
        Offset(cx + innerR * cos(angle), cy + innerR * sin(angle)),
        tickPaint,
      );
    }

    // === Needle ===
    final needleAngle = startAngle + sweepAngle * value;
    final needleLength = radius * 0.7;
    final needleTip = Offset(
      cx + needleLength * cos(needleAngle),
      cy + needleLength * sin(needleAngle),
    );

    // Needle shadow
    canvas.drawLine(
      Offset(cx, cy),
      needleTip,
      Paint()
        ..color = _getColor().withValues(alpha: 0.3)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Needle line
    canvas.drawLine(
      Offset(cx, cy),
      needleTip,
      Paint()
        ..color = _getColor()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // Needle center dot
    canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = _getColor());
    canvas.drawCircle(Offset(cx, cy), 3, Paint()..color = AppColors.surface);

    // === Ping text ===
    final textPainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: pingMs != null ? '$pingMs' : '--',
            style: TextStyle(
              color: _getColor(),
              fontSize: size.width * 0.16,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: ' ms',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: size.width * 0.08,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(cx - textPainter.width / 2, cy - radius * 0.45),
    );

    // === Label ===
    final labelPainter = TextPainter(
      text: TextSpan(
        text: _getLabel(),
        style: TextStyle(
          color: _getColor().withValues(alpha: 0.8),
          fontSize: size.width * 0.07,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    labelPainter.layout();
    labelPainter.paint(
      canvas,
      Offset(cx - labelPainter.width / 2, cy - radius * 0.2),
    );
  }

  Color _getColor() {
    if (pingMs == null) return AppColors.textMuted;
    if (pingMs! < 50) return const Color(0xFF69F0AE);
    if (pingMs! < 100) return const Color(0xFFB2FF59);
    if (pingMs! < 150) return const Color(0xFFFFD740);
    if (pingMs! < 250) return const Color(0xFFFF9100);
    return const Color(0xFFFF5252);
  }

  String _getLabel() {
    if (pingMs == null) return 'OFFLINE';
    if (pingMs! < 50) return 'EXCELLENT';
    if (pingMs! < 100) return 'GOOD';
    if (pingMs! < 150) return 'FAIR';
    if (pingMs! < 250) return 'SLOW';
    return 'POOR';
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.pingMs != pingMs;
}
