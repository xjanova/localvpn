import 'package:flutter/material.dart';

import '../../services/sound_service.dart';
import '../../theme/m3/m3_theme.dart';
import 'm3_icons.dart';

enum ProBadgeKind {
  /// Paid licence: gold frame, black gloss plate, glowing gold PRO.
  pro,

  /// Free tier: silver frame, dimmed crown.
  free,

  /// No licence / expired: red frame.
  none,
}

/// Licence badge, same construction as Anti X: frame → plate → gloss →
/// diagonal shine, with the 3D crown overflowing the frame on the left.
class ProBadge extends StatefulWidget {
  final ProBadgeKind kind;
  final String main;
  final String sub;
  final VoidCallback? onTap;
  final double height;

  const ProBadge({
    super.key,
    required this.kind,
    required this.main,
    required this.sub,
    this.onTap,
    this.height = 40,
  });

  @override
  State<ProBadge> createState() => _ProBadgeState();
}

class _ProBadgeState extends State<ProBadge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final (frame, plate, mainFill, glow, subColor, crownOpacity) =
        switch (widget.kind) {
      ProBadgeKind.pro => (
          M3Fx.goldFrame,
          M3Fx.proPlate,
          M3Fx.proGold,
          M3Fx.goldGlow,
          const Color(0xFFFFE7A6),
          1.0,
        ),
      ProBadgeKind.free => (
          M3Fx.silverFrame,
          M3Fx.freePlate,
          M3Fx.proSilver,
          <BoxShadow>[],
          const Color(0xFFDDE5EC),
          0.55,
        ),
      ProBadgeKind.none => (
          M3Fx.redFrame,
          M3Fx.freePlate,
          const LinearGradient(
              colors: [Color(0xFFFF8592), Color(0xFFFF8592)]),
          M3Fx.redGlow,
          const Color(0xFFFFC2C8),
          0.4,
        ),
    };
    final h = widget.height;
    final crown = h * 1.15;

    final badge = Container(
      height: h,
      decoration: BoxDecoration(
        gradient: frame,
        borderRadius: BorderRadius.circular(12),
        boxShadow: glow,
      ),
      padding: const EdgeInsets.all(1.8),
      child: Container(
        decoration: BoxDecoration(
          gradient: plate,
          borderRadius: BorderRadius.circular(10.5),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.45,
                child: Container(
                  margin: const EdgeInsets.all(0.6),
                  decoration: const BoxDecoration(
                    gradient: M3Fx.btnGloss,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(10),
                      topRight: Radius.circular(10),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: M3Fx.proShine,
                  borderRadius: BorderRadius.circular(10.5),
                ),
              ),
            ),
            if (_hover && widget.onTap != null)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x1FFFE9A8),
                    borderRadius: BorderRadius.circular(10.5),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(left: crown * 0.62, right: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShaderMask(
                    shaderCallback: (r) => mainFill.createShader(r),
                    blendMode: BlendMode.srcIn,
                    child: Text(
                      widget.main,
                      style: TextStyle(
                        fontFamily: M3Fonts.head,
                        fontSize: h * 0.47,
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                        color: Colors.white,
                        height: 1.05,
                        shadows: widget.kind == ProBadgeKind.pro
                            ? M3Fx.proGlow
                            : null,
                      ),
                    ),
                  ),
                  Container(
                    width: 1.4,
                    height: h * 0.5,
                    margin: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(gradient: frame),
                  ),
                  Flexible(
                    child: Text(
                      widget.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: M3Fonts.head,
                        fontSize: h * 0.325,
                        fontWeight: FontWeight.w500,
                        color: subColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Crown overflows the frame on the left.
            Positioned(
              left: -crown * 0.36,
              top: -crown * 0.30,
              child: Icon3D(M3Icons.crown, size: crown, opacity: crownOpacity),
            ),
          ],
        ),
      ),
    );

    final padded = Padding(
      padding: EdgeInsets.only(left: crown * 0.3),
      child: badge,
    );
    if (widget.onTap == null) return padded;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () {
          SoundService().play(SfxType.tap);
          widget.onTap!();
        },
        child: padded,
      ),
    );
  }
}
