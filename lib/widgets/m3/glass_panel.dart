import 'package:flutter/material.dart';

import '../../services/sound_service.dart';
import '../../theme/m3/m3_theme.dart';

/// The glass card: 3-stop vertical fill, a 1 px light-catching edge, a soft
/// gloss over the top and a deep drop shadow. No backdrop blur (it would cost
/// a lot on Windows and the wallpaper is calm enough without it).
class GlassPanel extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;

  /// Brighter fill, for the hero card or a selected item.
  final bool highlight;

  /// Top gloss. Turn it off behind big headlines (it washes them out).
  final bool gloss;

  /// Tints the edge (e.g. green when connected, red for errors).
  final Color? accent;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final bool shadow;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.radius = 20,
    this.highlight = false,
    this.gloss = true,
    this.accent,
    this.onTap,
    this.width,
    this.height,
    this.shadow = true,
  });

  @override
  State<GlassPanel> createState() => _GlassPanelState();
}

class _GlassPanelState extends State<GlassPanel> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final interactive = widget.onTap != null;
    final hi = widget.highlight || (interactive && _hover);
    final r = BorderRadius.circular(widget.radius);
    final inner = BorderRadius.circular(widget.radius - 1);

    final edge = widget.accent != null
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              widget.accent!.withValues(alpha: 0.95),
              widget.accent!.withValues(alpha: 0.45),
              widget.accent!.withValues(alpha: 0.30),
            ],
            stops: const [0, 0.45, 1],
          )
        : p.glassLine;

    Widget card = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      decoration: BoxDecoration(
        borderRadius: r,
        gradient: edge,
        boxShadow: widget.shadow ? p.cardShadow : null,
      ),
      padding: const EdgeInsets.all(1),
      child: ClipRRect(
        borderRadius: inner,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: hi ? p.glassFillHi : p.glassFill,
          ),
          child: Stack(
            children: [
              if (widget.gloss)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 46,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(
                                alpha: p.isNight ? 0.06 : 0.45),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Thin inner highlight along the top edge.
              Positioned(
                left: 12,
                right: 12,
                top: 0,
                height: 1,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: p.isNight ? 0.35 : 0.9),
                        Colors.white.withValues(alpha: 0),
                      ]),
                    ),
                  ),
                ),
              ),
              Padding(padding: widget.padding, child: widget.child),
            ],
          ),
        ),
      ),
    );

    if (!interactive) return card;

    card = AnimatedScale(
      scale: _down ? 0.985 : 1,
      duration: const Duration(milliseconds: 90),
      child: card,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: () {
          SoundService().play(SfxType.tap);
          widget.onTap!();
        },
        child: card,
      ),
    );
  }
}

/// A recessed box inside a card (key/value blocks, IP readouts).
class M3Inset extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  const M3Inset({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    this.radius = 14,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.inset,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.line),
      ),
      child: child,
    );
  }
}

/// Gold hairline divider (sidebar, hero cards).
class M3GoldLine extends StatelessWidget {
  final double height;
  final EdgeInsetsGeometry margin;

  const M3GoldLine({
    super.key,
    this.height = 1.2,
    this.margin = const EdgeInsets.symmetric(vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: margin,
      decoration: const BoxDecoration(gradient: M3Fx.goldLine),
    );
  }
}
