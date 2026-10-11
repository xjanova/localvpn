import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../services/sound_service.dart';
import '../../theme/m3/m3_theme.dart';
import 'glass_panel.dart';
import 'm3_icons.dart';

/// Small rounded tag (status words, counts, labels).
class M3Tag extends StatelessWidget {
  final String label;
  final M3Tone tone;
  final IconData? icon;
  final bool dot;

  const M3Tag(
    this.label, {
    super.key,
    this.tone = M3Tone.cyan,
    this.icon,
    this.dot = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final fg = p.toneText(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2.5),
      decoration: BoxDecoration(
        color: p.toneSoft(tone),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: p.toneSoftLine(tone)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            StatusOrb(color: p.toneColor(tone), size: 7, pulse: false),
            const SizedBox(width: 5),
          ] else if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: M3Fonts.ui,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: fg,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Aqua gloss count badge (sidebar items).
class M3Count extends StatelessWidget {
  final int count;
  final bool red;

  const M3Count(this.count, {super.key, this.red = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 26),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: red ? M3Fx.redGloss : M3Fx.aquaGloss,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0x99FFFFFF)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          fontFamily: M3Fonts.head,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: red ? Colors.white : M3Fx.aquaText,
          height: 1,
        ),
      ),
    );
  }
}

/// Glowing status orb (online / connected / error). Round on purpose —
/// orbs and switch tracks are the only round shapes in the kit.
class StatusOrb extends StatelessWidget {
  final Color color;
  final double size;
  final bool pulse;

  const StatusOrb({
    super.key,
    required this.color,
    this.size = 10,
    this.pulse = true,
  });

  @override
  Widget build(BuildContext context) {
    final orb = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 0.9,
          colors: [
            Color.lerp(color, Colors.white, 0.65)!,
            color,
            Color.lerp(color, Colors.black, 0.35)!,
          ],
          stops: const [0, 0.55, 1],
        ),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: size),
        ],
      ),
    );
    if (!pulse) return orb;
    return orb
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fade(begin: 1, end: 0.55, duration: 1100.ms, curve: Curves.easeInOut);
  }
}

/// Filter chip: glass when idle, aqua gloss when selected.
class M3Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  const M3Chip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final fg = selected ? M3Fx.aquaText : p.text2;
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                SoundService().play(SfxType.tap);
                onTap!();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: BoxDecoration(
            gradient: selected ? M3Fx.aquaGloss : p.glassBtn,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected
                  ? M3Fx.aquaEdge
                  : (p.isNight ? p.line : p.inputLine),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontFamily: M3Fonts.ui,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Glass track with a chrome knob.
class M3Switch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const M3Switch({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled
              ? () {
                  SoundService().play(SfxType.tap);
                  onChanged!(!value);
                }
              : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 46,
            height: 26,
            decoration: BoxDecoration(
              gradient: value ? M3Fx.aquaGloss : null,
              color: value ? null : p.track,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: value ? M3Fx.aquaEdge : (p.isNight ? p.line : p.inputLine),
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Opacity(
                    opacity: value ? 1 : 0.5,
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        gradient: M3Fx.btnGloss,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                AnimatedAlign(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: const Color(0xFF7D8997), width: 0.8),
                      gradient: const RadialGradient(
                        center: Alignment(-0.3, -0.4),
                        radius: 0.8,
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFDDE5EC),
                          Color(0xFF9AA6B3),
                        ],
                        stops: [0, 0.55, 1],
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x55000000),
                          blurRadius: 3,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A switch with a title and a description, for settings lists.
class M3SwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? icon3d;

  const M3SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
    this.icon3d,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (icon3d != null) ...[
            Icon3D(icon3d!, size: 34),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: M3Text.h3(context)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: M3Text.sub(context)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          M3Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// In-page notice strip.
class M3Banner extends StatelessWidget {
  final M3Tone tone;
  final String title;
  final String? message;
  final IconData? icon;
  final String? icon3d;
  final Widget? action;

  const M3Banner({
    super.key,
    required this.title,
    this.message,
    this.tone = M3Tone.amber,
    this.icon,
    this.icon3d,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final leading = icon3d != null
        ? Icon3D(icon3d!, size: 36)
        : (icon != null
            ? Icon(icon, color: p.toneColor(tone), size: 22)
            : null);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.isNight ? p.toneText(tone) : p.toneColor(tone),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 2),
          Text(
            message!,
            style: TextStyle(
              fontFamily: M3Fonts.ui,
              fontSize: 12.5,
              height: 1.4,
              color: p.text2,
            ),
          ),
        ],
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        // Tone tint over a near-opaque base: banners often sit on the bright
        // part of the wallpaper, where a bare tint left the text unreadable.
        color: Color.alphaBlend(
          p.toneSoft(tone),
          p.isNight ? const Color(0xE60A1430) : const Color(0xF0FFFFFF),
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.toneSoftLine(tone)),
      ),
      child: LayoutBuilder(builder: (context, c) {
        // Narrow (phones): the action drops under the text.
        final stack = action != null && c.maxWidth < 520;
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 12)],
            Expanded(child: text),
            if (action != null && !stack) ...[
              const SizedBox(width: 12),
              action!,
            ],
          ],
        );
        if (!stack) return row;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row,
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: action!),
          ],
        );
      }),
    );
  }
}

/// Page title block: big 3D icon, H1 and a one-line description.
class M3PageHeader extends StatelessWidget {
  final String icon3d;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onBack;

  const M3PageHeader({
    super.key,
    required this.icon3d,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (onBack != null) ...[
          _BackButton(onTap: onBack!),
          const SizedBox(width: 10),
        ],
        Icon3D(icon3d, size: narrow ? 44 : 56),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: M3Text.h1(context)
                    .copyWith(fontSize: narrow ? 22 : 26),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  // Sits on the wallpaper, not on glass: brighter colour and
                  // the title's shadow so it survives the light ribbons.
                  style: M3Text.sub(context).copyWith(
                    color: context.m3.text2,
                    fontWeight: FontWeight.w500,
                    shadows: context.m3.titleShadow,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Tooltip(
      message: 'ย้อนกลับ',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            SoundService().play(SfxType.tap);
            widget.onTap();
          },
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: p.glassBtn,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.isNight ? p.line : p.inputLine),
              boxShadow: _hover ? M3Fx.aquaGlow : null,
            ),
            child: Icon(Icons.arrow_back_rounded,
                size: 20, color: p.glassBtnText),
          ),
        ),
      ),
    );
  }
}

/// Card title row: small 3D icon, H2 title, optional trailing widget.
class M3CardHeader extends StatelessWidget {
  final String? icon3d;
  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const M3CardHeader({
    super.key,
    required this.title,
    this.icon3d,
    this.icon,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Row(
      children: [
        if (icon3d != null) ...[
          Icon3D(icon3d!, size: 32),
          const SizedBox(width: 10),
        ] else if (icon != null) ...[
          Icon(icon, size: 20, color: p.cyan),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: M3Text.h2(context)),
              if (subtitle != null)
                Text(subtitle!, style: M3Text.sub(context)),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Stat tile: label, a big glowing number and a 3D icon in the corner.
class M3StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final String icon3d;
  final M3Tone? tone;
  final VoidCallback? onTap;

  const M3StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon3d,
    this.sub,
    this.tone,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final color = tone == null ? null : p.toneColor(tone!);
    return GlassPanel(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            child: Icon3D(icon3d, size: 58),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 60),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: M3Fonts.head,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: p.text2,
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: M3Text.num(context,
                        size: 34, color: color, red: tone == M3Tone.red),
                  ),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    sub!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: M3Text.sub(context).copyWith(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-state block with a floating 3D icon.
class M3EmptyState extends StatelessWidget {
  final String icon3d;
  final String title;
  final String? message;
  final Widget? action;

  const M3EmptyState({
    super.key,
    required this.icon3d,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon3D(icon3d, size: 96, opacity: 0.95)
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .moveY(begin: 0, end: -8, duration: 2200.ms, curve: Curves.easeInOut),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center, style: M3Text.h2(context)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!,
                textAlign: TextAlign.center, style: M3Text.sub(context)),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// Glass tube progress bar.
class M3ProgressBar extends StatelessWidget {
  /// 0..1, or null for an indeterminate shimmer.
  final double? value;
  final double height;
  final M3Tone tone;

  const M3ProgressBar({
    super.key,
    this.value,
    this.height = 10,
    this.tone = M3Tone.cyan,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final fill = switch (tone) {
      M3Tone.red => M3Fx.barRed,
      M3Tone.green => M3Fx.barGreen,
      M3Tone.gold || M3Tone.amber => M3Fx.barGold,
      _ => M3Fx.barAqua,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: p.track,
          borderRadius: BorderRadius.circular(height / 2),
        ),
        child: value == null
            ? Container(decoration: BoxDecoration(gradient: fill))
                .animate(onPlay: (c) => c.repeat())
                .shimmer(duration: 1400.ms, color: Colors.white54)
            : LayoutBuilder(
                builder: (context, c) => Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: c.maxWidth * value!.clamp(0.0, 1.0),
                    decoration: BoxDecoration(gradient: fill),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(gradient: M3Fx.barShine),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// A list row inside a card: hover highlight, optional leading/trailing.
class M3Row extends StatefulWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool selected;

  const M3Row({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.selected = false,
  });

  @override
  State<M3Row> createState() => _M3RowState();
}

class _M3RowState extends State<M3Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final bg = widget.selected
        ? p.select
        : (_hover && widget.onTap != null ? p.hover : p.row);
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                SoundService().play(SfxType.tap);
                widget.onTap!();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.line.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: M3Text.h3(context),
                    ),
                    if (widget.subtitleWidget != null)
                      widget.subtitleWidget!
                    else if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: M3Text.sub(context),
                      ),
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 10),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Key/value line ("Virtual IP   10.10.0.4").
class M3KeyValue extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;

  const M3KeyValue(
    this.label,
    this.value, {
    super.key,
    this.mono = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: M3Text.sub(context)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono
                  ? M3Text.mono(context, size: 12.5)
                  : M3Text.body(context).copyWith(fontSize: 13),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
  }
}

/// Text field with an optional label above it.
class M3Field extends StatelessWidget {
  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final bool obscure;
  final IconData? prefixIcon;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final bool mono;
  final int maxLines;
  final int? maxLength;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;

  const M3Field({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.obscure = false,
    this.prefixIcon,
    this.suffix,
    this.keyboardType,
    this.onSubmitted,
    this.onChanged,
    this.validator,
    this.mono = false,
    this.maxLines = 1,
    this.maxLength,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.textInputAction,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      onFieldSubmitted: onSubmitted,
      onChanged: onChanged,
      validator: validator,
      maxLines: obscure ? 1 : maxLines,
      maxLength: maxLength,
      enabled: enabled,
      autofocus: autofocus,
      focusNode: focusNode,
      textInputAction: textInputAction,
      style: mono
          ? M3Text.mono(context, size: 13.5, color: context.m3.text)
          : M3Text.body(context),
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 19),
        suffixIcon: suffix,
      ),
    );
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Text(label!, style: M3Text.label(context)),
        ),
        field,
      ],
    );
  }
}

/// Section title between cards.
class M3SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const M3SectionTitle(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10, left: 2),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              gradient: M3Fx.aquaGloss,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: M3Text.h2(context))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Wraps content in a centred column with a maximum width (desktop) and the
/// standard page padding.
class M3PageBody extends StatelessWidget {
  final List<Widget> children;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final Future<void> Function()? onRefresh;

  const M3PageBody({
    super.key,
    required this.children,
    this.maxWidth = 1180,
    this.padding,
    this.controller,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final pad = padding ??
        EdgeInsets.fromLTRB(w < 600 ? 14 : 22, w < 600 ? 12 : 18,
            w < 600 ? 14 : 22, 28);
    Widget list = ListView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: pad,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
    if (onRefresh != null) {
      list = RefreshIndicator(
        onRefresh: onRefresh!,
        color: context.m3.cyan,
        backgroundColor: context.m3.popup,
        child: list,
      );
    }
    return list;
  }
}
