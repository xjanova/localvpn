import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../database/app_store.dart';
import '../platform/windows_native.dart';

/// Who this device is, for the licence server (docs: xmanstudio
/// ProductLicenseController, product `localvpn`).
///
/// - [machineId]: 32 hex chars, kept once made. Licences are bound to it.
/// - [hardwareHash]: from the hardware itself (Windows: SMBIOS UUID and
///   serials; Android: ANDROID_ID + Widevine id), so a reinstall of the app
///   or of Windows is still the same device and gets no second trial.
/// - [drmId] / [androidId]: Android only, let the server find a phone's
///   licence again after its machine id changed.
class DeviceIdentity {
  const DeviceIdentity({
    required this.machineId,
    this.hardwareHash,
    this.drmId,
    this.androidId,
    this.machineName,
    this.osVersion,
  });

  final String machineId;
  final String? hardwareHash;
  final String? drmId;
  final String? androidId;
  final String? machineName;
  final String? osVersion;

  /// What every licence request carries to identify the device.
  Map<String, String> get fields => {
        'machine_id': machineId,
        if (hardwareHash case final h?) 'hardware_hash': h,
        if (drmId case final d?) 'drm_id': d,
        if (androidId case final a?) 'android_id': a,
      };

  static const String _prefMachineId = 'device_id';
  static const MethodChannel _android =
      MethodChannel('com.xjanova.localvpn/device');

  static Future<DeviceIdentity> load() async {
    final store = await AppStore.instance();
    String? hardwareHash;
    String? drmId;
    String? androidId;
    String? machineName;
    String? osVersion;
    String fallbackSeed = 'unknown_platform_${Platform.operatingSystem}';

    final info = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        machineName = '${a.manufacturer} ${a.model}'.trim();
        osVersion = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
        final ids = await _androidIds();
        androidId = ids['androidId'];
        drmId = ids['drmId'];
        hardwareHash = hardwareHashFrom([
          if (androidId != null) 'aid:$androidId',
          if (drmId != null) 'drm:$drmId',
        ]);
        fallbackSeed = androidId != null
            ? 'android|$androidId'
            : 'android|${a.brand}|${a.model}|${a.id}';
      } else if (Platform.isWindows) {
        final w = await info.windowsInfo;
        machineName = w.computerName;
        osVersion = '${w.productName} ${w.displayVersion} (build ${w.buildNumber})';
        hardwareHash = windowsHardwareHash(await WindowsNative.hardwareIds());
        fallbackSeed = 'windows|${w.deviceId}';
      } else if (Platform.isLinux) {
        final l = await info.linuxInfo;
        machineName = l.prettyName;
        fallbackSeed = 'linux|${l.machineId ?? 'unknown'}';
      } else if (Platform.isMacOS) {
        final m = await info.macOsInfo;
        machineName = m.computerName;
        fallbackSeed = 'macos|${m.systemGUID ?? 'unknown'}';
      }
    } catch (e) {
      debugPrint('Device info unavailable: $e');
    }

    // A machine id made by an earlier version stays: licences are bound to
    // it. (On Android those were per model; the hardware ids sent with every
    // request let the server tell such phones apart from now on.)
    var machineId = store.getString(_prefMachineId);
    if (machineId == null || machineId.length < 32) {
      machineId = sha256.convert(utf8.encode(fallbackSeed)).toString().substring(0, 32);
      await store.setString(_prefMachineId, machineId);
    }

    return DeviceIdentity(
      machineId: machineId,
      hardwareHash: hardwareHash,
      drmId: drmId,
      androidId: androidId,
      machineName: machineName,
      osVersion: osVersion,
    );
  }

  static Future<Map<String, String>> _androidIds() async {
    try {
      final m = await _android
          .invokeMethod<Map<dynamic, dynamic>>('getIds')
          .timeout(const Duration(seconds: 5));
      return {
        for (final e in (m ?? const {}).entries)
          if (e.value is String && (e.value as String).isNotEmpty)
            '${e.key}': e.value as String,
      };
    } catch (e) {
      debugPrint('Android device ids unavailable: $e');
      return const {};
    }
  }

  /// SHA-256 of the parts that are real, or null when none is (better no
  /// hash than one that thousands of boards share).
  @visibleForTesting
  static String? hardwareHashFrom(List<String> parts) {
    if (parts.isEmpty) return null;
    return sha256.convert(utf8.encode('lvpn-hw|${parts.join('|')}')).toString();
  }

  /// The Windows hash from SMBIOS, leaving out the placeholder values
  /// boards ship with ("To be filled by O.E.M.", all-zero UUIDs …).
  @visibleForTesting
  static String? windowsHardwareHash(Map<String, String> ids) {
    final parts = <String>[];
    final uuid = ids['uuid']?.toLowerCase();
    if (uuid != null && isRealUuid(uuid)) parts.add('uuid:$uuid');
    for (final key in const ['systemSerial', 'boardSerial', 'chassisSerial']) {
      final v = ids[key]?.trim();
      if (v != null && isRealSerial(v)) parts.add('$key:${v.toUpperCase()}');
    }
    return hardwareHashFrom(parts);
  }

  @visibleForTesting
  static bool isRealUuid(String hex) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(hex)) return false;
    if (RegExp(r'^(0+|f+)$').hasMatch(hex)) return false;
    // 03000200-0400-0500-0006-000700080009 and its byte-swapped form: a
    // well-known placeholder on cheap boards.
    const placeholders = {
      '03000200040005000006000700080009',
      '00020003000400050006000700080009',
    };
    return !placeholders.contains(hex);
  }

  @visibleForTesting
  static bool isRealSerial(String s) {
    if (s.length < 4) return false;
    final lower = s.toLowerCase();
    const junk = [
      'to be filled',
      'default string',
      'system serial',
      'serial number',
      'not applicable',
      'not specified',
      'none',
      'n/a',
      'o.e.m',
      'oem',
      '123456789',
      'chassis serial',
      'base board serial',
      'invalid',
    ];
    if (junk.any(lower.contains)) return false;
    // "0000000", "XXXXXXX", "........"
    if (RegExp(r'^(.)\1+$').hasMatch(s)) return false;
    return true;
  }
}
