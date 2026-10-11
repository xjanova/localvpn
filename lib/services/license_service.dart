import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../database/app_store.dart';
import '../models/license_state.dart';
import 'device_identity.dart';
import 'trusted_clock.dart';

/// One licence as the server describes it.
class LicenseInfo {
  const LicenseInfo({
    required this.key,
    required this.type,
    this.expiresAt,
    this.daysRemaining,
  });

  final String key;
  final String type;
  final DateTime? expiresAt;
  final int? daysRemaining;

  static LicenseInfo? fromData(Object? data) {
    if (data is! Map) return null;
    final key = data['license_key'];
    final type = data['license_type'];
    if (key is! String || key.isEmpty || type is! String) return null;
    final days = data['days_remaining'];
    return LicenseInfo(
      key: key,
      type: type,
      expiresAt: DateTime.tryParse('${data['expires_at'] ?? ''}'),
      daysRemaining: days is num ? days.toInt() : null,
    );
  }

  bool get isFree => type == 'free';
  bool get isTrial => type == 'demo' || type == 'trial';
}

/// LocalVPN licence (product `localvpn` on xmanstudio).
///
/// - Every device registers online before first use; after that it works
///   offline from a sealed cache.
/// - A device that never had it gets the 30-day Pro trial on its own, once:
///   the server binds the trial to the hardware, so reinstalling doesn't
///   bring it back.
/// - When a trial or term ends the server hands over the device's FREE key
///   (`license_changed`): the app drops to the free tier, it doesn't stop.
/// - Dates come from the server's clock and a forward-only watermark
///   ([TrustedClock]); a clock set back can't stretch a trial, and a paid
///   key is trusted offline for 7 days at most.
class LicenseService extends ChangeNotifier {
  LicenseService({
    @visibleForTesting http.Client? client,
    @visibleForTesting Future<DeviceIdentity> Function()? identity,
    @visibleForTesting Future<TrustedClock> Function()? clock,
    @visibleForTesting String? appVersion,
  })  : _http = client ?? http.Client(),
        _identityLoader = identity ?? DeviceIdentity.load,
        _clockLoader = clock ?? TrustedClock.load,
        _appVersion = appVersion;

  static const String _baseUrl =
      'https://xman4289.com/api/v1/product/localvpn';
  static const String _purchaseBaseUrl = 'https://xman4289.com/localvpn';

  /// How long a paid key is trusted without reaching the server.
  static const Duration offlineGrace = Duration(days: 7);
  static const Duration _revalidateEvery = Duration(hours: 6);

  static const String _prefCache = 'license_cache_v2';
  static const String _prefSalt = '_lk_salt';
  static const String _prefRegistered = 'device_registered_at';
  static const String _prefTrialOffered = 'trial_auto_started';

  // Written by versions before 1.1; read once, then removed.
  static const String _legacyKey = 'license_key_enc';
  static const List<String> _legacyKeys = [
    'license_key_enc',
    'license_type',
    'license_expiry',
    'last_validation',
    'last_known_time',
    'demo_started',
  ];

  final http.Client _http;
  final Future<DeviceIdentity> Function() _identityLoader;
  final Future<TrustedClock> Function() _clockLoader;
  String? _appVersion;

  LicenseState _state = const LicenseState.initial();
  LicenseState get state => _state;

  DeviceIdentity? _id;
  String? get deviceId => _id?.machineId;

  AppStore? _store;
  TrustedClock? _clock;
  Timer? _timer;
  DateTime? _lastOnlineCheck;
  bool _refreshing = false;

  bool _isProcessing = false;
  bool get isProcessing => _isProcessing;

  bool _needsOnlineRegistration = false;

  /// First run without internet: the device must register once before use.
  bool get needsOnlineRegistration => _needsOnlineRegistration;

  Future<void> init() async {
    _setState(const LicenseState(status: LicenseStatus.checking));
    _store = await AppStore.instance();
    _clock = await _clockLoader();
    _id = await _identityLoader();
    _appVersion ??= await _readAppVersion();
    await _ensureSalt();
    final cached = _readCache() ?? _migrateLegacy();
    if (cached != null) _applyOffline(cached, announce: false);

    final canStartTrial = await _register();
    if (canStartTrial == null) {
      // Offline. A device that never registered can't start; one that did
      // runs on what it knew.
      if (_store!.getString(_prefRegistered) == null) {
        _needsOnlineRegistration = true;
        _setState(LicenseState(
          status: LicenseStatus.none,
          deviceId: deviceId,
          errorMessage: 'เชื่อมต่ออินเทอร์เน็ตเพื่อลงทะเบียนเครื่องครั้งแรก',
        ));
      } else {
        _applyOffline(_readCache());
      }
    } else {
      _needsOnlineRegistration = false;
      await _refresh(canStartTrial: canStartTrial);
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  /// Retry from a "register first" screen.
  Future<void> retryRegistration() => init();

  // ── Server calls ──────────────────────────────────────────────────────

  Future<_Answer?> _post(String path, Map<String, Object?> body) async {
    try {
      final response = await _http
          .post(
            Uri.parse('$_baseUrl/$path'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      final date = response.headers['date'];
      if (date != null) {
        try {
          _clock?.noteServerTime(HttpDate.parse(date));
        } catch (_) {}
      }
      if (response.statusCode >= 500 || response.statusCode == 429) {
        return null; // the server is not answering for real
      }
      Object? json;
      try {
        // Laravel sends application/json without a charset; the body is
        // UTF-8 (Thai messages).
        json = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      } catch (_) {}
      return _Answer(
          response.statusCode, json is Map<String, dynamic> ? json : const {});
    } catch (e) {
      debugPrint('Licence request $path failed: $e');
      return null;
    }
  }

  /// can_start_trial, or null when the server could not be reached.
  Future<bool?> _register() async {
    final id = _id!;
    final answer = await _post('register-device', {
      ...id.fields,
      'machine_name': id.machineName,
      'os_version': id.osVersion,
      'app_version': _appVersion,
    });
    if (answer == null || answer.status != 200) return null;
    _store!.setString(_prefRegistered, _clock!.now().toIso8601String());
    final data = answer.json['data'];
    return data is Map && data['can_start_trial'] == true;
  }

  /// The key this device should run now: the cached one validated, or the
  /// machine's best key. Null only when the server can't be reached.
  Future<void> _refresh({bool? canStartTrial}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      LicenseInfo? info;
      var reached = false;
      final cached = _readCache();
      if (cached != null) {
        final answer = await _post('validate', {
          'license_key': cached.key,
          'machine_id': deviceId,
        });
        if (answer != null) {
          reached = true;
          if (answer.status == 200 && answer.json['is_valid'] == true) {
            info = LicenseInfo.fromData(answer.json['data']);
          }
        }
      }
      if (info == null && (reached || cached == null)) {
        final answer = await _post('check-machine', _id!.fields);
        if (answer != null) {
          reached = true;
          if (answer.status == 200 && answer.json['has_license'] == true) {
            info = LicenseInfo.fromData(answer.json['data']);
          }
        }
      }
      if (!reached) {
        _applyOffline(_readCache());
        return;
      }
      _lastOnlineCheck = _clock!.now();
      if (info == null) {
        // Reached the server, which knows no key for us (should not happen
        // for LocalVPN: every device has at least its FREE key).
        _writeCache(null);
        _setState(LicenseState(
          status: LicenseStatus.free,
          licenseType: 'free',
          deviceId: deviceId,
          trialAvailable: canStartTrial ?? _state.trialAvailable,
        ));
        return;
      }
      _accept(info,
          trialAvailable:
              (canStartTrial ?? _state.trialAvailable) && info.isFree);

      // The one free trial, started for the user (owner: "ใช้ฟรี 30 วัน").
      if (_state.trialAvailable &&
          info.isFree &&
          _store!.getBool(_prefTrialOffered) != true) {
        _store!.setBool(_prefTrialOffered, true);
        await startDemo(auto: true);
      }
    } finally {
      _refreshing = false;
    }
  }

  /// Start the 30-day Pro trial (once per device and hardware).
  Future<bool> startDemo({bool auto = false}) async {
    if (_id == null) return false;
    _setProcessing(true);
    try {
      final answer = await _post('demo', _id!.fields);
      if (answer == null) {
        if (!auto) {
          _setState(_state.copyWith(
            errorMessage: 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ กรุณาลองใหม่',
          ));
        }
        return false;
      }
      final info = answer.json['success'] == true
          ? LicenseInfo.fromData(answer.json['data'])
          : null;
      if (info != null) {
        _accept(info, trialAvailable: false);
        return true;
      }
      final code = answer.json['error_code'] as String?;
      const used = {
        'TRIAL_ALREADY_USED',
        'TRIAL_USED_ON_THIS_HARDWARE',
        'ALREADY_LICENSED',
        'TRIAL_ACTIVE',
        'DEVICE_BLOCKED',
      };
      final base = used.contains(code)
          ? _state.copyWith(trialAvailable: false)
          : _state;
      _setState(auto
          ? base
          : base.copyWith(
              errorCode: code,
              errorMessage: answer.json['message'] as String? ??
                  'ไม่สามารถเริ่มทดลองใช้งานได้',
            ));
      return false;
    } finally {
      _setProcessing(false);
    }
  }

  /// Activate a bought key on this device. When the key is already on its
  /// two devices the state carries errorCode ALREADY_ACTIVATED_OTHER_DEVICE;
  /// call again with [forceRebind] (after asking the user) to move it here.
  Future<bool> activate(String licenseKey, {bool forceRebind = false}) async {
    final key = licenseKey.trim().toUpperCase();
    if (key.isEmpty || _id == null) return false;
    _setProcessing(true);
    try {
      final id = _id!;
      final answer = await _post('activate', {
        'license_key': key,
        'machine_id': id.machineId,
        'machine_fingerprint': id.hardwareHash ?? id.machineId,
        'app_version': _appVersion,
        if (id.drmId case final d?) 'drm_id': d,
        if (id.androidId case final a?) 'android_id': a,
        if (forceRebind) 'force_rebind': 'true',
      });
      if (answer == null) {
        _setState(_state.copyWith(
          errorMessage: 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ กรุณาลองใหม่อีกครั้ง',
        ));
        return false;
      }
      final info = answer.status == 200 && answer.json['success'] == true
          ? LicenseInfo.fromData(answer.json['data'])
          : null;
      if (info != null) {
        _accept(info, trialAvailable: false);
        return true;
      }
      _setState(_state.copyWith(
        errorCode: answer.json['error_code'] as String?,
        errorMessage: answer.status == 422
            ? 'รูปแบบ License key ไม่ถูกต้อง'
            : answer.json['message'] as String? ??
                'ไม่สามารถเปิดใช้งาน License ได้',
      ));
      return false;
    } finally {
      _setProcessing(false);
    }
  }

  /// Give this device's place on the key back (to use it on another
  /// device); the device continues on its FREE key.
  Future<void> deactivate() async {
    final cached = _readCache();
    if (cached != null && !cached.isFree) {
      await _post('deactivate', {
        'license_key': cached.key,
        'machine_id': deviceId,
      });
    }
    _writeCache(null);
    _setState(LicenseState(
        status: LicenseStatus.free, licenseType: 'free', deviceId: deviceId));
    await _refresh();
  }

  // ── State ─────────────────────────────────────────────────────────────

  void _accept(LicenseInfo info, {required bool trialAvailable}) {
    _writeCache(_Cached(
      key: info.key,
      type: info.type,
      expiresAt: info.expiresAt,
      validatedAt: _clock!.now(),
    ));
    _setState(LicenseState(
      status: _statusOf(info.type),
      licenseKey: info.key,
      licenseType: info.type,
      expiresAt: info.expiresAt,
      daysLeft: info.daysRemaining ?? _daysLeft(info.expiresAt),
      deviceId: deviceId,
      trialAvailable: trialAvailable,
    ));
  }

  static LicenseStatus _statusOf(String type) => switch (type) {
        'free' => LicenseStatus.free,
        'demo' || 'trial' => LicenseStatus.trial,
        _ => LicenseStatus.active,
      };

  int? _daysLeft(DateTime? expiresAt) {
    if (expiresAt == null) return null;
    final left = expiresAt.difference(_clock!.now());
    return left.isNegative ? 0 : (left.inHours / 24).ceil();
  }

  /// What the cache allows without the server.
  void _applyOffline(_Cached? cached, {bool announce = true}) {
    final clock = _clock!;
    String? why;
    var status = LicenseStatus.free;
    if (cached != null && !cached.isFree) {
      final now = clock.now();
      if (clock.rolledBack) {
        why = 'เวลาของเครื่องถูกย้อนกลับ — เชื่อมต่ออินเทอร์เน็ตเพื่อยืนยันสิทธิ์ PRO';
      } else if (cached.expiresAt != null && !cached.expiresAt!.isAfter(now)) {
        why = cached.isTrial
            ? 'หมดช่วงทดลองใช้ PRO แล้ว — ใช้งานแบบฟรีต่อได้'
            : 'License หมดอายุแล้ว — ต่ออายุเพื่อใช้ PRO ต่อ';
      } else if (!cached.isTrial &&
          now.difference(cached.validatedAt) > offlineGrace) {
        why = 'ออฟไลน์นานเกิน 7 วัน — เชื่อมต่ออินเทอร์เน็ตเพื่อยืนยัน License';
      } else {
        status = _statusOf(cached.type);
      }
    }
    _setState(LicenseState(
      status: status,
      licenseKey: status == LicenseStatus.free && cached != null && !cached.isFree
          ? null
          : cached?.key,
      licenseType: status == LicenseStatus.free ? 'free' : cached?.type,
      expiresAt: status == LicenseStatus.free ? null : cached?.expiresAt,
      daysLeft: status == LicenseStatus.free ? null : _daysLeft(cached?.expiresAt),
      deviceId: deviceId,
      errorMessage: announce ? why : null,
      offline: true,
    ));
  }

  /// Every minute: keep the watermark moving, notice a trial or term that
  /// just ended, and check with the server every few hours.
  void _tick() {
    final clock = _clock;
    if (clock == null || _needsOnlineRegistration) return;
    clock.mark();
    final ends = _state.expiresAt;
    final ended = _state.isPaid && ends != null && !ends.isAfter(clock.now());
    final last = _lastOnlineCheck;
    final due = last == null || clock.now().difference(last) > _revalidateEvery;
    if (ended || due) {
      unawaited(_refresh().then((_) {
        // Still not confirmed: the cache decides.
        if (ended && _state.isPaid && _state.expiresAt == ends) {
          _applyOffline(_readCache());
        }
      }));
    } else if (_state.isPaid && _state.daysLeft != _daysLeft(ends)) {
      _setState(_state.copyWith(daysLeft: _daysLeft(ends)));
    }
  }

  void _setState(LicenseState s) {
    _state = s;
    notifyListeners();
  }

  void _setProcessing(bool v) {
    _isProcessing = v;
    notifyListeners();
  }

  String getPurchaseUrl(String plan) => '$_purchaseBaseUrl#$plan';

  void clearError() => _setState(_state.withoutError());

  /// Kept for callers from before the free tier was the server's answer.
  void setFreeMode() {
    if (_state.isValid) return;
    _setState(LicenseState(
      status: LicenseStatus.free,
      licenseType: 'free',
      deviceId: deviceId,
    ));
  }

  // ── Screenshot demo data (lib/dev/shot_harness.dart only) ──
  void debugSetState(LicenseState state) {
    _state = state;
    notifyListeners();
  }

  // ── Sealed cache ──────────────────────────────────────────────────────
  //
  // The cache is signed with a key made from a per-install salt and the
  // machine id. Editing it (say, "free" → "lifetime") breaks the signature
  // and the app runs free until the server says otherwise.

  Future<void> _ensureSalt() async {
    final store = _store!;
    if ((store.getString(_prefSalt) ?? '').isEmpty) {
      final r = Random.secure();
      await store.setString(
          _prefSalt, base64Encode(List.generate(32, (_) => r.nextInt(256))));
    }
  }

  List<int> get _sealKey => sha256
      .convert(utf8.encode(
          'lvpn-licence|${_store!.getString(_prefSalt)}|$deviceId'))
      .bytes;

  _Cached? _readCache() {
    final raw = _store?.getString(_prefCache);
    if (raw == null) return null;
    try {
      final outer = jsonDecode(raw) as Map<String, dynamic>;
      final body = outer['b'] as String;
      final mac = Hmac(sha256, _sealKey).convert(utf8.encode(body)).toString();
      if (mac != outer['m']) {
        debugPrint('Licence cache signature mismatch: ignored');
        return null;
      }
      return _Cached.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void _writeCache(_Cached? c) {
    final store = _store;
    if (store == null) return;
    if (c == null) {
      store.remove(_prefCache);
      return;
    }
    final body = jsonEncode(c.toJson());
    final mac = Hmac(sha256, _sealKey).convert(utf8.encode(body)).toString();
    store.setString(_prefCache, jsonEncode({'b': body, 'm': mac}));
  }

  /// The key an earlier version stored (XOR with the same salt), moved into
  /// the sealed cache once. Its type is re-learnt from the server.
  _Cached? _migrateLegacy() {
    final store = _store!;
    final enc = store.getString(_legacyKey);
    if (enc == null) return null;
    String key = '';
    try {
      final k = sha256
          .convert(utf8.encode('${store.getString(_prefSalt)}|$deviceId'))
          .bytes;
      final bytes = base64Decode(enc);
      key = utf8.decode([
        for (var i = 0; i < bytes.length; i++) bytes[i] ^ k[i % k.length],
      ]);
    } catch (_) {}
    for (final k in _legacyKeys) {
      store.remove(k);
    }
    if (key.isEmpty) return null;
    // Unknown type until the server answers: trusted as free meanwhile.
    final cached = _Cached(
      key: key,
      type: 'free',
      validatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    _writeCache(cached);
    return cached;
  }

  static Future<String?> _readAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class _Answer {
  const _Answer(this.status, this.json);
  final int status;
  final Map<String, dynamic> json;
}

class _Cached {
  const _Cached({
    required this.key,
    required this.type,
    this.expiresAt,
    required this.validatedAt,
  });

  final String key;
  final String type;
  final DateTime? expiresAt;
  final DateTime validatedAt;

  bool get isFree => type == 'free';
  bool get isTrial => type == 'demo' || type == 'trial';

  Map<String, Object?> toJson() => {
        'k': key,
        't': type,
        'e': expiresAt?.toIso8601String(),
        'v': validatedAt.millisecondsSinceEpoch,
      };

  static _Cached fromJson(Map<String, dynamic> j) => _Cached(
        key: j['k'] as String,
        type: j['t'] as String,
        expiresAt: DateTime.tryParse('${j['e'] ?? ''}'),
        validatedAt: DateTime.fromMillisecondsSinceEpoch(j['v'] as int),
      );
}
