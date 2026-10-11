import 'package:flutter/widgets.dart';

import '../services/license_service.dart';
import '../widgets/m3/m3.dart';

/// Activates [key]. When it is already on its two devices, asks whether to
/// move it to this one (the device seen least recently loses its place).
/// True = active here, false = failed (see the state's error), null = the
/// user kept it where it was.
Future<bool?> activateLicense(
  BuildContext context,
  LicenseService license,
  String key,
) async {
  final ok = await license.activate(key);
  if (ok ||
      license.state.errorCode != 'ALREADY_ACTIVATED_OTHER_DEVICE' ||
      !context.mounted) {
    return ok;
  }
  final why = license.state.errorMessage;
  license.clearError();
  final move = await m3Confirm(
    context,
    icon3d: M3Icons.devicePc,
    title: 'ย้าย License มาเครื่องนี้?',
    message: '${why ?? 'License นี้ใช้ครบจำนวนเครื่องแล้ว'}\n\n'
        'เครื่องที่ไม่ได้เปิดใช้นานที่สุดจะถูกปลดออก และกลับไปใช้แพ็กเกจฟรี',
    confirmLabel: 'ย้ายมาเครื่องนี้',
    cancelLabel: 'ไม่ย้าย',
    destructive: true,
  );
  if (!move || !context.mounted) return null;
  return license.activate(key, forceRebind: true);
}

/// "เหลือ N วัน" for a trial or a term, from the server's count.
String daysLeftLabel(int? days) =>
    days == null ? '' : (days > 0 ? 'เหลือ $days วัน' : 'วันสุดท้าย');
