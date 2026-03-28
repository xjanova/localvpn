import 'dart:math';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// VPN Mascot connection states
enum MascotState { idle, connecting, connected, error }

/// Cyberpunk robot mascot with animated states
class VpnMascot extends StatefulWidget {
  final MascotState state;
  final double size;
  final String? countryFlag;

  const VpnMascot({
    super.key,
    this.state = MascotState.idle,
    this.size = 160,
    this.countryFlag,
  });

  @override
  State<VpnMascot> createState() => _VpnMascotState();
}

class _VpnMascotState extends State<VpnMascot> with TickerProviderStateMixin {
  late AnimationController _breathController;
  late AnimationController _scanController;
  late AnimationController _glowController;
  late AnimationController _eyeBlinkController;

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    )..repeat(reverse: true);

    _scanController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();

    _glowController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _eyeBlinkController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );

    _startBlinkLoop();
  }

  void _startBlinkLoop() async {
    while (mounted) {
      await Future.delayed(Duration(milliseconds: 2000 + Random().nextInt(3000)));
      if (!mounted) return;
      try {
        await _eyeBlinkController.forward();
        await _eyeBlinkController.reverse();
      } catch (_) {
        // Controller disposed during animation — exit loop
        return;
      }
    }
  }

  @override
  void dispose() {
    _breathController.dispose();
    _scanController.dispose();
    _glowController.dispose();
    _eyeBlinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _breathController,
          _scanController,
          _glowController,
          _eyeBlinkController,
        ]),
        builder: (context, _) {
          return CustomPaint(
            painter: _MascotPainter(
              state: widget.state,
              breathValue: _breathController.value,
              scanValue: _scanController.value,
              glowValue: _glowController.value,
              blinkValue: _eyeBlinkController.value,
              countryFlag: widget.countryFlag,
            ),
          );
        },
      ),
    );
  }
}

class _MascotPainter extends CustomPainter {
  final MascotState state;
  final double breathValue;
  final double scanValue;
  final double glowValue;
  final double blinkValue;
  final String? countryFlag;

  _MascotPainter({
    required this.state,
    required this.breathValue,
    required this.scanValue,
    required this.glowValue,
    required this.blinkValue,
    this.countryFlag,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final s = size.width / 160; // scale factor

    final breathOffset = breathValue * 3 * s;

    // === Shield glow (behind robot) ===
    if (state == MascotState.connected) {
      final shieldPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.success.withValues(alpha: 0.15 + glowValue * 0.1),
            AppColors.success.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: 70 * s));
      canvas.drawCircle(Offset(cx, cy), 70 * s, shieldPaint);
    } else if (state == MascotState.connecting) {
      final scanAngle = scanValue * 2 * pi;
      final scanPaint = Paint()
        ..shader = SweepGradient(
          startAngle: scanAngle,
          endAngle: scanAngle + pi / 2,
          colors: [
            AppColors.primary.withValues(alpha: 0),
            AppColors.primary.withValues(alpha: 0.2),
            AppColors.primary.withValues(alpha: 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: 65 * s));
      canvas.drawCircle(Offset(cx, cy), 65 * s, scanPaint);
    }

    // === Body (rounded rectangle) ===
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy + 10 * s - breathOffset),
        width: 70 * s,
        height: 80 * s,
      ),
      Radius.circular(16 * s),
    );

    // Body gradient
    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF2A3050),
          const Color(0xFF1A1F36),
        ],
      ).createShader(bodyRect.outerRect);
    canvas.drawRRect(bodyRect, bodyPaint);

    // Body border
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..color = _getBorderColor();
    canvas.drawRRect(bodyRect, borderPaint);

    // === Chest light (circle) ===
    final chestY = cy + 20 * s - breathOffset;
    final chestColor = _getChestColor();
    canvas.drawCircle(
      Offset(cx, chestY),
      6 * s,
      Paint()..color = chestColor.withValues(alpha: 0.3 + glowValue * 0.3),
    );
    canvas.drawCircle(
      Offset(cx, chestY),
      3 * s,
      Paint()..color = chestColor,
    );

    // === Head ===
    final headY = cy - 30 * s - breathOffset;
    final headRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, headY), width: 56 * s, height: 44 * s),
      Radius.circular(12 * s),
    );
    canvas.drawRRect(headRect, Paint()..color = const Color(0xFF252B48));
    canvas.drawRRect(headRect, borderPaint);

    // === Eyes ===
    final eyeY = headY + 2 * s;
    final eyeH = (1 - blinkValue) * 10 * s; // close when blinking
    final leftEyeX = cx - 12 * s;
    final rightEyeX = cx + 12 * s;

    if (eyeH > 1) {
      final eyeColor = _getEyeColor();
      // Left eye
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(leftEyeX, eyeY), width: 12 * s, height: eyeH),
          Radius.circular(3 * s),
        ),
        Paint()..color = eyeColor,
      );
      // Right eye
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(rightEyeX, eyeY), width: 12 * s, height: eyeH),
          Radius.circular(3 * s),
        ),
        Paint()..color = eyeColor,
      );

      // Eye glow
      if (state == MascotState.connected || state == MascotState.connecting) {
        final glowPaint = Paint()
          ..color = eyeColor.withValues(alpha: 0.3)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 * s);
        canvas.drawCircle(Offset(leftEyeX, eyeY), 8 * s, glowPaint);
        canvas.drawCircle(Offset(rightEyeX, eyeY), 8 * s, glowPaint);
      }
    }

    // === Antenna ===
    final antennaBaseY = headY - 22 * s;
    final antennaTopY = antennaBaseY - 14 * s;
    canvas.drawLine(
      Offset(cx, antennaBaseY),
      Offset(cx, antennaTopY),
      Paint()
        ..color = AppColors.textMuted
        ..strokeWidth = 2 * s
        ..strokeCap = StrokeCap.round,
    );

    // Antenna tip (blinks when connecting)
    Color tipColor = AppColors.textMuted;
    if (state == MascotState.connecting) {
      tipColor = scanValue > 0.5 ? AppColors.primary : AppColors.textMuted;
    } else if (state == MascotState.connected) {
      tipColor = AppColors.success;
    } else if (state == MascotState.error) {
      tipColor = AppColors.error;
    }
    canvas.drawCircle(Offset(cx, antennaTopY), 4 * s, Paint()..color = tipColor);
    if (state != MascotState.idle) {
      canvas.drawCircle(
        Offset(cx, antennaTopY),
        6 * s,
        Paint()..color = tipColor.withValues(alpha: 0.2 + glowValue * 0.2),
      );
    }

    // === Arms ===
    final armY = cy + 5 * s - breathOffset;
    final armPaint = Paint()
      ..color = const Color(0xFF252B48)
      ..strokeWidth = 6 * s
      ..strokeCap = StrokeCap.round;

    // Left arm
    canvas.drawLine(
      Offset(cx - 35 * s, armY),
      Offset(cx - 48 * s, armY + 20 * s + breathValue * 4 * s),
      armPaint,
    );
    // Right arm
    canvas.drawLine(
      Offset(cx + 35 * s, armY),
      Offset(cx + 48 * s, armY + 20 * s + breathValue * 4 * s),
      armPaint,
    );

    // === Legs ===
    final legY = cy + 50 * s - breathOffset;
    canvas.drawLine(
      Offset(cx - 14 * s, legY),
      Offset(cx - 18 * s, legY + 18 * s),
      armPaint,
    );
    canvas.drawLine(
      Offset(cx + 14 * s, legY),
      Offset(cx + 18 * s, legY + 18 * s),
      armPaint,
    );

    // === Shield (when connected) ===
    if (state == MascotState.connected) {
      _drawShield(canvas, cx, cy - breathOffset, s);
    }

    // === Connecting scan ring ===
    if (state == MascotState.connecting) {
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * s
        ..color = AppColors.primary.withValues(alpha: 0.3 + scanValue * 0.3);
      final ringRadius = 55 * s + scanValue * 15 * s;
      canvas.drawCircle(Offset(cx, cy - breathOffset), ringRadius, ringPaint);
    }
  }

  void _drawShield(Canvas canvas, double cx, double cy, double s) {
    final path = Path();
    final shieldCx = cx + 30 * s;
    final shieldCy = cy - 5 * s;
    final sw = 18 * s;
    final sh = 22 * s;

    path.moveTo(shieldCx, shieldCy - sh);
    path.quadraticBezierTo(shieldCx + sw, shieldCy - sh * 0.7, shieldCx + sw, shieldCy);
    path.quadraticBezierTo(shieldCx + sw * 0.5, shieldCy + sh, shieldCx, shieldCy + sh);
    path.quadraticBezierTo(shieldCx - sw * 0.5, shieldCy + sh, shieldCx - sw, shieldCy);
    path.quadraticBezierTo(shieldCx - sw, shieldCy - sh * 0.7, shieldCx, shieldCy - sh);
    path.close();

    canvas.drawPath(
      path,
      Paint()..color = AppColors.success.withValues(alpha: 0.15 + glowValue * 0.1),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * s
        ..color = AppColors.success.withValues(alpha: 0.6),
    );

    // Check mark inside shield
    final checkPath = Path();
    checkPath.moveTo(shieldCx - 6 * s, shieldCy);
    checkPath.lineTo(shieldCx - 1 * s, shieldCy + 5 * s);
    checkPath.lineTo(shieldCx + 7 * s, shieldCy - 5 * s);
    canvas.drawPath(
      checkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.success,
    );
  }

  Color _getBorderColor() {
    return switch (state) {
      MascotState.idle => AppColors.cardBorder,
      MascotState.connecting => AppColors.primary.withValues(alpha: 0.5 + scanValue * 0.5),
      MascotState.connected => AppColors.success.withValues(alpha: 0.5 + glowValue * 0.3),
      MascotState.error => AppColors.error.withValues(alpha: 0.6),
    };
  }

  Color _getEyeColor() {
    return switch (state) {
      MascotState.idle => AppColors.textMuted,
      MascotState.connecting => AppColors.primary,
      MascotState.connected => AppColors.success,
      MascotState.error => AppColors.error,
    };
  }

  Color _getChestColor() {
    return switch (state) {
      MascotState.idle => AppColors.textMuted,
      MascotState.connecting => AppColors.primary,
      MascotState.connected => AppColors.success,
      MascotState.error => AppColors.error,
    };
  }

  @override
  bool shouldRepaint(covariant _MascotPainter old) => true;
}
