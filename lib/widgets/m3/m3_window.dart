import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../platform/platform_info.dart';
import '../../theme/m3/m3_theme.dart';
import 'm3_icons.dart';

/// Full-bleed wallpaper of the active palette with its shade on top.
class M3Wallpaper extends StatelessWidget {
  const M3Wallpaper({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: p.bg),
        Image.asset(
          p.wallpaper,
          fit: BoxFit.cover,
          alignment: Alignment.topLeft,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
        ColoredBox(color: p.winShade),
      ],
    );
  }
}

/// Custom Windows title bar (the native one is hidden by window_manager):
/// logo, title, an optional status chip and glass min/max/close capsules.
class M3TitleBar extends StatefulWidget {
  final String title;
  final Widget? chip;

  const M3TitleBar({super.key, required this.title, this.chip});

  static const double height = 38;

  @override
  State<M3TitleBar> createState() => _M3TitleBarState();
}

class _M3TitleBarState extends State<M3TitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (isWindows) {
      windowManager.addListener(this);
      windowManager.isMaximized().then((m) {
        if (mounted) setState(() => _maximized = m);
      });
    }
  }

  @override
  void dispose() {
    if (isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      height: M3TitleBar.height,
      decoration: BoxDecoration(
        gradient: p.titleFill,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  children: [
                    const Icon3D(M3Icons.logo, size: 24),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: M3Fonts.head,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (widget.chip != null) ...[
                      const SizedBox(width: 10),
                      widget.chip!,
                    ],
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          _WinButton(
            icon: Icons.remove_rounded,
            tooltip: 'ย่อ',
            onTap: () => windowManager.minimize(),
          ),
          _WinButton(
            icon: _maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            tooltip: _maximized ? 'คืนขนาด' : 'ขยาย',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinButton(
            icon: Icons.close_rounded,
            tooltip: 'ปิด',
            close: true,
            onTap: () => windowManager.close(),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool close;

  const _WinButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.close = false,
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              width: 42,
              height: 24,
              decoration: BoxDecoration(
                gradient: widget.close ? M3Fx.redGloss : p.glassBtn,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: widget.close
                      ? M3Fx.redEdge
                      : (p.isNight ? p.line : p.inputLine),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: const BoxDecoration(
                        gradient: M3Fx.btnGloss,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(6),
                          topRight: Radius.circular(6),
                          bottomLeft: Radius.circular(3),
                          bottomRight: Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  if (_hover)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ),
                  Icon(
                    widget.icon,
                    size: 14,
                    color: widget.close ? Colors.white : p.glassBtnText,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
