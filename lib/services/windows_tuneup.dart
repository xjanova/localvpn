import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/app_store.dart';
import '../platform/platform_info.dart';
import '../platform/windows_native.dart';

/// Result of one tweak.
class TuneupResult {
  final bool ok;
  final String message;
  const TuneupResult(this.ok, this.message);
}

/// Windows network tweaks that have a measurable effect on game latency,
/// each one reversible. All of them need the app to run as administrator.
///
/// What is deliberately NOT here: registry "network throttling" tweaks,
/// DNS changers, "RAM cleaners" — they do not change the round trip to a
/// game server.
class WindowsTuneup {
  WindowsTuneup._();

  static const _prefWlan = 'tuneup_wlan_iface';
  static const _prefPowerScheme = 'tuneup_power_scheme';
  static const _prefNagleGuid = 'tuneup_nagle_guid';

  static const _highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c';
  static final _guidRe = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');

  static bool _safeName(String s) =>
      s.isNotEmpty && !RegExp(r'["&|<>^%!\r\n]').hasMatch(s);

  static Future<ProcessResult> _run(String exe, List<String> args) =>
      Process.run(exe, args).timeout(const Duration(seconds: 15));

  // ── Wi-Fi background scanning ─────────────────────────────────────────
  // Windows scans for other Wi-Fi networks about once a minute while
  // connected; each scan takes the radio off-channel and shows up in game
  // as a 100–300 ms spike. Turning off auto-config for the session stops
  // the scans. Side effect: Windows will not reconnect on its own if the
  // Wi-Fi drops, so it is switched back on when the boost ends.

  static Future<TuneupResult> suppressWifiScan(String interfaceName) async {
    if (!isWindows) return const TuneupResult(false, 'ใช้ได้เฉพาะ Windows');
    if (!_safeName(interfaceName)) {
      return const TuneupResult(false, 'ชื่อการ์ด Wi-Fi ไม่รองรับ');
    }
    final r = await Process.run(
      'netsh wlan set autoconfig enabled=no interface="$interfaceName"',
      const [],
      runInShell: true,
    ).timeout(const Duration(seconds: 15));
    if (r.exitCode != 0) {
      return TuneupResult(false, _first(r) ?? 'ปิดการสแกน Wi-Fi ไม่สำเร็จ');
    }
    final prefs = await AppStore.instance();
    await prefs.setString(_prefWlan, interfaceName);
    return const TuneupResult(true, 'หยุดการสแกน Wi-Fi เบื้องหลังแล้ว');
  }

  static Future<TuneupResult> restoreWifiScan() async {
    if (!isWindows) return const TuneupResult(true, '');
    final prefs = await AppStore.instance();
    final name = prefs.getString(_prefWlan);
    if (name == null || !_safeName(name)) return const TuneupResult(true, '');
    final r = await Process.run(
      'netsh wlan set autoconfig enabled=yes interface="$name"',
      const [],
      runInShell: true,
    ).timeout(const Duration(seconds: 15));
    if (r.exitCode == 0) await prefs.remove(_prefWlan);
    return TuneupResult(r.exitCode == 0,
        r.exitCode == 0 ? 'เปิดการเชื่อมต่อ Wi-Fi อัตโนมัติคืนแล้ว' : (_first(r) ?? ''));
  }

  // ── Power plan ────────────────────────────────────────────────────────
  // Power-saving states on the CPU and the network card add wake-up delay
  // to every packet. High performance for the session, previous plan after.

  static Future<TuneupResult> highPerformancePower() async {
    if (!isWindows) return const TuneupResult(false, 'ใช้ได้เฉพาะ Windows');
    final cur = await _run('powercfg', ['/getactivescheme']);
    final guid = _guidRe.firstMatch(cur.stdout.toString())?.group(0);
    if (guid == null) {
      return const TuneupResult(false, 'อ่านแผนพลังงานปัจจุบันไม่ได้');
    }
    if (guid.toLowerCase() == _highPerformance) {
      return const TuneupResult(true, 'ใช้แผนประสิทธิภาพสูงอยู่แล้ว');
    }
    final r = await _run('powercfg', ['/setactive', _highPerformance]);
    if (r.exitCode != 0) {
      return const TuneupResult(false,
          'เครื่องนี้ไม่มีแผน "ประสิทธิภาพสูง" (พบบ่อยในโน้ตบุ๊ก Modern Standby)');
    }
    final prefs = await AppStore.instance();
    await prefs.setString(_prefPowerScheme, guid);
    return const TuneupResult(true, 'เปลี่ยนเป็นแผนพลังงานประสิทธิภาพสูงแล้ว');
  }

  static Future<TuneupResult> restorePower() async {
    if (!isWindows) return const TuneupResult(true, '');
    final prefs = await AppStore.instance();
    final guid = prefs.getString(_prefPowerScheme);
    if (guid == null || !_guidRe.hasMatch(guid)) {
      return const TuneupResult(true, '');
    }
    final r = await _run('powercfg', ['/setactive', guid]);
    if (r.exitCode == 0) await prefs.remove(_prefPowerScheme);
    return TuneupResult(r.exitCode == 0, '');
  }

  // ── Nagle's algorithm ─────────────────────────────────────────────────
  // Windows holds back small TCP packets (up to ~200 ms with delayed ACK).
  // Games that run over TCP (many MMOs, some mobile ports) feel that; UDP
  // games (most shooters) are not affected. Applies to new connections on
  // the given adapter. Stays until switched off.

  static String _ifaceKey(String guid) =>
      r'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\'
      '$guid';

  static Future<TuneupResult> disableNagle(String adapterGuid) async {
    if (!isWindows) return const TuneupResult(false, 'ใช้ได้เฉพาะ Windows');
    if (!RegExp(r'^\{[0-9A-Fa-f-]{36}\}$').hasMatch(adapterGuid)) {
      return const TuneupResult(false, 'รหัสการ์ดเครือข่ายไม่ถูกต้อง');
    }
    final key = _ifaceKey(adapterGuid);
    for (final v in const ['TcpAckFrequency', 'TCPNoDelay']) {
      final r = await _run('reg',
          ['add', key, '/v', v, '/t', 'REG_DWORD', '/d', '1', '/f']);
      if (r.exitCode != 0) {
        return TuneupResult(false, _first(r) ?? 'แก้ registry ไม่สำเร็จ');
      }
    }
    final prefs = await AppStore.instance();
    await prefs.setString(_prefNagleGuid, adapterGuid);
    return const TuneupResult(true,
        'ปิด Nagle แล้ว (มีผลกับการเชื่อมต่อใหม่ — เปิดเกมใหม่อีกครั้ง)');
  }

  static Future<TuneupResult> restoreNagle() async {
    if (!isWindows) return const TuneupResult(true, '');
    final prefs = await AppStore.instance();
    final guid = prefs.getString(_prefNagleGuid);
    if (guid == null) return const TuneupResult(true, '');
    final key = _ifaceKey(guid);
    for (final v in const ['TcpAckFrequency', 'TCPNoDelay']) {
      await _run('reg', ['delete', key, '/v', v, '/f']);
    }
    await prefs.remove(_prefNagleGuid);
    return const TuneupResult(true, 'คืนค่า Nagle เป็นค่าเริ่มต้นแล้ว');
  }

  static Future<bool> isNagleDisabled() async {
    final prefs = await AppStore.instance();
    return prefs.getString(_prefNagleGuid) != null;
  }

  /// Puts back the session tweaks if the app died while a boost was on.
  static Future<void> restoreLeftovers() async {
    if (!isWindows) return;
    try {
      if (!await WindowsNative.isElevated()) return;
      await restoreWifiScan();
      await restorePower();
    } catch (e) {
      debugPrint('tuneup restore: $e');
    }
  }

  static String? _first(ProcessResult r) {
    final text = '${r.stdout}\n${r.stderr}'.trim();
    if (text.isEmpty) return null;
    return text.split('\n').first.trim();
  }
}
