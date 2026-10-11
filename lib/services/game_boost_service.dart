import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../database/app_store.dart';
import '../models/proxy_server.dart';
import '../platform/platform_info.dart';
import '../platform/windows_native.dart';
import 'net/latency_probe.dart';
import 'vpn_proxy_service.dart';
import 'windows_tuneup.dart';

/// A place game servers live, with a probe target that answers TCP 443
/// from the same data centre region (AWS regional endpoints — the same
/// targets cloudping-style tools use).
class BoostRegion {
  final String id;
  final String name;
  final String countryCode;
  final String host;
  final int port;

  /// Relay countries worth trying for this region, closest first.
  final List<String> nearRelays;

  const BoostRegion({
    required this.id,
    required this.name,
    required this.countryCode,
    required this.host,
    this.port = 443,
    this.nearRelays = const [],
  });
}

/// A game and the region its Thai / SEA players usually land on. Only a
/// hint — the real server depends on the game's own region setting.
class BoostGame {
  final String name;
  final String regionId;
  final String note;
  const BoostGame(this.name, this.regionId, this.note);
}

/// A game whose server ranges the admin listed (xmanstudio: LocalVPN →
/// Fleet → game profiles). Only these ranges go through a game exit.
class GameProfile {
  const GameProfile({
    required this.slug,
    required this.name,
    required this.region,
    required this.cidrs,
    this.probe,
  });

  final String slug;
  final String name;

  /// Region id or country code (sg, SG, jp …) — matched to [BoostRegion].
  final String region;
  final List<String> cidrs;

  /// host:port inside those ranges that answers TCP, to measure through
  /// the relay (a game exit forwards nothing else).
  final String? probe;

  static final RegExp _cidr = RegExp(
      r'^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}/([0-9]|[12]\d|3[0-2])$');

  static GameProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    final slug = j['slug'];
    final name = j['name'];
    final cidrs = [
      for (final c in j['cidrs'] as List? ?? const [])
        if (c is String && _cidr.hasMatch(c.trim())) c.trim(),
    ];
    if (slug is! String || name is! String || cidrs.isEmpty) return null;
    final probe = j['probe_host'] ?? j['probe'];
    return GameProfile(
      slug: slug,
      name: name,
      region: '${j['region'] ?? ''}'.toLowerCase(),
      cidrs: cidrs,
      probe: probe is String && probe.isNotEmpty ? probe : null,
    );
  }

  Map<String, Object?> toJson() => {
        'slug': slug,
        'name': name,
        'region': region,
        'cidrs': cidrs,
        'probe_host': probe,
      };

  bool inRegion(BoostRegion r) =>
      region == r.id || region == r.countryCode.toLowerCase();
}

/// One measured path to the target region.
class RouteResult {
  final String label;
  final ServerCountry? relay; // null = direct (your ISP's route)
  final LatencySample sample;
  final String? failure;

  const RouteResult({
    required this.label,
    this.relay,
    required this.sample,
    this.failure,
  });

  bool get isDirect => relay == null;
  bool get ok => failure == null && sample.ok;
}

class BufferbloatResult {
  final double idleMs;
  final double loadedMs;
  final double downloadMbps;
  const BufferbloatResult(this.idleMs, this.loadedMs, this.downloadMbps);

  double get increaseMs => (loadedMs - idleMs).clamp(0, 10000).toDouble();

  String get grade {
    final d = increaseMs;
    if (d < 5) return 'A';
    if (d < 30) return 'B';
    if (d < 60) return 'C';
    if (d < 200) return 'D';
    return 'F';
  }
}

enum BoostPhase { idle, measuring, analyzing, connecting, active, stopping }

/// Game ping booster.
///
/// What actually lowers ping from Thailand to a server abroad is the ROUTE:
/// Thai ISPs sometimes send traffic the long way (via Hong Kong or the US,
/// through congested exchanges). A relay with a better path can cut that.
/// So the booster measures, compares and only recommends a relay when the
/// numbers show it wins — otherwise it says the direct route is best.
/// On Windows it can also stop Wi-Fi scan spikes and power-saving delay.
class GameBoostService extends ChangeNotifier {
  GameBoostService({required this.proxy});

  final VpnProxyService proxy;

  static const regions = <BoostRegion>[
    BoostRegion(
      id: 'sg',
      name: 'สิงคโปร์',
      countryCode: 'SG',
      host: 'dynamodb.ap-southeast-1.amazonaws.com',
      nearRelays: ['SG', 'MY', 'ID', 'TH', 'VN', 'HK'],
    ),
    BoostRegion(
      id: 'hk',
      name: 'ฮ่องกง',
      countryCode: 'HK',
      host: 'dynamodb.ap-east-1.amazonaws.com',
      nearRelays: ['HK', 'TW', 'VN', 'SG', 'JP'],
    ),
    BoostRegion(
      id: 'jp',
      name: 'ญี่ปุ่น (โตเกียว)',
      countryCode: 'JP',
      host: 'dynamodb.ap-northeast-1.amazonaws.com',
      nearRelays: ['JP', 'KR', 'TW', 'HK'],
    ),
    BoostRegion(
      id: 'kr',
      name: 'เกาหลีใต้ (โซล)',
      countryCode: 'KR',
      host: 'dynamodb.ap-northeast-2.amazonaws.com',
      nearRelays: ['KR', 'JP', 'TW', 'HK'],
    ),
    BoostRegion(
      id: 'in',
      name: 'อินเดีย (มุมไบ)',
      countryCode: 'IN',
      host: 'dynamodb.ap-south-1.amazonaws.com',
      nearRelays: ['IN', 'SG', 'AE'],
    ),
    BoostRegion(
      id: 'au',
      name: 'ออสเตรเลีย (ซิดนีย์)',
      countryCode: 'AU',
      host: 'dynamodb.ap-southeast-2.amazonaws.com',
      nearRelays: ['AU', 'NZ', 'SG'],
    ),
    BoostRegion(
      id: 'usw',
      name: 'สหรัฐฯ ฝั่งตะวันตก',
      countryCode: 'US',
      host: 'dynamodb.us-west-2.amazonaws.com',
      nearRelays: ['US', 'CA', 'JP'],
    ),
    BoostRegion(
      id: 'use',
      name: 'สหรัฐฯ ฝั่งตะวันออก',
      countryCode: 'US',
      host: 'dynamodb.us-east-1.amazonaws.com',
      nearRelays: ['US', 'CA', 'GB'],
    ),
    BoostRegion(
      id: 'de',
      name: 'ยุโรป (แฟรงก์เฟิร์ต)',
      countryCode: 'DE',
      host: 'dynamodb.eu-central-1.amazonaws.com',
      nearRelays: ['DE', 'NL', 'FR', 'PL', 'GB'],
    ),
    BoostRegion(
      id: 'gb',
      name: 'อังกฤษ (ลอนดอน)',
      countryCode: 'GB',
      host: 'dynamodb.eu-west-2.amazonaws.com',
      nearRelays: ['GB', 'NL', 'FR', 'DE', 'IE'],
    ),
    BoostRegion(
      id: 'me',
      name: 'ตะวันออกกลาง (บาห์เรน)',
      countryCode: 'BH',
      host: 'dynamodb.me-south-1.amazonaws.com',
      nearRelays: ['AE', 'BH', 'SA', 'IN'],
    ),
  ];

  static const games = <BoostGame>[
    BoostGame('Valorant / League of Legends (SEA)', 'sg', 'เซิร์ฟ SEA ของ Riot'),
    BoostGame('Dota 2 / CS2 (SEA)', 'sg', 'Steam SEA'),
    BoostGame('PUBG / Apex Legends (Asia)', 'sg', 'เลือกโซน SEA/Asia ในเกม'),
    BoostGame('Genshin Impact / Honkai: Star Rail (Asia)', 'jp',
        'เซิร์ฟ Asia ของ HoYoverse'),
    BoostGame('Final Fantasy XIV (JP)', 'jp', 'ดาต้าเซ็นเตอร์ญี่ปุ่น'),
    BoostGame('Fortnite (Asia)', 'jp', 'โซน Asia'),
    BoostGame('MMO เกาหลี (KR)', 'kr', 'เซิร์ฟเกาหลี'),
    BoostGame('World of Warcraft / เกมเซิร์ฟ US', 'usw', 'US West'),
    BoostGame('เกมเซิร์ฟยุโรป (EU)', 'de', 'EU Central'),
  ];

  static const _profilesUrl =
      'https://xman4289.com/api/v1/localvpn/game-profiles';
  static const _prefProfiles = 'boost_game_profiles';
  static const _prefRegion = 'boost_region';
  static const _prefCustomHost = 'boost_custom_host';
  static const _prefWifiTweak = 'boost_tweak_wifi';
  static const _prefPowerTweak = 'boost_tweak_power';

  BoostRegion _region = regions.first;
  BoostRegion get region => _region;

  List<GameProfile> _profiles = const [];

  /// Games of the selected region that a game exit carries.
  List<GameProfile> get regionProfiles =>
      [for (final p in _profiles) if (p.inRegion(_region)) p];

  /// Optional host:port the player knows their game server is on.
  String? _customHost;
  String? get customHost => _customHost;

  BoostPhase _phase = BoostPhase.idle;
  BoostPhase get phase => _phase;
  bool get isActive => _phase == BoostPhase.active;
  bool get isBusy =>
      _phase == BoostPhase.measuring ||
      _phase == BoostPhase.analyzing ||
      _phase == BoostPhase.connecting ||
      _phase == BoostPhase.stopping;

  /// True while the analyser has the tunnel up for a test (the shell must
  /// not advertise this device as a VPN gateway then).
  bool get usesTunnel =>
      _phase == BoostPhase.analyzing ||
      _phase == BoostPhase.connecting ||
      _phase == BoostPhase.active;

  String? _status;
  String? get status => _status;

  String? _error;
  String? get error => _error;

  RouteResult? _direct;
  RouteResult? get direct => _direct;

  final List<RouteResult> _relays = [];
  List<RouteResult> get relays => List.unmodifiable(_relays);

  ServerCountry? _activeRelay;
  ServerCountry? get activeRelay => _activeRelay;

  /// Live median-of-3 samples while boosting (or monitoring), newest last.
  final List<double> _live = [];
  List<double> get live => List.unmodifiable(_live);
  Timer? _liveTimer;
  bool _liveBusy = false;

  bool wifiTweak = true;
  bool powerTweak = true;
  final List<String> _tweakNotes = [];
  List<String> get tweakNotes => List.unmodifiable(_tweakNotes);

  ActiveAdapter? _adapter;
  ActiveAdapter? get adapter => _adapter;

  BufferbloatResult? _bufferbloat;
  BufferbloatResult? get bufferbloat => _bufferbloat;
  bool _bloatRunning = false;
  bool get bufferbloatRunning => _bloatRunning;

  bool _cancel = false;
  bool _disposed = false;

  /// The best measured relay, only when it beats the direct route by a
  /// margin a player would notice (≥ 8 ms or ≥ 10 % on the score).
  RouteResult? get recommendation {
    final d = _direct;
    final ok = _relays.where((r) => r.ok).toList()
      ..sort((a, b) => a.sample.score.compareTo(b.sample.score));
    if (ok.isEmpty) return null;
    final best = ok.first;
    if (d == null || !d.ok) return best;
    final gain = d.sample.score - best.sample.score;
    if (gain >= 8 || gain >= d.sample.score * 0.10) return best;
    return null;
  }

  /// Analysed, and no relay beat the direct route.
  bool get directIsBest =>
      _direct != null && _direct!.ok && _relays.isNotEmpty &&
      recommendation == null;

  Future<void> load() async {
    try {
      final prefs = await AppStore.instance();
      final id = prefs.getString(_prefRegion);
      _region = regions.firstWhere((r) => r.id == id,
          orElse: () => regions.first);
      _customHost = prefs.getString(_prefCustomHost);
      wifiTweak = prefs.getBool(_prefWifiTweak) ?? true;
      powerTweak = prefs.getBool(_prefPowerTweak) ?? true;
      _profiles = _parseProfiles(prefs.getString(_prefProfiles));
    } catch (_) {}
    _adapter = await WindowsNative.activeAdapter();
    _notify();
    unawaited(refreshProfiles());
  }

  static List<GameProfile> _parseProfiles(String? raw) {
    if (raw == null) return const [];
    try {
      final j = jsonDecode(raw);
      final list = j is Map ? j['profiles'] : j;
      return [
        for (final p in list as List? ?? const [])
          if (GameProfile.fromJson(p) case final g?) g,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The admin's game list; kept for offline use.
  Future<void> refreshProfiles() async {
    try {
      final r = await http
          .get(Uri.parse(_profilesUrl),
              headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;
      final profiles = _parseProfiles(r.body);
      _profiles = profiles;
      final prefs = await AppStore.instance();
      await prefs.setString(_prefProfiles,
          jsonEncode({'profiles': [for (final p in profiles) p.toJson()]}));
      _notify();
    } catch (e) {
      debugPrint('Game profiles not refreshed: $e');
    }
  }

  /// What goes through the tunnel: the region's game ranges and the probe
  /// target, or null when the admin listed no game for it (then the old
  /// "all internet" route, which only a full-VPN server accepts).
  Future<List<String>?> _routes() async {
    final games = regionProfiles;
    if (games.isEmpty) return null;
    final routes = <String>{for (final g in games) ...g.cidrs};
    final (host, _) = _target;
    try {
      final ip = InternetAddress.tryParse(host) ??
          (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
                  .timeout(const Duration(seconds: 4)))
              .first;
      if (ip.type == InternetAddressType.IPv4) routes.add('${ip.address}/32');
    } catch (_) {}
    return routes.toList();
  }

  Future<void> setRegion(BoostRegion r) async {
    if (isBusy || isActive) return;
    _region = r;
    _direct = null;
    _relays.clear();
    _notify();
    final prefs = await AppStore.instance();
    await prefs.setString(_prefRegion, r.id);
  }

  /// "1.2.3.4:7000" / "game.example.com:443"; empty clears it.
  Future<String?> setCustomHost(String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      _customHost = null;
    } else {
      final m = RegExp(r'^([A-Za-z0-9.\-]+)(?::(\d{1,5}))?$').firstMatch(t);
      if (m == null) return 'รูปแบบต้องเป็น host หรือ host:port';
      final port = int.tryParse(m.group(2) ?? '443') ?? 443;
      if (port < 1 || port > 65535) return 'พอร์ตต้องอยู่ระหว่าง 1–65535';
      _customHost = '${m.group(1)}:$port';
    }
    _direct = null;
    _relays.clear();
    _notify();
    final prefs = await AppStore.instance();
    if (_customHost == null) {
      await prefs.remove(_prefCustomHost);
    } else {
      await prefs.setString(_prefCustomHost, _customHost!);
    }
    return null;
  }

  Future<void> setTweaks({bool? wifi, bool? power}) async {
    if (wifi != null) wifiTweak = wifi;
    if (power != null) powerTweak = power;
    _notify();
    final prefs = await AppStore.instance();
    await prefs.setBool(_prefWifiTweak, wifiTweak);
    await prefs.setBool(_prefPowerTweak, powerTweak);
  }

  (String, int) get _target {
    final c = _customHost ??
        regionProfiles.map((p) => p.probe).whereType<String>().firstOrNull;
    if (c != null) {
      final i = c.lastIndexOf(':');
      final port = i > 0 ? int.tryParse(c.substring(i + 1)) : null;
      if (port != null) return (c.substring(0, i), port);
      return (c, 443);
    }
    return (_region.host, _region.port);
  }

  String get targetLabel => _customHost ?? _region.name;

  Future<LatencySample> _probe({int count = 8}) {
    final (host, port) = _target;
    return LatencyProbe.tcp(host, port, count: count);
  }

  /// Quick test of the direct route only.
  Future<void> measureDirect() async {
    if (isBusy) return;
    if (_proxyBusy) {
      _error = 'ตัดการเชื่อมต่อ VPN ประเทศก่อน เพื่อวัดเส้นทางตรงของคุณ';
      _notify();
      return;
    }
    _phase = BoostPhase.measuring;
    _error = null;
    _status = 'กำลังวัดเส้นทางตรงไป $targetLabel…';
    _notify();
    final s = await _probe(count: 10);
    _direct = RouteResult(
      label: 'เส้นทางตรง (ISP ของคุณ)',
      sample: s,
      failure: s.ok ? null : 'ไม่ตอบสนอง',
    );
    _phase = BoostPhase.idle;
    _status = null;
    _notify();
  }

  bool get _proxyBusy =>
      proxy.status == VpnProxyStatus.connected ||
      proxy.status == VpnProxyStatus.connecting ||
      proxy.status == VpnProxyStatus.disconnecting;

  /// Candidate relays: free ones first, nearest to the target region.
  List<ServerCountry> _candidates({int max = 4}) {
    final near = _region.nearRelays;
    final list = proxy.countries.where((c) => c.servers.isNotEmpty).toList();
    int rank(ServerCountry c) {
      final i = near.indexOf(c.countryCode.toUpperCase());
      return i < 0 ? 100 : i;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    final picked = list.where((c) => rank(c) < 100).take(max).toList();
    if (picked.length < 2) {
      for (final c in list) {
        if (picked.length >= 2) break;
        if (!picked.contains(c)) picked.add(c);
      }
    }
    return picked;
  }

  /// Measure the direct route, then each candidate relay end to end
  /// (tunnel up → probe the target through it → tunnel down).
  Future<void> analyze() async {
    if (isBusy || isActive) return;
    if (_proxyBusy) {
      _error = 'ตัดการเชื่อมต่อ VPN ประเทศก่อนวิเคราะห์เส้นทาง';
      _notify();
      return;
    }
    _cancel = false;
    _error = null;
    _relays.clear();
    _phase = BoostPhase.analyzing;
    _status = 'กำลังวัดเส้นทางตรงไป $targetLabel…';
    _notify();

    final d = await _probe(count: 10);
    _direct = RouteResult(
      label: 'เส้นทางตรง (ISP ของคุณ)',
      sample: d,
      failure: d.ok ? null : 'ไม่ตอบสนอง',
    );
    _notify();

    if (proxy.countries.isEmpty) {
      _status = 'กำลังโหลดรายชื่อเซิร์ฟเวอร์รีเลย์…';
      _notify();
      await proxy.fetchServers();
    }
    final candidates = _candidates();
    if (candidates.isEmpty) {
      _error = 'ยังไม่มีเซิร์ฟเวอร์รีเลย์ที่ใช้ได้ในตอนนี้';
    }

    for (var i = 0; i < candidates.length && !_cancel; i++) {
      final c = candidates[i];
      _status = 'ทดสอบผ่าน ${c.countryName} (${i + 1}/${candidates.length})…';
      _notify();
      _relays.add(await _measureVia(c));
      _notify();
    }

    _phase = BoostPhase.idle;
    _status = null;
    _notify();
  }

  void cancel() {
    _cancel = true;
  }

  Future<RouteResult> _measureVia(ServerCountry c) async {
    final up = await _bringUp(c);
    if (up != null) {
      await _bringDown();
      return RouteResult(
        label: 'ผ่าน ${c.countryName}',
        relay: c,
        sample: LatencySample.empty,
        failure: up,
      );
    }
    // Let the tunnel settle (first packets pay the handshake).
    await Future.delayed(const Duration(milliseconds: 800));
    final s = await _probe(count: 8);
    await _bringDown();
    return RouteResult(
      label: 'ผ่าน ${c.countryName}',
      relay: c,
      sample: s,
      failure: s.ok ? null : 'ไม่ตอบสนองผ่านรีเลย์นี้',
    );
  }

  /// Returns null when connected, otherwise a Thai error.
  Future<String?> _bringUp(ServerCountry c) async {
    final done = Completer<String?>();
    void listener() {
      if (done.isCompleted) return;
      if (proxy.status == VpnProxyStatus.connected) done.complete(null);
      if (proxy.status == VpnProxyStatus.error) {
        done.complete(proxy.error ?? 'เชื่อมต่อรีเลย์ไม่สำเร็จ');
      }
    }

    proxy.addListener(listener);
    try {
      final routes = await _routes();
      final started = await proxy.connectToCountry(
        c,
        routing: routes == null ? WgRouting.internetOnly : WgRouting.games,
        routes: routes ?? const [],
      );
      if (!started && !done.isCompleted) {
        done.complete(proxy.error ?? 'เชื่อมต่อรีเลย์ไม่สำเร็จ');
      }
      return await done.future.timeout(const Duration(seconds: 30),
          onTimeout: () => 'รีเลย์ไม่ตอบภายใน 30 วินาที');
    } finally {
      proxy.removeListener(listener);
    }
  }

  Future<void> _bringDown() async {
    if (proxy.status == VpnProxyStatus.disconnected) return;
    await proxy.disconnect();
    // Give Windows a moment to remove the routes.
    await Future.delayed(const Duration(milliseconds: 600));
  }

  /// Turn the boost on through [relay] (the recommendation by default).
  /// [force] allows a relay even when the analysis said direct is better.
  Future<void> start({ServerCountry? relay}) async {
    if (isBusy || isActive) return;
    final target = relay ?? recommendation?.relay;
    if (target == null) {
      _error = 'วิเคราะห์เส้นทางก่อน หรือเลือกรีเลย์เอง';
      _notify();
      return;
    }
    if (_proxyBusy) {
      _error = 'ตัดการเชื่อมต่อ VPN ประเทศก่อนเปิดโหมดลดปิง';
      _notify();
      return;
    }
    _error = null;
    _phase = BoostPhase.connecting;
    _status = 'กำลังเปิดเส้นทางผ่าน ${target.countryName}…';
    _notify();

    final err = await _bringUp(target);
    if (err != null) {
      await _bringDown();
      _phase = BoostPhase.idle;
      _status = null;
      _error = err;
      _notify();
      return;
    }
    _activeRelay = target;
    await _applyTweaks();
    _phase = BoostPhase.active;
    _status = null;
    _live.clear();
    _startLive();
    proxy.addListener(_onProxyChanged);
    _notify();
  }

  void _onProxyChanged() {
    // The tunnel dropped under us (server gone, user disconnected it on the
    // VPN page): end the boost cleanly.
    if (_phase == BoostPhase.active &&
        proxy.status != VpnProxyStatus.connected &&
        proxy.status != VpnProxyStatus.connecting) {
      stop(tunnelAlreadyDown: true);
    }
  }

  Future<void> stop({bool tunnelAlreadyDown = false}) async {
    // While connecting, start() owns the tunnel and cleans up on failure.
    if (_phase != BoostPhase.active) return;
    proxy.removeListener(_onProxyChanged);
    _phase = BoostPhase.stopping;
    _status = 'กำลังปิดโหมดลดปิง…';
    _notify();
    _liveTimer?.cancel();
    if (!tunnelAlreadyDown) await _bringDown();
    await _restoreTweaks();
    _activeRelay = null;
    _phase = BoostPhase.idle;
    _status = null;
    _notify();
  }

  Future<void> _applyTweaks() async {
    _tweakNotes.clear();
    if (!isWindows || !await WindowsNative.isElevated()) return;
    _adapter = await WindowsNative.activeAdapter();
    if (wifiTweak && (_adapter?.isWifi ?? false)) {
      final r = await WindowsTuneup.suppressWifiScan(_adapter!.name);
      _tweakNotes.add(r.message);
    }
    if (powerTweak) {
      final r = await WindowsTuneup.highPerformancePower();
      _tweakNotes.add(r.message);
    }
  }

  Future<void> _restoreTweaks() async {
    if (!isWindows) return;
    await WindowsTuneup.restoreWifiScan();
    await WindowsTuneup.restorePower();
    _tweakNotes.clear();
  }

  /// Live graph: one median-of-3 probe every 2 s.
  void _startLive() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_liveBusy || _disposed) return;
      _liveBusy = true;
      try {
        final s = await _probe(count: 3);
        _live.add(s.medianMs ?? -1);
        if (_live.length > 90) _live.removeAt(0);
        _notify();
      } finally {
        _liveBusy = false;
      }
    });
  }

  /// Ping under load: idle round trip vs while a download saturates the
  /// line. A big rise means the router's queue (bufferbloat) is what makes
  /// the game lag whenever someone at home downloads or streams.
  Future<void> runBufferbloatTest() async {
    if (_bloatRunning || isBusy) return;
    _bloatRunning = true;
    _error = null;
    _notify();
    const host = 'speed.cloudflare.com';
    try {
      final idle = await LatencyProbe.tcp(host, 443, count: 6);
      if (!idle.ok) {
        _error = 'วัดไม่ได้ — ตรวจสอบการเชื่อมต่ออินเทอร์เน็ต';
        return;
      }
      final client = http.Client();
      var bytes = 0;
      final sw = Stopwatch()..start();
      final loadedSamples = <double>[];
      final download = () async {
        try {
          final req = http.Request(
              'GET', Uri.parse('https://$host/__down?bytes=100000000'));
          final res = await client.send(req);
          await for (final chunk in res.stream) {
            bytes += chunk.length;
            if (sw.elapsed > const Duration(seconds: 9)) break;
          }
        } catch (_) {}
      }();
      // Start probing once the download has ramped up.
      await Future.delayed(const Duration(milliseconds: 1500));
      while (sw.elapsed < const Duration(seconds: 8)) {
        final s = await LatencyProbe.tcp(host, 443, count: 1);
        if (s.ok) loadedSamples.add(s.answered.first);
        await Future.delayed(const Duration(milliseconds: 250));
      }
      client.close();
      await download.timeout(const Duration(seconds: 3), onTimeout: () {});
      final secs = sw.elapsedMilliseconds / 1000;
      loadedSamples.sort();
      final loaded = loadedSamples.isEmpty
          ? idle.medianMs!
          : loadedSamples[loadedSamples.length ~/ 2];
      _bufferbloat = BufferbloatResult(
        idle.medianMs!,
        loaded,
        secs > 0 ? bytes * 8 / secs / 1e6 : 0,
      );
    } on SocketException {
      _error = 'ทดสอบไม่สำเร็จ — ตรวจสอบการเชื่อมต่ออินเทอร์เน็ต';
    } finally {
      _bloatRunning = false;
      _notify();
    }
  }

  // ── Screenshot demo data (lib/dev/shot_harness.dart only) ──
  void debugSeed({
    RouteResult? direct,
    List<RouteResult> relays = const [],
    List<double> live = const [],
    BufferbloatResult? bufferbloat,
    ServerCountry? activeRelay,
    ActiveAdapter? adapter,
  }) {
    _direct = direct;
    _relays
      ..clear()
      ..addAll(relays);
    _live
      ..clear()
      ..addAll(live);
    _bufferbloat = bufferbloat;
    _activeRelay = activeRelay;
    _adapter = adapter ?? _adapter;
    _phase = activeRelay != null ? BoostPhase.active : BoostPhase.idle;
    _notify();
  }

  void clearError() {
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _liveTimer?.cancel();
    proxy.removeListener(_onProxyChanged);
    super.dispose();
  }
}
