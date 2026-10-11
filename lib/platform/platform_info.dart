import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where the app is running. Kept in one place so screens never touch
/// `dart:io` Platform directly (and widget tests can still import them).
bool get isWindows => !kIsWeb && Platform.isWindows;
bool get isAndroid => !kIsWeb && Platform.isAndroid;
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// QR scanning needs a camera plugin that only exists on phones.
bool get canScanQr => isMobile;
