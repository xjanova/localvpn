import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_info.dart';

/// Result of an ICMP echo run. [rtts] holds one entry per probe in ms,
/// -1 for a probe that got no answer.
class IcmpResult {
  final bool ok;
  final String? ip;
  final List<double> rtts;

  const IcmpResult({required this.ok, this.ip, this.rtts = const []});

  List<double> get answered => rtts.where((r) => r >= 0).toList();
  double get lossPercent =>
      rtts.isEmpty ? 100 : (rtts.length - answered.length) * 100 / rtts.length;
  double? get minMs =>
      answered.isEmpty ? null : answered.reduce((a, b) => a < b ? a : b);
  double? get avgMs => answered.isEmpty
      ? null
      : answered.reduce((a, b) => a + b) / answered.length;

  /// Mean absolute difference between consecutive answered probes.
  double? get jitterMs {
    final a = answered;
    if (a.length < 2) return null;
    var sum = 0.0;
    for (var i = 1; i < a.length; i++) {
      sum += (a[i] - a[i - 1]).abs();
    }
    return sum / (a.length - 1);
  }
}

/// The network adapter Windows currently uses to reach the internet.
class ActiveAdapter {
  final String name;
  final String description;
  final String guid;
  final String type; // wifi | ethernet | other
  final int speedMbps;
  final String? ipv4;
  final String? gateway;

  const ActiveAdapter({
    required this.name,
    required this.description,
    required this.guid,
    required this.type,
    required this.speedMbps,
    this.ipv4,
    this.gateway,
  });

  bool get isWifi => type == 'wifi';

  factory ActiveAdapter.fromMap(Map<dynamic, dynamic> m) => ActiveAdapter(
        name: m['name'] as String? ?? '',
        description: m['description'] as String? ?? '',
        guid: m['guid'] as String? ?? '',
        type: m['type'] as String? ?? 'other',
        speedMbps: (m['speedMbps'] as num?)?.toInt() ?? 0,
        ipv4: m['ipv4'] as String?,
        gateway: m['gateway'] as String?,
      );
}

/// Calls into the Windows runner (windows/runner/native_channels.cpp).
/// Every method is a safe no-op on other platforms.
class WindowsNative {
  WindowsNative._();

  static const MethodChannel _channel =
      MethodChannel('com.xjanova.localvpn/windows');

  static Future<bool> isElevated() async {
    if (!isWindows) return true;
    try {
      return await _channel.invokeMethod<bool>('isElevated') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts an elevated copy of the app (UAC prompt). Returns false when the
  /// user declines. The caller should quit right after a true result.
  static Future<bool> relaunchAsAdmin() async {
    if (!isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('relaunchAsAdmin') ?? false;
    } on PlatformException catch (e) {
      debugPrint('relaunchAsAdmin: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> quit() async {
    if (!isWindows) return;
    try {
      await _channel.invokeMethod('quit');
    } on MissingPluginException {
      // nothing to do
    }
  }

  static Future<IcmpResult> icmpPing(
    String host, {
    int count = 5,
    int timeoutMs = 1000,
  }) async {
    if (!isWindows) return const IcmpResult(ok: false);
    try {
      final m = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'icmpPing',
        {'host': host, 'count': count, 'timeoutMs': timeoutMs},
      );
      if (m == null || m['ok'] != true) return const IcmpResult(ok: false);
      final rtts = (m['rtts'] as List? ?? const [])
          .map((e) => (e as num).toDouble())
          .toList();
      return IcmpResult(ok: true, ip: m['ip'] as String?, rtts: rtts);
    } on PlatformException {
      return const IcmpResult(ok: false);
    } on MissingPluginException {
      return const IcmpResult(ok: false);
    }
  }

  /// SMBIOS identity: `uuid`, `systemSerial`, `boardSerial`, `chassisSerial`
  /// (raw; the caller drops placeholder values). Empty when unreadable.
  static Future<Map<String, String>> hardwareIds() async {
    if (!isWindows) return const {};
    try {
      final m =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('hardwareIds');
      return {
        for (final e in (m ?? const {}).entries)
          if (e.value is String) '${e.key}': e.value as String,
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  static Future<ActiveAdapter?> activeAdapter() async {
    if (!isWindows) return null;
    try {
      final m =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getActiveAdapter');
      return m == null ? null : ActiveAdapter.fromMap(m);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
