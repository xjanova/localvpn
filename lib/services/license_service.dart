import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/license_state.dart';

class LicenseService extends ChangeNotifier {
  static const String _baseUrl =
      'https://xman4289.com/api/v1/product/localvpn';
  static const String _purchaseBaseUrl = 'https://xman4289.com/localvpn/buy';

  static const String _prefLicenseKey = 'license_key_enc';
  static const String _prefLicenseType = 'license_type';
  static const String _prefLicenseExpiry = 'license_expiry';
  static const String _prefLastValidation = 'last_validation';
  static const String _prefLastKnownTime = 'last_known_time';
  static const String _prefDeviceId = 'device_id';
  static const String _prefDemoStarted = 'demo_started';
  static const String _prefSalt = '_lk_salt';

  LicenseState _state = const LicenseState.initial();
  LicenseState get state => _state;

  String? _deviceId;
  String? get deviceId => _deviceId;

  SharedPreferences? _cachedPrefs;

  bool _isProcessing = false;
  bool get isProcessing => _isProcessing;

  Future<void> init() async {
    _state = const LicenseState(status: LicenseStatus.checking);
    notifyListeners();

    await _generateDeviceId();
    _cachedPrefs = await SharedPreferences.getInstance();
    await _deriveKey(); // Ensure salt is generated on first launch

    if (_detectClockTamper() || await _checkClockTamperAsync()) {
      _state = LicenseState(
        status: LicenseStatus.none,
        deviceId: _deviceId,
        errorMessage: 'ตรวจพบการเปลี่ยนแปลงเวลาของอุปกรณ์',
      );
      notifyListeners();
      return;
    }

    await _saveLastKnownTime();

    final prefs = await SharedPreferences.getInstance();
    final encryptedKey = prefs.getString(_prefLicenseKey);

    if (encryptedKey != null && encryptedKey.isNotEmpty) {
      final licenseKey = _decrypt(encryptedKey);
      if (licenseKey.isNotEmpty) {
        await validate(licenseKey);
        return;
      }
    }

    await checkMachine();
  }

  Future<void> _generateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_prefDeviceId);

    if (cached != null && cached.isNotEmpty) {
      _deviceId = cached;
      return;
    }

    final deviceInfo = DeviceInfoPlugin();
    String rawId = '';

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      // Note: Do NOT include android.fingerprint — it changes on OS updates,
      // which would break license recovery via checkMachine().
      rawId =
          '${android.brand}|${android.model}|${android.id}';
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      rawId =
          '${ios.name}|${ios.model}|${ios.identifierForVendor ?? "unknown"}';
    } else if (Platform.isWindows) {
      final windowsInfo = await deviceInfo.windowsInfo;
      rawId = 'windows|${windowsInfo.computerName}|${windowsInfo.deviceId}';
    } else if (Platform.isLinux) {
      final linuxInfo = await deviceInfo.linuxInfo;
      rawId = 'linux|${linuxInfo.machineId ?? "unknown"}|${linuxInfo.name}';
    } else if (Platform.isMacOS) {
      final macInfo = await deviceInfo.macOsInfo;
      rawId = 'macos|${macInfo.systemGUID ?? "unknown"}|${macInfo.computerName}|${macInfo.model}';
    } else {
      rawId = 'unknown_platform_${Platform.operatingSystem}';
    }

    final hash = sha256.convert(utf8.encode(rawId));
    _deviceId = hash.toString().substring(0, 32);

    await prefs.setString(_prefDeviceId, _deviceId!);
  }

  bool _detectClockTamper() {
    // Synchronous check not possible; async check done via _checkClockTamperAsync
    return false;
  }

  Future<bool> _checkClockTamperAsync() async {
    final prefs = await SharedPreferences.getInstance();
    final lastKnownStr = prefs.getString(_prefLastKnownTime);
    if (lastKnownStr == null) return false;

    final lastKnown = DateTime.tryParse(lastKnownStr);
    if (lastKnown == null) return false;

    final now = DateTime.now();
    if (now.isBefore(lastKnown.subtract(const Duration(hours: 1)))) {
      return true;
    }
    return false;
  }

  Future<void> _saveLastKnownTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLastKnownTime, DateTime.now().toIso8601String());
  }

  Future<void> registerDevice() async {
    if (_deviceId == null) await _generateDeviceId();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/register-device'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'machine_id': _deviceId,
              'platform': Platform.operatingSystem,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200 && response.statusCode != 201) {
        debugPrint('Device registration returned ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Device registration error: $e');
    }
  }

  Future<bool> activate(String licenseKey) async {
    final sanitized = licenseKey.trim();
    if (sanitized.isEmpty) return false;

    _isProcessing = true;
    notifyListeners();

    try {
      if (_deviceId == null) await _generateDeviceId();

      final response = await http
          .post(
            Uri.parse('$_baseUrl/activate'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'license_key': sanitized,
              'machine_id': _deviceId,
              'platform': Platform.operatingSystem,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefLicenseKey, _encrypt(sanitized));
        await prefs.setString(
          _prefLicenseType,
          data['license_type'] as String? ?? 'unknown',
        );

        final expiry = data['expires_at'] as String?;
        if (expiry != null) {
          await prefs.setString(_prefLicenseExpiry, expiry);
        }

        await prefs.setString(
          _prefLastValidation,
          DateTime.now().toIso8601String(),
        );

        _state = LicenseState(
          status: LicenseStatus.active,
          licenseKey: sanitized,
          licenseType: data['license_type'] as String?,
          expiresAt: expiry != null ? DateTime.tryParse(expiry) : null,
          deviceId: _deviceId,
        );
        notifyListeners();
        return true;
      } else {
        _state = _state.copyWith(
          errorMessage:
              data['message'] as String? ?? 'ไม่สามารถเปิดใช้งาน License ได้',
        );
        notifyListeners();
        return false;
      }
    } catch (e) {
      _state = _state.copyWith(
        errorMessage: 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ กรุณาลองใหม่อีกครั้ง',
      );
      notifyListeners();
      return false;
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> validate([String? key]) async {
    final prefs = await SharedPreferences.getInstance();
    final licenseKey =
        key ?? _decrypt(prefs.getString(_prefLicenseKey) ?? '');

    if (licenseKey.isEmpty) {
      _state = LicenseState(
        status: LicenseStatus.none,
        deviceId: _deviceId,
      );
      notifyListeners();
      return;
    }

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/validate'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'license_key': licenseKey,
              'machine_id': _deviceId,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['valid'] == true) {
        await prefs.setString(
          _prefLastValidation,
          DateTime.now().toIso8601String(),
        );

        final expiryStr = data['expires_at'] as String?;

        _state = LicenseState(
          status: LicenseStatus.active,
          licenseKey: licenseKey,
          licenseType: data['license_type'] as String?,
          expiresAt:
              expiryStr != null ? DateTime.tryParse(expiryStr) : null,
          deviceId: _deviceId,
        );
      } else {
        _state = LicenseState(
          status: LicenseStatus.expired,
          deviceId: _deviceId,
          errorMessage:
              data['message'] as String? ?? 'License ไม่ถูกต้องหรือหมดอายุ',
        );
      }
    } catch (e) {
      // Offline fallback: check cached state
      final lastValidation = prefs.getString(_prefLastValidation);
      final cachedType = prefs.getString(_prefLicenseType);
      final cachedExpiry = prefs.getString(_prefLicenseExpiry);

      if (lastValidation != null) {
        final lastValid = DateTime.tryParse(lastValidation);
        if (lastValid != null &&
            DateTime.now().difference(lastValid).inDays < 7) {
          DateTime? expiry;
          if (cachedExpiry != null) {
            expiry = DateTime.tryParse(cachedExpiry);
            if (expiry != null && expiry.isBefore(DateTime.now())) {
              _state = LicenseState(
                status: LicenseStatus.expired,
                deviceId: _deviceId,
                errorMessage: 'License หมดอายุแล้ว',
              );
              notifyListeners();
              return;
            }
          }

          _state = LicenseState(
            status: LicenseStatus.active,
            licenseKey: licenseKey,
            licenseType: cachedType,
            expiresAt: expiry,
            deviceId: _deviceId,
          );
          notifyListeners();
          return;
        }
      }

      _state = LicenseState(
        status: LicenseStatus.none,
        deviceId: _deviceId,
        errorMessage: 'ไม่สามารถตรวจสอบ License ได้ กรุณาเชื่อมต่ออินเทอร์เน็ต',
      );
    }

    notifyListeners();
  }

  Future<void> checkMachine() async {
    if (_deviceId == null) await _generateDeviceId();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/check-machine'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'machine_id': _deviceId,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['has_license'] == true) {
        // License key is nested under data.data.license_key
        final licenseData = data['data'] as Map<String, dynamic>?;
        final licenseKey = licenseData?['license_key'] as String?;
        final licenseType = licenseData?['license_type'] as String?;
        if (licenseKey != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefLicenseKey, _encrypt(licenseKey));

          // For free licenses, set free mode directly without re-validating
          if (licenseType == 'free') {
            _state = LicenseState(
              status: LicenseStatus.free,
              licenseKey: licenseKey,
              licenseType: 'free',
              deviceId: _deviceId,
            );
            notifyListeners();
            return;
          }

          await validate(licenseKey);
          return;
        }
      }

      // Check demo status
      await checkDemo();
    } catch (e) {
      _state = LicenseState(
        status: LicenseStatus.none,
        deviceId: _deviceId,
      );
      notifyListeners();
    }
  }

  Future<bool> startDemo() async {
    if (_deviceId == null) await _generateDeviceId();

    _isProcessing = true;
    notifyListeners();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/demo'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'machine_id': _deviceId,
              'platform': Platform.operatingSystem,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefDemoStarted, true);

        final minutesLeft = data['minutes_left'] as int? ?? 60;

        _state = LicenseState(
          status: LicenseStatus.trial,
          licenseType: 'demo',
          deviceId: _deviceId,
          demoMinutesLeft: minutesLeft,
        );
        notifyListeners();
        return true;
      } else {
        _state = _state.copyWith(
          errorMessage:
              data['message'] as String? ?? 'ไม่สามารถเริ่มทดลองใช้งานได้',
        );
        notifyListeners();
        return false;
      }
    } catch (e) {
      _state = _state.copyWith(
        errorMessage: 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้',
      );
      notifyListeners();
      return false;
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> checkDemo() async {
    if (_deviceId == null) await _generateDeviceId();

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/demo/check'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'machine_id': _deviceId,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 && data['active'] == true) {
        final minutesLeft = data['minutes_left'] as int? ?? 0;

        _state = LicenseState(
          status: LicenseStatus.trial,
          licenseType: 'demo',
          deviceId: _deviceId,
          demoMinutesLeft: minutesLeft,
        );
      } else {
        _state = LicenseState(
          status: LicenseStatus.none,
          deviceId: _deviceId,
        );
      }
    } catch (e) {
      _state = LicenseState(
        status: LicenseStatus.none,
        deviceId: _deviceId,
      );
    }

    notifyListeners();
  }

  Future<void> deactivate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefLicenseKey);
    await prefs.remove(_prefLicenseType);
    await prefs.remove(_prefLicenseExpiry);
    await prefs.remove(_prefLastValidation);

    _state = LicenseState(
      status: LicenseStatus.none,
      deviceId: _deviceId,
    );
    notifyListeners();
  }

  String getPurchaseUrl(String plan) {
    final uri = Uri.parse(_purchaseBaseUrl).replace(
      queryParameters: {'plan': plan},
    );
    return uri.toString();
  }

  void clearError() {
    _state = LicenseState(
      status: _state.status,
      licenseKey: _state.licenseKey,
      licenseType: _state.licenseType,
      expiresAt: _state.expiresAt,
      deviceId: _state.deviceId,
      demoMinutesLeft: _state.demoMinutesLeft,
      // errorMessage intentionally omitted = null
    );
    notifyListeners();
  }

  /// Set free mode for users without a license.
  /// Preserves any existing license key (e.g. free license from backend).
  void setFreeMode() {
    _state = LicenseState(
      status: LicenseStatus.free,
      licenseKey: _state.licenseKey,
      licenseType: 'free',
      deviceId: _deviceId,
    );
    notifyListeners();
  }

  // Device-specific XOR encryption for local storage
  Future<List<int>> _deriveKey() async {
    final prefs = await SharedPreferences.getInstance();
    String? salt = prefs.getString(_prefSalt);
    if (salt == null || salt.isEmpty) {
      final random = Random.secure();
      final saltBytes = List<int>.generate(32, (_) => random.nextInt(256));
      salt = base64Encode(saltBytes);
      await prefs.setString(_prefSalt, salt);
    }
    final combined = '$salt|${_deviceId ?? "default"}';
    final hash = sha256.convert(utf8.encode(combined));
    return hash.bytes;
  }

  String _encrypt(String input) {
    // Synchronous wrapper - salt must already exist after init
    if (input.isEmpty) return '';
    final prefs = _cachedPrefs;
    if (prefs == null) return '';
    String? salt = prefs.getString(_prefSalt);
    if (salt == null || salt.isEmpty) return '';
    final combined = '$salt|${_deviceId ?? "default"}';
    final keyBytes = sha256.convert(utf8.encode(combined)).bytes;
    final inputBytes = utf8.encode(input);
    final result = <int>[];
    for (var i = 0; i < inputBytes.length; i++) {
      result.add(inputBytes[i] ^ keyBytes[i % keyBytes.length]);
    }
    return base64Encode(result);
  }

  String _decrypt(String input) {
    if (input.isEmpty) return '';
    try {
      final prefs = _cachedPrefs;
      if (prefs == null) return '';
      String? salt = prefs.getString(_prefSalt);
      if (salt == null || salt.isEmpty) return '';
      final combined = '$salt|${_deviceId ?? "default"}';
      final keyBytes = sha256.convert(utf8.encode(combined)).bytes;
      final decoded = base64Decode(input);
      final result = <int>[];
      for (var i = 0; i < decoded.length; i++) {
        result.add(decoded[i] ^ keyBytes[i % keyBytes.length]);
      }
      return utf8.decode(result);
    } catch (_) {
      return '';
    }
  }
}
