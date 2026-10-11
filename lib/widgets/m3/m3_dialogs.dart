import 'package:flutter/material.dart';

import '../../theme/m3/m3_theme.dart';
import 'gloss_button.dart';
import 'm3_icons.dart';

/// Glass dialog with a 3D icon, a title, a body and gloss buttons.
Future<T?> showM3Dialog<T>(
  BuildContext context, {
  String? icon3d,
  required String title,
  String? message,
  Widget? content,
  List<Widget> Function(BuildContext dialogContext)? actions,
  bool barrierDismissible = true,
  double maxWidth = 460,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: context.m3.scrim,
    builder: (ctx) {
      final p = ctx.m3;
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            decoration: BoxDecoration(
              gradient: p.drawerFill,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.popupLine),
              boxShadow: p.cardShadow,
            ),
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (icon3d != null) ...[
                        Icon3D(icon3d, size: 46),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text(title, style: M3Text.h2(ctx).copyWith(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 12),
                    Text(message,
                        style: M3Text.body(ctx).copyWith(color: p.text2)),
                  ],
                  if (content != null) ...[
                    const SizedBox(height: 14),
                    content,
                  ],
                  if (actions != null) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      runSpacing: 10,
                      children: actions(ctx),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Yes/no question. Destructive actions get a red confirm button.
Future<bool> m3Confirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'ยืนยัน',
  String cancelLabel = 'ยกเลิก',
  bool destructive = false,
  String? icon3d,
}) async {
  final ok = await showM3Dialog<bool>(
    context,
    icon3d: icon3d,
    title: title,
    message: message,
    actions: (ctx) => [
      GlossButton(
        label: cancelLabel,
        variant: GlossVariant.glass,
        onPressed: () => Navigator.of(ctx).pop(false),
      ),
      GlossButton(
        label: confirmLabel,
        variant: destructive ? GlossVariant.red : GlossVariant.aqua,
        onPressed: () => Navigator.of(ctx).pop(true),
      ),
    ],
  );
  return ok ?? false;
}

/// Short floating message.
void m3Toast(
  BuildContext context,
  String message, {
  M3Tone tone = M3Tone.cyan,
  Duration duration = const Duration(seconds: 3),
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final p = context.m3;
  final icon = switch (tone) {
    M3Tone.green => Icons.check_circle_rounded,
    M3Tone.red => Icons.error_rounded,
    M3Tone.amber || M3Tone.gold => Icons.warning_amber_rounded,
    _ => Icons.info_rounded,
  };
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: duration,
        action: action,
        width: MediaQuery.sizeOf(context).width > 700 ? 520 : null,
        content: Row(
          children: [
            Icon(icon, color: p.toneColor(tone), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message,
                  style: M3Text.body(context).copyWith(fontSize: 13.5)),
            ),
          ],
        ),
      ),
    );
}

/// Glass bottom sheet (mobile menus, pickers).
Future<T?> showM3Sheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext) builder,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    barrierColor: context.m3.scrim,
    builder: (ctx) {
      final p = ctx.m3;
      return Container(
        decoration: BoxDecoration(
          gradient: p.drawerFill,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: p.popupLine),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: p.thumb,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Flexible(child: builder(ctx)),
            ],
          ),
        ),
      );
    },
  );
}
