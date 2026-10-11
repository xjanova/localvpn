import 'package:flutter/material.dart';

import '../../services/sound_service.dart';
import '../../theme/m3/m3_theme.dart';
import 'm3_icons.dart';

enum GlossVariant { aqua, gold, red, green, glass }

enum GlossSize { small, medium, large }

/// Aero gloss button: rounded rectangle (never a pill — the owner dislikes
/// oval buttons), a hard light split at 50 %, and a gold ring on the
/// primary (aqua) and destructive (red) variants.
class GlossButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final String? icon3d;
  final VoidCallback? onPressed;
  final GlossVariant variant;
  final GlossSize size;
  final bool expand;
  final bool loading;
  final String? tooltip;

  const GlossButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.icon3d,
    this.variant = GlossVariant.aqua,
    this.size = GlossSize.medium,
    this.expand = false,
    this.loading = false,
    this.tooltip,
  });

  @override
  State<GlossButton> createState() => _GlossButtonState();
}

class _GlossButtonState extends State<GlossButton> {
  bool _hover = false;
  bool _down = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;

    final (LinearGradient fill, Color edge, Color fg, bool ring) =
        switch (widget.variant) {
      GlossVariant.aqua => (M3Fx.aquaGloss, M3Fx.aquaEdge, M3Fx.aquaText, true),
      GlossVariant.gold => (M3Fx.goldGloss, M3Fx.goldEdge, M3Fx.goldText, false),
      GlossVariant.red => (M3Fx.redGloss, M3Fx.redEdge, Colors.white, true),
      GlossVariant.green =>
        (M3Fx.greenGloss, M3Fx.greenEdge, M3Fx.greenText, false),
      GlossVariant.glass => (p.glassBtn, p.line, p.glassBtnText, false),
    };

    final (double height, EdgeInsets pad, double font, double iconSize) =
        switch (widget.size) {
      GlossSize.small => (30.0, const EdgeInsets.symmetric(horizontal: 11),
          12.5, 15.0),
      GlossSize.medium => (38.0, const EdgeInsets.symmetric(horizontal: 16),
          13.5, 17.0),
      GlossSize.large => (48.0, const EdgeInsets.symmetric(horizontal: 22),
          15.5, 20.0),
    };

    final radius = widget.size == GlossSize.large ? 12.0 : 10.0;
    final border = widget.variant == GlossVariant.glass
        ? Border.all(color: p.isNight ? p.line : p.inputLine)
        : Border.all(color: edge);

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: iconSize - 2,
              height: iconSize - 2,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            ),
          )
        else if (widget.icon3d != null)
          Padding(
            padding: const EdgeInsets.only(right: 7),
            child: Icon3D(widget.icon3d!, size: iconSize + 8),
          )
        else if (widget.icon != null)
          Padding(
            padding: const EdgeInsets.only(right: 7),
            child: Icon(widget.icon, size: iconSize, color: fg),
          ),
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: M3Fonts.head,
              fontSize: font,
              fontWeight: widget.variant == GlossVariant.glass
                  ? FontWeight.w500
                  : FontWeight.w600,
              color: fg,
              height: 1.1,
            ),
          ),
        ),
      ],
    );

    Widget body = Container(
      height: height,
      padding: pad,
      decoration: BoxDecoration(
        gradient: fill,
        borderRadius: BorderRadius.circular(radius),
        border: border,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  gradient: M3Fx.btnGloss,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(radius - 1),
                    topRight: Radius.circular(radius - 1),
                    bottomLeft: const Radius.circular(4),
                    bottomRight: const Radius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          if (_hover && _enabled)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(radius),
                  ),
                ),
              ),
            ),
          content,
        ],
      ),
    );

    if (ring) {
      body = Container(
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          gradient: M3Fx.goldRing,
          borderRadius: BorderRadius.circular(radius + 1),
          boxShadow: _hover && _enabled
              ? (widget.variant == GlossVariant.red
                  ? M3Fx.redGlow
                  : M3Fx.aquaGlow)
              : null,
        ),
        child: body,
      );
    }

    Widget button = AnimatedOpacity(
      opacity: _enabled || widget.loading ? 1 : 0.45,
      duration: const Duration(milliseconds: 150),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 90),
        child: body,
      ),
    );

    button = MouseRegion(
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: _enabled
            ? () {
                SoundService().play(SfxType.tap);
                widget.onPressed!();
              }
            : null,
        child: Semantics(
          button: true,
          enabled: _enabled,
          label: widget.label,
          child: button,
        ),
      ),
    );

    if (widget.expand) button = SizedBox(width: double.infinity, child: button);
    if (widget.tooltip != null) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// Small square glass button holding one Material icon (toolbar actions).
class GlossIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final Color? color;

  const GlossIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 34,
    this.color,
  });

  @override
  State<GlossIconButton> createState() => _GlossIconButtonState();
}

class _GlossIconButtonState extends State<GlossIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final enabled = widget.onPressed != null;
    Widget b = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        gradient: p.glassBtn,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: p.isNight ? p.line : p.inputLine),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                gradient: M3Fx.btnGloss,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                  bottomLeft: Radius.circular(3),
                  bottomRight: Radius.circular(3),
                ),
              ),
            ),
          ),
          if (_hover && enabled)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
          Icon(widget.icon,
              size: widget.size * 0.5, color: widget.color ?? p.glassBtnText),
        ],
      ),
    );
    b = Opacity(opacity: enabled ? 1 : 0.45, child: b);
    b = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled
            ? () {
                SoundService().play(SfxType.tap);
                widget.onPressed!();
              }
            : null,
        child: b,
      ),
    );
    if (widget.tooltip != null) {
      b = Tooltip(message: widget.tooltip!, child: b);
    }
    return b;
  }
}
