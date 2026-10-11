import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/license_state.dart';
import '../models/member.dart';
import '../models/network.dart';
import '../models/proxy_server.dart';
import '../platform/windows_native.dart';
import '../screens/network_detail_screen.dart';
import '../screens/shell/app_services.dart';
import '../screens/shell/app_shell.dart';
import '../services/game_boost_service.dart';
import '../services/license_service.dart';
import '../services/net/latency_probe.dart';
import '../widgets/m3/m3.dart';
import 'launch_options.dart';

/// Off-screen screenshot runner (see [LaunchOptions]). Uses demo data and
/// blocks every HTTP request so a run can never write to the real backend.
class ShotHarness extends StatefulWidget {
  final LaunchOptions options;

  const ShotHarness({super.key, required this.options});

  static final GlobalKey _boundary = GlobalKey();

  /// Wraps the app so frames can be captured.
  static Widget wrap(Widget app) {
    HttpOverrides.global = _OfflineHttp();
    return RepaintBoundary(key: _boundary, child: app);
  }

  @override
  State<ShotHarness> createState() => _ShotHarnessState();
}

class _ShotHarnessState extends State<ShotHarness> {
  final _shellKey = GlobalKey<AppShellState>();
  late final LicenseService _license;

  @override
  void initState() {
    super.initState();
    _license = LicenseService()
      ..debugSetState(LicenseState(
        status: LicenseStatus.active,
        licenseKey: 'DEMO-0000-0000-0000',
        licenseType: 'lifetime',
        deviceId: 'demo-device-0001',
      ));
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final theme = M3ThemeController.instance;
    final out = widget.options.shot!;
    try {
      await _settle(1800);
      for (final page in widget.options.pages) {
        if (page.startsWith('theme:')) {
          theme.force(page.substring(6) == 'night');
          await _settle(600);
          continue;
        }
        final shell = _shellKey.currentState;
        if (shell == null) break;
        _seed(shell.services, boostActive: page != 'boost-idle');
        await _open(shell, page);
        await _settle(1400);
        _seed(shell.services, boostActive: page != 'boost-idle');
        await _settle(500);
        final name = '$out-${theme.isNight ? 'night' : 'sky'}-$page.png';
        await _capture(name);
        stdout.writeln('SHOT $name');
      }
    } catch (e, st) {
      stderr.writeln('SHOT_FAILED $e\n$st');
    }
    await Future.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  Future<void> _open(AppShellState shell, String page) async {
    final tab = ShellTab.values.where((t) => t.name == page).firstOrNull;
    if (tab != null) {
      shell.goTo(tab, popToRoot: true);
      return;
    }
    switch (page) {
      case 'boost-idle':
        shell.goTo(ShellTab.boost, popToRoot: true);
      case 'net-detail':
        shell.goTo(ShellTab.networks, popToRoot: true);
        await _settle(300);
        final net = shell.services.network.currentNetwork!;
        shell.pushOnTab(
          ShellTab.networks,
          M3PageRoute(
            builder: (_) => NetworkDetailScreen(
              services: shell.services,
              network: net,
            ),
          ),
        );
    }
  }

  Future<void> _settle(int ms) async {
    await Future.delayed(Duration(milliseconds: ms));
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _capture(String path) async {
    final ctx = ShotHarness._boundary.currentContext;
    if (ctx == null) return;
    final boundary = ctx.findRenderObject()! as RenderRepaintBoundary;
    final ratio = View.of(ctx).devicePixelRatio;
    final image = await boundary.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    await File(path).writeAsBytes(data.buffer.asUint8List());
  }

  void _seed(AppServices s, {required bool boostActive}) {
    const subnet = '10.10.7.0/24';
    const net = VpnNetwork(
      id: '7',
      name: 'ก๊วนเกมคืนวันศุกร์',
      slug: 'friday-gamers',
      description: 'Valorant + Minecraft LAN ทุกคืนวันศุกร์',
      isPublic: false,
      memberCount: 6,
      onlineCount: 4,
      virtualSubnet: subnet,
    );
    final now = DateTime.now();
    final members = [
      NetworkMember(
          id: '1',
          displayName: 'XMAN-PC (เครื่องนี้)',
          virtualIp: '10.10.7.2',
          isOnline: true,
          lastHeartbeat: now,
          machineId: 'demo-device-0001'),
      NetworkMember(
          id: '2',
          displayName: 'Boss-Gaming',
          virtualIp: '10.10.7.3',
          publicIp: '203.0.113.21',
          isOnline: true,
          lastHeartbeat: now),
      NetworkMember(
          id: '3',
          displayName: 'น้องฟ้า Laptop',
          virtualIp: '10.10.7.4',
          publicIp: '203.0.113.33',
          isOnline: true,
          lastHeartbeat: now),
      NetworkMember(
          id: '4',
          displayName: 'Tee-Android',
          virtualIp: '10.10.7.5',
          publicIp: '203.0.113.48',
          isOnline: true,
          vpnGatewayCountry: 'JP',
          lastHeartbeat: now),
      NetworkMember(
          id: '5',
          displayName: 'Minecraft-Server',
          virtualIp: '10.10.7.6',
          isOnline: false,
          lastHeartbeat: now.subtract(const Duration(hours: 3))),
      NetworkMember(
          id: '6',
          displayName: 'Mook-PC',
          virtualIp: '10.10.7.7',
          isOnline: false,
          lastHeartbeat: now.subtract(const Duration(days: 1))),
    ];
    s.network.debugSeed(
      current: net,
      members: members,
      ownVirtualIp: '10.10.7.2',
      publicNetworks: const [
        VpnNetwork(name: 'Minecraft TH Survival', slug: 'mc-th',
            memberCount: 38, onlineCount: 12, isPublic: true,
            description: 'เซิร์ฟ Survival คนไทย เปิด 24 ชม.'),
        VpnNetwork(name: 'ห้องเล่น Red Alert 2', slug: 'ra2',
            memberCount: 14, onlineCount: 5, isPublic: true,
            description: 'เกม LAN คลาสสิก'),
        VpnNetwork(name: 'Office Bangna', slug: 'bangna-office',
            memberCount: 9, onlineCount: 3, isPublic: false),
        VpnNetwork(name: 'Terraria ก๊วนเด็กวิศวะ', slug: 'terraria-eng',
            memberCount: 6, onlineCount: 2, isPublic: true),
      ],
    );
    s.vpn.debugSetConnected('10.10.7.2', subnet);
    s.p2p.debugSeedPeers({
      '10.10.7.3': true,
      '10.10.7.4': true,
      '10.10.7.5': false,
    });

    WireguardServer srv(int id, String cc, String name, int load) =>
        WireguardServer(
          id: id,
          name: '$cc-$id.xman4289.com',
          countryCode: cc,
          countryName: name,
          endpoint: '203.0.113.${100 + id}:51820',
          load: load,
          isHealthy: true,
        )..measuredPing = {'SG': 31, 'JP': 74, 'HK': 46, 'US': 189,
              'DE': 212}[cc];
    ServerCountry country(String cc, String name, int id, int load) =>
        ServerCountry(countryCode: cc, countryName: name,
            servers: [srv(id, cc, name, load)]);
    final sg = country('SG', 'Singapore', 1, 34);
    final hk = country('HK', 'Hong Kong', 2, 52);
    final jp = country('JP', 'Japan', 3, 41);
    s.proxy.debugSeed(
      [sg, jp, hk, country('US', 'United States', 4, 63)],
      locked: [
        ServerCountry(countryCode: 'DE', countryName: 'Germany',
            servers: [srv(5, 'DE', 'Germany', 20)], locked: true),
      ],
    );

    LatencySample sample(List<double> v) => LatencySample(v);
    s.boost.debugSeed(
      direct: RouteResult(
        label: 'เส้นทางตรง (ISP ของคุณ)',
        sample: sample([48, 52, 61, 47, 95, 50, 49, 53, 58, 51]),
      ),
      relays: [
        RouteResult(label: 'ผ่าน Singapore', relay: sg,
            sample: sample([31, 32, 30, 33, 31, 34, 30, 32])),
        RouteResult(label: 'ผ่าน Hong Kong', relay: hk,
            sample: sample([44, 46, 45, 49, 44, 47, 45, 46])),
        RouteResult(label: 'ผ่าน Japan', relay: jp,
            sample: sample([79, 81, 78, 80, 83, 79, 80, 82])),
      ],
      live: boostActive
          ? [
              for (var i = 0; i < 48; i++)
                31.0 + (i % 5) - (i % 3) + (i == 17 || i == 33 ? 14 : 0),
            ]
          : const [],
      bufferbloat: const BufferbloatResult(12, 58, 94.6),
      activeRelay: boostActive ? sg : null,
      adapter: const ActiveAdapter(
        name: 'Wi-Fi',
        description: 'Intel(R) Wi-Fi 6E AX211 160MHz',
        guid: '{00000000-0000-0000-0000-000000000000}',
        type: 'wifi',
        speedMbps: 1201,
        ipv4: '192.168.1.45',
        gateway: '192.168.1.1',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      key: _shellKey,
      licenseService: _license,
      demo: true,
    );
  }
}

class _OfflineHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        Future.error(const SocketException('offline screenshot run'));
    return client;
  }
}
