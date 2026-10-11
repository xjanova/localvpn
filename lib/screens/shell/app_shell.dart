import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../database/database_helper.dart';
import '../../models/license_state.dart';
import '../../platform/platform_info.dart';
import '../../platform/windows_native.dart';
import '../../services/license_service.dart';
import '../../services/sound_service.dart';
import '../../services/vpn_proxy_service.dart';
import '../../services/windows_tuneup.dart';
import '../../widgets/m3/m3.dart';
import '../devices_screen.dart';
import '../file_transfer_screen.dart';
import '../game_boost_screen.dart';
import '../home_screen.dart';
import '../network_list_screen.dart';
import '../settings_screen.dart';
import '../torrent/global_torrent_screen.dart';
import '../vpn_proxy_screen.dart';
import 'app_services.dart';

enum ShellTab { home, networks, boost, vpn, files, torrent, devices, settings }

class _TabSpec {
  final ShellTab tab;
  final String label;
  final String icon;
  const _TabSpec(this.tab, this.label, this.icon);
}

const _tabs = <_TabSpec>[
  _TabSpec(ShellTab.home, 'ภาพรวม', M3Icons.power),
  _TabSpec(ShellTab.networks, 'เครือข่าย LAN', M3Icons.networks),
  _TabSpec(ShellTab.boost, 'ลดปิงเกม', M3Icons.gameBoost),
  _TabSpec(ShellTab.vpn, 'VPN ประเทศ', M3Icons.vpnProxy),
  _TabSpec(ShellTab.files, 'ส่งไฟล์', M3Icons.fileTransfer),
  _TabSpec(ShellTab.torrent, 'Torrent', M3Icons.torrent),
  _TabSpec(ShellTab.devices, 'อุปกรณ์', M3Icons.devicePc),
  _TabSpec(ShellTab.settings, 'ตั้งค่า', M3Icons.settings),
];

/// Tabs on the phone bottom bar; the rest live behind "เมนู".
const _mobileTabs = [
  ShellTab.home,
  ShellTab.networks,
  ShellTab.boost,
  ShellTab.files,
];

/// Gives any screen access to the services and to tab switching.
class AppShellScope extends InheritedWidget {
  final AppShellState state;

  const AppShellScope({super.key, required this.state, required super.child});

  static AppShellState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>()!.state;

  static AppShellState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>()?.state;

  @override
  bool updateShouldNotify(AppShellScope oldWidget) => false;
}

/// Main window: wallpaper, (Windows) title bar, sidebar or bottom bar, and
/// one nested navigator per tab so pushed pages keep the sidebar visible.
class AppShell extends StatefulWidget {
  final LicenseService licenseService;

  /// Opens this tab first (screenshot runs).
  final ShellTab initialTab;

  /// Screenshot run: no auto-rejoin, no update check, no system tweaks.
  final bool demo;

  const AppShell({
    super.key,
    required this.licenseService,
    this.initialTab = ShellTab.home,
    this.demo = false,
  });

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell>
    with WindowListener, TrayListener {
  late final AppServices services;
  late ShellTab _tab;
  final Map<ShellTab, GlobalKey<NavigatorState>> _navKeys = {
    for (final t in ShellTab.values) t: GlobalKey<NavigatorState>(),
  };
  final Set<ShellTab> _built = {};
  bool _elevated = true;
  String _version = '';
  bool _trayShown = false;
  bool _toldAboutTray = false;
  bool _quitting = false;
  bool _wasLanConnected = false;

  ShellTab get tab => _tab;
  bool get isElevated => _elevated;
  String get version => _version;

  @override
  void initState() {
    super.initState();
    services = AppServices(widget.licenseService);
    _tab = widget.initialTab;
    _built.add(_tab);

    services.vpn.addListener(_onLanChanged);
    services.proxy.addListener(_onProxyChanged);
    services.network.addListener(_onNetworkChanged);
    services.license.addListener(_refresh);
    services.boost.addListener(_refresh);
    services.boost.load();
    // The Windows installer replaces our files: close cleanly once it runs.
    services.update.onInstallerStarted = () => _quit();

    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _version = i.version);
    }).catchError((_) {});

    if (isWindows) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
      trayManager.addListener(this);
      WindowsNative.isElevated().then((e) {
        if (mounted) setState(() => _elevated = e);
      });
      if (!widget.demo) WindowsTuneup.restoreLeftovers();
    }

    if (!widget.demo) {
      _autoRejoinLastNetwork();
      services.update.checkForUpdate();
    }
  }

  Future<void> _autoRejoinLastNetwork() async {
    // Settings → "เชื่อมต่ออัตโนมัติ" (on unless switched off).
    try {
      if (await DatabaseHelper().getSetting('auto_connect') == 'false') return;
    } catch (_) {}
    final saved = await services.network.getSavedNetworks();
    if (saved.isEmpty) return;
    final last = saved.first;
    final slug = last['slug'] as String?;
    if (slug == null) return;
    await services.network.joinNetworkRaw(
      slug,
      passwordHash: last['password_hash'] as String?,
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String? _filesSlug;
  DateTime _filesRefreshed = DateTime.fromMillisecondsSinceEpoch(0);

  void _onNetworkChanged() {
    // The network service notifies on every heartbeat: reload the shared
    // file list when the network changes, otherwise at most every 30 s
    // (new files from friends still show up on their own).
    final slug = services.network.currentNetwork?.slug;
    final changed = slug != _filesSlug;
    if (changed) {
      _filesSlug = slug;
      services.files.setNetwork(slug);
    }
    final now = DateTime.now();
    if (slug != null &&
        (changed || now.difference(_filesRefreshed).inSeconds >= 30)) {
      _filesRefreshed = now;
      services.files.refreshFileList();
    }
    _refresh();
  }

  void _onLanChanged() {
    final now = services.vpn.isConnected;
    if (now && !_wasLanConnected) SoundService().play(SfxType.connect);
    if (!now && _wasLanConnected) SoundService().play(SfxType.disconnect);
    _wasLanConnected = now;
    _refresh();
  }

  void _onProxyChanged() {
    // Share the country VPN with the network only for a real country VPN,
    // never for a boost tunnel or the analyser's test tunnels.
    if (services.proxy.status == VpnProxyStatus.connected &&
        !services.boost.usesTunnel) {
      services.network.setVpnGateway(
        services.proxy.connectedCountry,
        hostname: services.proxy.connectedHostname,
      );
    } else {
      services.network.setVpnGateway(null);
    }
    _refresh();
  }

  /// Switch tab. [popToRoot] returns that tab's stack to its first page.
  void goTo(ShellTab t, {bool popToRoot = false}) {
    if (popToRoot) {
      _navKeys[t]?.currentState?.popUntil((r) => r.isFirst);
    }
    if (t == _tab) return;
    HapticFeedback.selectionClick();
    SoundService().play(SfxType.tabSwitch);
    setState(() {
      _tab = t;
      _built.add(t);
    });
  }

  /// Push a page onto [t]'s own navigator (keeps the sidebar visible).
  void pushOnTab(ShellTab t, Route<void> route) {
    goTo(t);
    _navKeys[t]?.currentState?.push(route);
  }

  /// Restart elevated (UAC). Quits this copy when the user accepts.
  Future<void> relaunchAsAdmin() async {
    final ok = await WindowsNative.relaunchAsAdmin();
    if (!ok) {
      if (mounted) {
        m3Toast(context, 'ยกเลิกการขอสิทธิ์ผู้ดูแลระบบ', tone: M3Tone.amber);
      }
      return;
    }
    await _quit(relaunching: true);
  }

  // ── Window / tray (Windows) ───────────────────────────────────────────

  @override
  void onWindowClose() async {
    if (_quitting) return;
    if (services.hasActiveConnection) {
      await _hideToTray();
    } else {
      await _quit();
    }
  }

  Future<void> _hideToTray() async {
    await _ensureTray();
    await windowManager.hide();
    if (!_toldAboutTray) {
      _toldAboutTray = true;
      await trayManager.setToolTip(
          'LocalVPN ยังเชื่อมต่ออยู่ — คลิกเพื่อเปิด');
    }
  }

  Future<void> _ensureTray() async {
    if (_trayShown) return;
    _trayShown = true;
    await trayManager.setIcon('assets/m3/tray.ico');
    await trayManager.setToolTip('LocalVPN');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'เปิด LocalVPN'),
      MenuItem.separator(),
      MenuItem(key: 'disconnect', label: 'ตัดการเชื่อมต่อทั้งหมด'),
      MenuItem(key: 'quit', label: 'ออกจากโปรแกรม'),
    ]));
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _showWindow();
      case 'disconnect':
        services.disconnectAll();
      case 'quit':
        _quit();
    }
  }

  Future<void> _quit({bool relaunching = false}) async {
    if (_quitting) return;
    _quitting = true;
    try {
      await services.disconnectAll().timeout(const Duration(seconds: 6));
    } catch (_) {}
    if (isWindows) {
      await WindowsTuneup.restoreWifiScan();
      await WindowsTuneup.restorePower();
      if (_trayShown) await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    services.vpn.removeListener(_onLanChanged);
    services.proxy.removeListener(_onProxyChanged);
    services.network.removeListener(_onNetworkChanged);
    services.license.removeListener(_refresh);
    services.boost.removeListener(_refresh);
    if (isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    services.dispose();
    super.dispose();
  }

  // ── Layout ────────────────────────────────────────────────────────────

  Widget _rootFor(ShellTab t) => switch (t) {
        ShellTab.home => HomeScreen(services: services),
        ShellTab.networks => NetworkListScreen(services: services),
        ShellTab.boost => GameBoostScreen(services: services),
        ShellTab.vpn => VpnProxyScreen(services: services),
        ShellTab.files => FileTransferScreen(services: services),
        ShellTab.torrent => GlobalTorrentScreen(services: services),
        ShellTab.devices => DevicesScreen(services: services),
        ShellTab.settings => SettingsScreen(services: services),
      };

  Widget _tabNavigator(ShellTab t) {
    return Navigator(
      key: _navKeys[t],
      onGenerateRoute: (settings) => M3PageRoute(
        settings: settings,
        builder: (_) => _rootFor(t),
      ),
    );
  }

  Future<bool> _handleBack() async {
    final nav = _navKeys[_tab]?.currentState;
    if (nav != null && nav.canPop()) {
      // maybePop lets the page's own PopScope ask first (unsaved forms).
      await nav.maybePop();
      return false;
    }
    if (_tab != ShellTab.home) {
      goTo(ShellTab.home);
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900;

    final content = IndexedStack(
      index: ShellTab.values.indexOf(_tab),
      children: [
        for (final t in ShellTab.values)
          _built.contains(t)
              ? HeroControllerScope.none(child: _tabNavigator(t))
              : const SizedBox.shrink(),
      ],
    );

    Widget body;
    if (wide) {
      body = Row(
        children: [
          _Sidebar(state: this, compact: size.height < 860),
          Expanded(child: content),
        ],
      );
    } else {
      body = Column(
        children: [
          Expanded(child: SafeArea(bottom: false, child: content)),
          _BottomBar(state: this),
        ],
      );
    }

    if (isWindows) {
      body = Column(
        children: [
          M3TitleBar(
            title: 'LocalVPN — LAN เสมือนผ่านอินเทอร์เน็ต',
            chip: M3Tag(
              _elevated ? 'ผู้ดูแลระบบ' : 'โหมดผู้ใช้ทั่วไป',
              tone: _elevated ? M3Tone.green : M3Tone.amber,
              dot: true,
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    return AppShellScope(
      state: this,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _handleBack()) SystemNavigator.pop();
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              const Positioned.fill(child: M3Wallpaper()),
              Positioned.fill(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sidebar ─────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final AppShellState state;
  final bool compact;

  const _Sidebar({required this.state, required this.compact});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final s = state.services;
    final online = s.network.members.where((m) => m.isOnline).length;

    int? countFor(ShellTab t) => switch (t) {
          ShellTab.devices => online > 0 ? online : null,
          _ => null,
        };

    return Container(
      width: 252,
      margin: const EdgeInsets.fromLTRB(14, 14, 0, 14),
      decoration: BoxDecoration(
        gradient: p.sideFill,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.isNight ? p.line : p.inputLine),
        boxShadow: p.cardShadow,
      ),
      child: Column(
        children: [
          SizedBox(height: compact ? 12 : 20),
          Icon3D(M3Icons.logo, size: compact ? 74 : 104, glow: p.logoGlow),
          SizedBox(height: compact ? 4 : 8),
          const _Wordmark(size: 26),
          const SizedBox(height: 2),
          Text('VIRTUAL LAN', style: M3Text.eyebrow(context)),
          const M3GoldLine(margin: EdgeInsets.fromLTRB(18, 12, 18, 10)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final spec in _tabs)
                  _NavItem(
                    spec: spec,
                    selected: state.tab == spec.tab,
                    compact: compact,
                    count: countFor(spec.tab),
                    live: _liveFor(spec.tab, s),
                    onTap: () => state.goTo(spec.tab,
                        popToRoot: state.tab == spec.tab),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LocalVPN ${state.version.isEmpty ? '' : 'v${state.version}'}',
                        style: TextStyle(
                          fontFamily: M3Fonts.head,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: p.gold,
                        ),
                      ),
                      Text('by Xman Studio', style: M3Text.sub(context)),
                    ],
                  ),
                ),
                if (s.update.updateAvailable)
                  Tooltip(
                    message: 'มีเวอร์ชันใหม่ ${s.update.latestVersion ?? ''}',
                    child: GestureDetector(
                      onTap: () => state.goTo(ShellTab.settings),
                      child: const Icon3D(M3Icons.update, size: 30),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Green orb next to a tab whose feature is running right now.
  static bool _liveFor(ShellTab t, AppServices s) => switch (t) {
        ShellTab.home || ShellTab.networks => s.vpn.isConnected,
        ShellTab.boost => s.boost.isActive,
        ShellTab.vpn => s.proxy.status == VpnProxyStatus.connected &&
            !s.boost.usesTunnel,
        _ => false,
      };
}

class _Wordmark extends StatelessWidget {
  final double size;
  const _Wordmark({required this.size});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    TextStyle style() => TextStyle(
          fontFamily: M3Fonts.head,
          fontSize: size,
          fontWeight: FontWeight.w800,
          fontStyle: FontStyle.italic,
          height: 1.1,
          color: Colors.white,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShaderMask(
          shaderCallback: (r) => p.wordmark.createShader(r),
          blendMode: BlendMode.srcIn,
          child: Text('Local', style: style()),
        ),
        ShaderMask(
          shaderCallback: (r) => p.wordmarkAccent.createShader(r),
          blendMode: BlendMode.srcIn,
          child: Text('VPN', style: style()),
        ),
      ],
    );
  }
}

class _NavItem extends StatefulWidget {
  final _TabSpec spec;
  final bool selected;
  final bool compact;
  final int? count;
  final bool live;
  final VoidCallback onTap;

  const _NavItem({
    required this.spec,
    required this.selected,
    required this.compact,
    required this.onTap,
    this.count,
    this.live = false,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final sel = widget.selected;
    final h = widget.compact ? 44.0 : 50.0;

    Widget pill = Container(
      height: h,
      decoration: BoxDecoration(
        gradient: sel ? M3Fx.aquaGloss : null,
        color: sel ? null : (_hover ? p.hover : Colors.transparent),
        borderRadius: BorderRadius.circular(14),
        border: sel ? Border.all(color: M3Fx.aquaEdge) : null,
      ),
      child: Stack(
        children: [
          if (sel)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(1),
                decoration: const BoxDecoration(
                  gradient: M3Fx.btnGloss,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(13),
                    topRight: Radius.circular(13),
                    bottomLeft: Radius.circular(5),
                    bottomRight: Radius.circular(5),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 10),
            child: Row(
              children: [
                Icon3D(widget.spec.icon, size: widget.compact ? 34 : 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.spec.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: M3Fonts.head,
                      fontSize: widget.compact ? 14 : 15,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                      color: sel
                          ? M3Fx.aquaText
                          : (_hover ? p.text : p.text2),
                    ),
                  ),
                ),
                if (widget.live) ...[
                  StatusOrb(color: sel ? M3Fx.greenEdge : p.green, size: 8),
                  const SizedBox(width: 6),
                ],
                if (widget.count != null) M3Count(widget.count!),
              ],
            ),
          ),
        ],
      ),
    );

    if (sel) {
      pill = Container(
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          gradient: M3Fx.goldRing,
          borderRadius: BorderRadius.circular(15.5),
          boxShadow: M3Fx.aquaGlow,
        ),
        child: pill,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(onTap: widget.onTap, child: pill),
      ),
    );
  }
}

// ── Bottom bar (phones, narrow windows) ─────────────────────────────────

class _BottomBar extends StatelessWidget {
  final AppShellState state;
  const _BottomBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final inMore = !_mobileTabs.contains(state.tab);
    return Container(
      decoration: BoxDecoration(
        gradient: p.titleFill,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 66,
          child: Row(
            children: [
              for (final t in _mobileTabs)
                _BottomItem(
                  spec: _tabs.firstWhere((s) => s.tab == t),
                  selected: state.tab == t,
                  onTap: () => state.goTo(t, popToRoot: state.tab == t),
                ),
              _BottomItem(
                spec: const _TabSpec(
                    ShellTab.settings, 'เมนู', M3Icons.settings),
                selected: inMore,
                onTap: () => _openMore(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMore(BuildContext context) {
    final rest = _tabs.where((s) => !_mobileTabs.contains(s.tab)).toList();
    showM3Sheet(
      context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 4,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          childAspectRatio: 0.82,
          children: [
            for (final s in rest)
              GestureDetector(
                onTap: () {
                  Navigator.of(ctx).pop();
                  state.goTo(s.tab);
                },
                child: Column(
                  children: [
                    Icon3D(s.icon, size: 54),
                    const SizedBox(height: 6),
                    Text(
                      s.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: M3Text.label(ctx).copyWith(
                        color: state.tab == s.tab ? ctx.m3.cyan : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomItem extends StatelessWidget {
  final _TabSpec spec;
  final bool selected;
  final VoidCallback onTap;

  const _BottomItem({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                gradient: selected ? M3Fx.aquaGloss : null,
                borderRadius: BorderRadius.circular(11),
                border: selected ? Border.all(color: M3Fx.aquaEdge) : null,
                boxShadow: selected ? M3Fx.aquaGlow : null,
              ),
              child: Icon3D(spec.icon, size: 32),
            ),
            const SizedBox(height: 3),
            Text(
              spec.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: M3Fonts.head,
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? p.cyan : p.text2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Header badges (PRO badge + connection pill) ─────────────────────────

/// Licence badge and LAN status, for the right side of page headers.
/// Listens to the services itself: pages use it as a `const` widget, which
/// never rebuilds with its parent.
class ShellBadges extends StatelessWidget {
  const ShellBadges({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppShellScope.of(context).services;
    return ListenableBuilder(
      listenable: Listenable.merge([s.license, s.vpn]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final shell = AppShellScope.of(context);
    final s = shell.services;
    final lic = s.license.state;
    final narrow = MediaQuery.sizeOf(context).width < 760;

    final (kind, main, sub) = switch (lic.status) {
      LicenseStatus.active => (
          ProBadgeKind.pro,
          'PRO',
          lic.licenseType == 'lifetime' ? 'ตลอดชีพ' : _expiry(lic),
        ),
      LicenseStatus.trial => (ProBadgeKind.pro, 'PRO', 'ทดลองใช้'),
      LicenseStatus.expired => (ProBadgeKind.none, 'PRO', 'หมดอายุ'),
      LicenseStatus.checking => (ProBadgeKind.free, 'FREE', 'กำลังตรวจสอบ'),
      _ => (ProBadgeKind.free, 'FREE', 'อัปเกรดเป็น PRO'),
    };

    final badge = ProBadge(
      kind: kind,
      main: main,
      sub: sub,
      height: narrow ? 34 : 40,
      onTap: lic.isPaid
          ? () => shell.goTo(ShellTab.settings)
          : () async {
              final uri = Uri.tryParse(s.license.getPurchaseUrl('monthly'));
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
    );
    if (narrow) return badge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        badge,
        const SizedBox(width: 10),
        _StatusPill(connected: s.vpn.isConnected),
      ],
    );
  }

  static String _expiry(LicenseState lic) {
    final e = lic.expiresAt;
    if (e == null) return lic.typeDisplayName;
    final days = e.difference(DateTime.now()).inDays;
    return days >= 0 ? 'เหลือ $days วัน' : 'หมดอายุ';
  }
}

class _StatusPill extends StatelessWidget {
  final bool connected;
  const _StatusPill({required this.connected});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        gradient: p.glassBtn,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.isNight ? p.line : p.inputLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusOrb(color: connected ? p.green : p.text3, size: 10,
              pulse: connected),
          const SizedBox(width: 8),
          Text(
            connected ? 'LAN เชื่อมต่อแล้ว' : 'ยังไม่เชื่อมต่อ',
            style: TextStyle(
              fontFamily: M3Fonts.head,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: p.glassBtnText,
            ),
          ),
        ],
      ),
    );
  }
}
