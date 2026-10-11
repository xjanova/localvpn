import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:localvpn/database/app_store.dart';
import 'package:localvpn/models/license_state.dart';
import 'package:localvpn/services/device_identity.dart';
import 'package:localvpn/services/license_service.dart';
import 'package:localvpn/services/trusted_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _machine = 'a1' * 16;
final _hardware = 'h' * 64;

/// The licence server, as far as these tests need it.
class _Server {
  bool online = true;
  bool canStartTrial = true;
  DateTime now = DateTime.utc(2026, 10, 11, 9);
  String? activeKey; // what validate accepts for this machine
  String activeType = 'free';
  DateTime? activeExpires;
  bool keyFull = false;
  final calls = <String, Map<String, dynamic>>{};

  late final client = MockClient((request) async {
    if (!online) throw const SocketException('offline');
    final path = request.url.pathSegments.last;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    calls[path] = body;
    Map<String, Object?> data() => {
          'license_key': activeKey,
          'license_type': activeType,
          'expires_at': activeExpires?.toIso8601String(),
          'days_remaining': activeExpires == null
              ? null
              : (activeExpires!.difference(now).inHours / 24).ceil(),
        };
    final (status, json) = switch (path) {
      'register-device' => (
          200,
          {
            'success': true,
            'data': {'can_start_trial': canStartTrial},
          },
        ),
      'check-machine' => () {
          activeKey ??= 'FREE-ABC';
          return (200, {'success': true, 'has_license': true, 'data': data()});
        }(),
      'demo' => canStartTrial
          ? () {
              canStartTrial = false;
              activeKey = 'DEMO-123';
              activeType = 'demo';
              activeExpires = now.add(const Duration(days: 30));
              return (200, {'success': true, 'data': data()});
            }()
          : (
              403,
              {
                'success': false,
                'error_code': 'TRIAL_USED_ON_THIS_HARDWARE',
                'message': 'เครื่องนี้เคยใช้สิทธิ์ทดลองใช้ไปแล้ว',
              },
            ),
      'validate' => body['license_key'] != activeKey
          ? (404, {'success': false, 'is_valid': false})
          : activeExpires != null && !activeExpires!.isAfter(now)
              // Trial over: the server hands the FREE key over.
              ? () {
                  final previous = activeKey;
                  activeKey = 'FREE-ABC';
                  activeType = 'free';
                  activeExpires = null;
                  return (
                    200,
                    {
                      'success': true,
                      'is_valid': true,
                      'license_changed': true,
                      'previous_license': {'license_key': previous},
                      'data': data(),
                    },
                  );
                }()
              : (200, {'success': true, 'is_valid': true, 'data': data()}),
      'activate' => body['machine_fingerprint'] == null
          ? (422, {'message': 'The machine fingerprint field is required.'})
          : keyFull && body['force_rebind'] != 'true'
              ? (
                  403,
                  {
                    'success': false,
                    'error_code': 'ALREADY_ACTIVATED_OTHER_DEVICE',
                    'message': 'License นี้ใช้ครบ 2 เครื่องแล้ว',
                  },
                )
              : () {
                  activeKey = body['license_key'] as String;
                  activeType = 'yearly';
                  activeExpires = now.add(const Duration(days: 365));
                  return (200, {'success': true, 'data': data()});
                }(),
      'deactivate' => (200, {'success': true}),
      _ => (404, {}),
    };
    return http.Response.bytes(utf8.encode(jsonEncode(json)), status,
        headers: {
          'content-type': 'application/json',
          'date': HttpDate.format(now),
        });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late _Server server;
  late DateTime deviceNow;
  final services = <LicenseService>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppStore.resetForTests();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await AppStore.openForTests(db);
    server = _Server();
    deviceNow = server.now;
  });

  tearDown(() async {
    for (final s in services) {
      s.dispose();
    }
    services.clear();
    await (await AppStore.instance()).flush();
    AppStore.resetForTests();
    await db.close();
  });

  /// One app start.
  Future<LicenseService> launch() async {
    final s = LicenseService(
      client: server.client,
      identity: () async =>
          DeviceIdentity(machineId: _machine, hardwareHash: _hardware),
      clock: () => TrustedClock.load(systemNow: () => deviceNow),
      appVersion: '1.1.0',
    );
    services.add(s);
    await s.init();
    return s;
  }

  test('first launch registers, then starts the 30-day trial by itself',
      () async {
    final s = await launch();
    expect(server.calls['register-device']!['hardware_hash'], _hardware);
    expect(server.calls['demo']!['machine_id'], _machine);
    expect(s.state.status, LicenseStatus.trial);
    expect(s.state.isPaid, isTrue);
    expect(s.state.daysLeft, 30);
    expect(s.state.trialAvailable, isFalse);
    expect(s.state.maxNetworkMembers, 50);
  });

  test('a device that used its trial runs free and is not offered one',
      () async {
    server.canStartTrial = false;
    final s = await launch();
    expect(server.calls.containsKey('demo'), isFalse);
    expect(s.state.status, LicenseStatus.free);
    expect(s.state.trialAvailable, isFalse);
    expect(s.state.maxNetworkMembers, 5);
  });

  test('when the trial ends the app falls back to the FREE key', () async {
    await launch();
    server.now = server.now.add(const Duration(days: 31));
    deviceNow = server.now;
    final s = await launch();
    expect(server.calls['validate']!['license_key'], 'DEMO-123');
    expect(s.state.status, LicenseStatus.free);
    expect(s.state.licenseKey, 'FREE-ABC');
  });

  test('offline, a trial runs until its end by the trusted clock', () async {
    await launch();
    server.online = false;
    deviceNow = server.now.add(const Duration(days: 10));
    var s = await launch();
    expect(s.state.status, LicenseStatus.trial);
    expect(s.state.offline, isTrue);
    expect(s.state.daysLeft, 20);

    deviceNow = server.now.add(const Duration(days: 30, hours: 1));
    s = await launch();
    expect(s.state.status, LicenseStatus.free);
    expect(s.state.errorMessage, contains('หมดช่วงทดลอง'));
  });

  test('winding the clock back does not bring the trial back', () async {
    await launch();
    server.online = false;
    deviceNow = server.now.add(const Duration(days: 29));
    await launch(); // the watermark now sits at day 29
    deviceNow = server.now.add(const Duration(days: 2));
    final s = await launch();
    expect(s.state.status, LicenseStatus.free);
    expect(s.state.errorMessage, contains('ย้อนกลับ'));
  });

  test('a paid key is trusted offline for 7 days, not longer', () async {
    server.canStartTrial = false;
    final first = await launch();
    expect(await first.activate('lvpn-yearly-key'), isTrue);
    expect(first.state.status, LicenseStatus.active);
    server.online = false;
    deviceNow = server.now.add(const Duration(days: 6));
    expect((await launch()).state.status, LicenseStatus.active);
    deviceNow = server.now.add(const Duration(days: 8));
    final late = await launch();
    expect(late.state.status, LicenseStatus.free);
    expect(late.state.errorMessage, contains('7 วัน'));
  });

  test('an edited cache is ignored', () async {
    server.canStartTrial = false;
    await launch();
    final store = await AppStore.instance();
    final raw = jsonDecode(store.getString('license_cache_v2')!) as Map;
    final body = (raw['b'] as String).replaceFirst('"free"', '"lifetime"');
    await store.setString(
        'license_cache_v2', jsonEncode({'b': body, 'm': raw['m']}));
    server.online = false;
    final s = await launch();
    expect(s.state.status, LicenseStatus.free);
  });

  test('the very first launch needs the internet', () async {
    server.online = false;
    final s = await launch();
    expect(s.needsOnlineRegistration, isTrue);
    expect(s.state.isValid, isFalse);
    server.online = true;
    await s.retryRegistration();
    expect(s.needsOnlineRegistration, isFalse);
    expect(s.state.isValid, isTrue);
  });

  test('activation sends the fingerprint; a full key can be moved here',
      () async {
    server.canStartTrial = false;
    server.keyFull = true;
    final s = await launch();
    expect(await s.activate('lvpn-yearly-key'), isFalse);
    expect(s.state.errorCode, 'ALREADY_ACTIVATED_OTHER_DEVICE');
    expect(server.calls['activate']!['machine_fingerprint'], _hardware);
    expect(server.calls['activate']!['license_key'], 'LVPN-YEARLY-KEY');

    expect(await s.activate('lvpn-yearly-key', forceRebind: true), isTrue);
    expect(server.calls['activate']!['force_rebind'], 'true');
    expect(s.state.status, LicenseStatus.active);
  });

  test('a key saved by an earlier version is picked up', () async {
    final store = await AppStore.instance();
    // The old XOR scheme with the same salt.
    const salt = 'c2FsdHNhbHRzYWx0c2FsdHNhbHRzYWx0c2FsdHNhbHQ=';
    await store.setString('_lk_salt', salt);
    final k = sha256.convert(utf8.encode('$salt|$_machine')).bytes;
    final key = utf8.encode('DEMO-123');
    await store.setString('license_key_enc',
        base64Encode([for (var i = 0; i < key.length; i++) key[i] ^ k[i % k.length]]));
    server
      ..canStartTrial = false
      ..activeKey = 'DEMO-123'
      ..activeType = 'demo'
      ..activeExpires = server.now.add(const Duration(days: 12));
    final s = await launch();
    expect(server.calls['validate']!['license_key'], 'DEMO-123');
    expect(s.state.status, LicenseStatus.trial);
    expect(store.getString('license_key_enc'), isNull);
  });
}
