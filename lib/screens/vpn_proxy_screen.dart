import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/proxy_server.dart';
import '../platform/platform_info.dart';
import '../services/vpn_proxy_service.dart';
import '../widgets/m3/m3.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "VPN ประเทศ" — WireGuard country VPN: a connection hero (state, ping,
/// time, traffic, connect/disconnect) and a grid of countries, with the PRO
/// countries locked behind an upgrade.
class VpnProxyScreen extends StatefulWidget {
  final AppServices services;

  const VpnProxyScreen({super.key, required this.services});

  @override
  State<VpnProxyScreen> createState() => _VpnProxyScreenState();
}

/// Why a country is offered for one-tap connect.
enum _Quick { recent, fastest, first }

enum _TileState { idle, connecting, connected }

class _VpnProxyScreenState extends State<VpnProxyScreen> {
  AppServices get s => widget.services;
  VpnProxyService get svc => s.proxy;

  Timer? _pingTimer;
  bool _tickBusy = false;
  bool _pinging = false;
  bool _reloading = false;

  /// A connect / switch call started here is still running.
  bool _acting = false;

  /// The LAN warning dialog is open (blocks a second tap opening another).
  bool _asking = false;

  /// Errors are shown only once this page started something (the game
  /// booster drives the same service and leaves its own errors behind).
  bool _ownsError = false;

  /// Country picked on this page most recently (retry target).
  String? _lastAttemptCode;

  List<Listenable> get _listenables =>
      [s.proxy, s.boost, s.license, s.network];

  @override
  void initState() {
    super.initState();
    for (final l in _listenables) {
      l.addListener(_onChanged);
    }
    _syncPingTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (svc.countries.isEmpty) {
        _reload();
      } else if (!_anyMeasured && !s.boost.usesTunnel) {
        _pingAll();
      }
    });
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _pingTimer = null;
    for (final l in _listenables) {
      l.removeListener(_onChanged);
    }
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    _syncPingTimer();
    setState(() {});
  }

  /// Ping the connected server every 5 s while a country VPN is up.
  void _syncPingTimer() {
    final want =
        svc.status == VpnProxyStatus.connected && !s.boost.usesTunnel;
    if (want && _pingTimer == null) {
      _pingTimer = Timer.periodic(
          const Duration(seconds: 5), (_) => _pingConnectedTick());
      _pingConnectedTick();
    } else if (!want && _pingTimer != null) {
      _pingTimer!.cancel();
      _pingTimer = null;
    }
  }

  Future<void> _pingConnectedTick() async {
    if (_tickBusy) return;
    _tickBusy = true;
    try {
      await svc.pingConnected();
    } catch (_) {
      // A missed sample just leaves the last ping on screen.
    } finally {
      _tickBusy = false;
    }
  }

  bool get _anyMeasured => svc.countries
      .any((c) => c.bestServer?.measuredPing != null);

  bool get _inNetwork => s.network.currentNetwork != null;
  bool get _isPremium => s.license.state.isPaid;
  bool get _tunnelBusy => s.boost.usesTunnel;
  bool get _active =>
      svc.status == VpnProxyStatus.connected ||
      svc.status == VpnProxyStatus.connecting;

  /// The country the big connect button uses: the one tried here last, the
  /// one used last time, the fastest measured, or simply the first.
  (ServerCountry, _Quick)? get _quick {
    final mine = _lastAttemptCode == null
        ? null
        : svc.findCountryByCode(_lastAttemptCode!);
    if (mine != null) return (mine, _Quick.recent);
    final last = svc.lastCountryCode == null
        ? null
        : svc.findCountryByCode(svc.lastCountryCode!);
    if (last != null) return (last, _Quick.recent);
    final measured = svc.countries
        .where((c) => c.bestServer?.measuredPing != null)
        .toList()
      ..sort((a, b) => a.bestServer!.measuredPing!
          .compareTo(b.bestServer!.measuredPing!));
    if (measured.isNotEmpty) return (measured.first, _Quick.fastest);
    final first = svc.countries.firstOrNull;
    return first == null ? null : (first, _Quick.first);
  }

  // ── Actions ───────────────────────────────────────────────────────────

  Future<void> _reload() async {
    if (_reloading) return;
    setState(() {
      _reloading = true;
      _ownsError = true;
    });
    await svc.fetchServers();
    if (!mounted) return;
    setState(() => _reloading = false);
    unawaited(_pingAll());
  }

  Future<void> _pingAll() async {
    if (_pinging || svc.countries.isEmpty) return;
    setState(() => _pinging = true);
    try {
      await svc.pingAllCountries();
    } catch (_) {
      // Unmeasured countries keep showing "—".
    }
    if (!mounted) return;
    setState(() => _pinging = false);
  }

  Future<void> _onCountryTap(ServerCountry country) async {
    if (_tunnelBusy) {
      m3Toast(context,
          'กำลังใช้โหมดลดปิงเกมอยู่ — ปิดโหมดลดปิงก่อนเลือกประเทศ',
          tone: M3Tone.amber);
      return;
    }
    if (svc.status == VpnProxyStatus.disconnecting || _asking) return;
    if (_acting) {
      m3Toast(context, 'กำลังเชื่อมต่ออยู่ รอสักครู่…', tone: M3Tone.amber);
      return;
    }
    final same = svc.connectedCountry?.toUpperCase() ==
        country.countryCode.toUpperCase();
    if (same && svc.status == VpnProxyStatus.connected) {
      m3Toast(context, 'เชื่อมต่อ ${country.countryName} อยู่แล้ว',
          tone: M3Tone.green);
      return;
    }
    if (same && svc.status == VpnProxyStatus.connecting) return;

    HapticFeedback.mediumImpact();

    // Phones run one VPN at a time: the country VPN replaces the LAN tunnel.
    // On Windows the tunnel leaves private ranges local, so the LAN stays.
    if (_inNetwork && !isWindows && !_active) {
      _asking = true;
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.networks,
        title: 'LAN เสมือนจะหยุดชั่วคราว',
        message: 'Android อนุญาต VPN ได้ครั้งละ 1 อุโมงค์เท่านั้น\n\n'
            'เมื่อเปิด VPN ประเทศ → LAN เสมือนจะหยุดทำงานชั่วคราว '
            'สมาชิกในวงจะเห็นคุณออฟไลน์\n\n'
            'ปิด VPN ประเทศ → LAN เสมือนจะกลับมาทำงานอัตโนมัติ',
        confirmLabel: 'เปิด VPN ต่อ',
      );
      _asking = false;
      if (!ok || !mounted) return;
    }
    await _connect(country);
  }

  Future<void> _connect(ServerCountry country) async {
    setState(() {
      _acting = true;
      _ownsError = true;
      _lastAttemptCode = country.countryCode;
    });
    try {
      if (_active) {
        // Race-safe reconnect: disconnects first, then connects.
        await svc.switchToCountry(country);
      } else {
        await svc.connectToCountry(country);
      }
    } catch (_) {
      if (mounted) {
        m3Toast(context, 'เชื่อมต่อไม่สำเร็จ กรุณาลองใหม่อีกครั้ง',
            tone: M3Tone.red);
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _disconnect() async {
    HapticFeedback.heavyImpact();
    await svc.disconnect();
  }

  void _onLockedTap(ServerCountry country) {
    if (_isPremium) {
      // Paid already, but the server list still has it locked (it was
      // fetched before the licence changed).
      m3Toast(
        context,
        'ประเทศนี้ยังล็อกอยู่ — กำลังโหลดรายการใหม่ ถ้ายังล็อกให้เปิดแอปใหม่',
        tone: M3Tone.amber,
      );
      _reload();
      return;
    }
    _showUpgrade(country);
  }

  void _showUpgrade([ServerCountry? country]) {
    showM3Dialog(
      context,
      icon3d: M3Icons.crown,
      title: country == null
          ? 'ปลดล็อกทุกประเทศด้วย PRO'
          : '${country.countryName} สำหรับสมาชิก PRO',
      message: 'อัปเกรดเป็น PRO เพื่อ:',
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Perk('VPN มุดได้ทุกประเทศ'),
          _Perk('สมาชิกในวง LAN สูงสุด 50 คน'),
          _Perk('ซัพพอร์ตพรีเมียม'),
        ],
      ),
      actions: (ctx) => [
        GlossButton(
          label: 'ไว้ทีหลัง',
          variant: GlossVariant.glass,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
        GlossButton(
          label: 'ดูแพ็กเกจ PRO',
          variant: GlossVariant.gold,
          icon3d: M3Icons.crown,
          onPressed: () {
            Navigator.of(ctx).pop();
            _openPurchase();
          },
        ),
      ],
    );
  }

  Future<void> _openPurchase() async {
    final uri = Uri.tryParse(s.license.getPurchaseUrl('monthly'));
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!mounted) return;
    if (!ok) {
      m3Toast(context, 'เปิดหน้าแพ็กเกจไม่ได้ กรุณาลองใหม่อีกครั้ง',
          tone: M3Tone.red);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final shell = AppShellScope.of(context);
    final boost = s.boost;
    final tunnelBusy = boost.usesTunnel;
    final status = svc.status;
    final connected = !tunnelBusy && status == VpnProxyStatus.connected;
    final net = s.network.currentNetwork;
    final quick = _quick;
    final countries = svc.countries;
    final locked = svc.lockedCountries;
    final loading = svc.isLoading || _reloading;

    final showError = svc.error != null &&
        _ownsError &&
        !tunnelBusy &&
        countries.isNotEmpty;

    return M3PageBody(
      onRefresh: _reload,
      children: [
        M3PageHeader(
          icon3d: M3Icons.vpnProxy,
          title: 'VPN ประเทศ',
          subtitle: 'เปลี่ยนประเทศของอินเทอร์เน็ตผ่าน WireGuard — '
              'ปลดล็อกเกม/เว็บต่างประเทศ',
          trailing: const ShellBadges(),
        ),
        const SizedBox(height: 16),
        if (isWindows && !shell.isElevated) ...[
          M3Banner(
            tone: M3Tone.amber,
            icon3d: M3Icons.adapter,
            title: 'ต้องเปิดแบบผู้ดูแลระบบ',
            message: 'WireGuard บน Windows ต้องใช้สิทธิ์ผู้ดูแลระบบ'
                'ในการสร้างอุโมงค์ VPN',
            action: GlossButton(
              label: 'เปิดใหม่แบบผู้ดูแล',
              size: GlossSize.small,
              variant: GlossVariant.gold,
              onPressed: shell.relaunchAsAdmin,
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (tunnelBusy) ...[
          M3Banner(
            tone: M3Tone.cyan,
            icon3d: M3Icons.gameBoost,
            title: 'กำลังใช้โหมดลดปิงเกมอยู่',
            message: boost.isActive
                ? 'อุโมงค์ WireGuard กำลังลดปิงผ่าน '
                    '${boost.activeRelay?.countryName ?? 'รีเลย์'} — '
                    'ปิดโหมดลดปิงก่อนจึงจะเลือกประเทศได้ (ใช้ได้ทีละอุโมงค์)'
                : 'ตัววิเคราะห์เส้นทางกำลังทดสอบรีเลย์ผ่านอุโมงค์ WireGuard — '
                    'รอให้เสร็จหรือยกเลิกก่อน แล้วค่อยเลือกประเทศ',
            action: GlossButton(
              label: 'ไปหน้าลดปิง',
              size: GlossSize.small,
              onPressed: () => shell.goTo(ShellTab.boost),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (connected && net != null && svc.routing == WgRouting.server) ...[
          const M3Banner(
            tone: M3Tone.amber,
            icon3d: M3Icons.networks,
            title: 'LAN เสมือนหยุดชั่วคราว',
            message: 'เปิด VPN ได้ทีละหนึ่งอุโมงค์ — '
                'ปิด VPN ประเทศเพื่อกลับไปใช้วง LAN',
          ),
          const SizedBox(height: 14),
        ],
        if (showError) ...[
          M3Banner(
            tone: M3Tone.red,
            icon: Icons.error_rounded,
            title: _friendlyError(svc.error!),
            action: GlossIconButton(
              icon: Icons.close_rounded,
              tooltip: 'ปิด',
              onPressed: svc.clearError,
            ),
          ),
          const SizedBox(height: 14),
        ],
        _Hero(
          services: s,
          quick: quick,
          acting: _acting,
          onConnect: _onCountryTap,
          onDisconnect: _disconnect,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 18),
        M3SectionTitle(
          'เลือกประเทศ',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (countries.isNotEmpty && (loading || _pinging)) ...[
                _BusyNote(loading ? 'กำลังโหลด…' : 'กำลังวัดปิง…'),
                const SizedBox(width: 10),
              ],
              GlossIconButton(
                icon: Icons.speed_rounded,
                tooltip: 'วัดปิงใหม่',
                onPressed:
                    _pinging || countries.isEmpty ? null : () => _pingAll(),
              ),
              const SizedBox(width: 8),
              GlossIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'โหลดรายการประเทศใหม่',
                onPressed: loading ? null : () => _reload(),
              ),
            ],
          ),
        ),
        if (countries.isEmpty && loading)
          GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.vpnProxy,
              title: 'กำลังโหลดรายการ VPN…',
              message: 'กำลังดึงรายชื่อประเทศและเซิร์ฟเวอร์ WireGuard',
              action: const SizedBox(
                width: 200,
                child: M3ProgressBar(height: 8),
              ),
            ),
          )
        else if (countries.isEmpty)
          GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.vpnProxy,
              title: 'ไม่สามารถโหลดรายการ VPN ได้',
              message: svc.error != null && _ownsError
                  ? _friendlyError(svc.error!)
                  : 'เซิร์ฟเวอร์อาจไม่พร้อมใช้งานชั่วคราว\nกรุณาลองใหม่อีกครั้ง',
              action: GlossButton(
                label: 'ลองใหม่',
                icon: Icons.refresh_rounded,
                loading: _reloading,
                onPressed: _reloading ? null : () => _reload(),
              ),
            ),
          )
        else
          _Grid(
            children: [
              for (var i = 0; i < countries.length; i++)
                _CountryTile(
                  country: countries[i],
                  state: _tileState(countries[i]),
                  recent: !_active &&
                      quick != null &&
                      quick.$2 == _Quick.recent &&
                      quick.$1.countryCode == countries[i].countryCode,
                  dimmed: tunnelBusy,
                  onTap: () => _onCountryTap(countries[i]),
                )
                    .animate()
                    .fadeIn(
                        delay: ((i < 8 ? i : 8) * 40).ms, duration: 300.ms)
                    .slideY(begin: 0.06, end: 0),
            ],
          ),
        if (locked.isNotEmpty) ...[
          const SizedBox(height: 18),
          M3SectionTitle(
            'ปลดล็อกด้วย PRO',
            trailing: _isPremium
                ? null
                : GlossButton(
                    label: 'อัปเกรด',
                    size: GlossSize.small,
                    variant: GlossVariant.gold,
                    icon3d: M3Icons.crown,
                    onPressed: () => _showUpgrade(),
                  ),
          ),
          _Grid(
            children: [
              for (final c in locked)
                _CountryTile(
                  country: c,
                  state: _TileState.idle,
                  locked: true,
                  onTap: () => _onLockedTap(c),
                ),
            ],
          ),
        ],
      ],
    );
  }

  _TileState _tileState(ServerCountry c) {
    if (_tunnelBusy) return _TileState.idle;
    final same =
        svc.connectedCountry?.toUpperCase() == c.countryCode.toUpperCase();
    if (!same) return _TileState.idle;
    return switch (svc.status) {
      VpnProxyStatus.connected => _TileState.connected,
      VpnProxyStatus.connecting => _TileState.connecting,
      _ => _TileState.idle,
    };
  }
}

/// The service reports errors in English; say them in Thai where we know
/// them (server messages are shown as they come).
String _friendlyError(String e) {
  if (e == 'VPN permission denied') {
    return isWindows
        ? 'Windows ไม่อนุญาตให้สร้างอุโมงค์ VPN — เปิดแอปแบบผู้ดูแลระบบแล้วลองใหม่'
        : 'ไม่ได้รับอนุญาตให้เปิด VPN — กดอนุญาตเมื่อระบบถาม แล้วลองใหม่';
  }
  if (e == 'VPN connection failed') {
    return 'เชื่อมต่อ VPN ไม่สำเร็จ ลองใหม่หรือเลือกประเทศอื่น';
  }
  if (e.startsWith('Tried ')) {
    return 'ลองเซิร์ฟเวอร์ทุกตัวในประเทศนี้แล้วแต่เชื่อมต่อไม่ได้ ลองประเทศอื่น';
  }
  if (e.startsWith('Could not connect to VPN')) {
    return 'เชื่อมต่อ VPN ไม่ได้ กรุณาลองใหม่อีกครั้ง';
  }
  if (e.startsWith('Could not reconnect')) {
    return 'เชื่อมต่อใหม่ไม่สำเร็จ กรุณาลองใหม่อีกครั้ง';
  }
  if (e.startsWith('Server error')) {
    final code = RegExp(r'\d+').firstMatch(e)?.group(0);
    return 'เซิร์ฟเวอร์ขัดข้อง${code == null ? '' : ' ($code)'} '
        'กรุณาลองใหม่ภายหลัง';
  }
  if (e == 'Could not load VPN servers' || e == 'Failed to load server list') {
    return 'โหลดรายชื่อเซิร์ฟเวอร์ VPN ไม่ได้ ตรวจสอบอินเทอร์เน็ตแล้วลองใหม่';
  }
  if (e == 'No servers available for this country') {
    return 'ประเทศนี้ยังไม่มีเซิร์ฟเวอร์ที่ใช้ได้ ลองประเทศอื่น';
  }
  if (e.startsWith('Connection timeout')) {
    return 'เซิร์ฟเวอร์ตอบช้าเกินไป กรุณาลองใหม่อีกครั้ง';
  }
  if (e == 'Cached config is invalid') {
    return 'ข้อมูลการเชื่อมต่อที่จำไว้ใช้ไม่ได้ ลองใหม่เมื่อออนไลน์';
  }
  return e;
}

String _flagEmoji(String code) {
  final cc = code.toUpperCase();
  if (cc.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(cc)) return '';
  return String.fromCharCodes(
      [0x1F1E6 + cc.codeUnitAt(0) - 0x41, 0x1F1E6 + cc.codeUnitAt(1) - 0x41]);
}

String _fmtDuration(Duration? d) {
  if (d == null) return '00:00';
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final sec = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

M3Tone? _pingTone(int? ms) {
  if (ms == null) return null;
  if (ms < 60) return M3Tone.green;
  if (ms < 120) return M3Tone.amber;
  return M3Tone.red;
}

// ── Hero ────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final AppServices services;
  final (ServerCountry, _Quick)? quick;
  final bool acting;
  final ValueChanged<ServerCountry> onConnect;
  final VoidCallback onDisconnect;

  const _Hero({
    required this.services,
    required this.quick,
    required this.acting,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final svc = services.proxy;
    final boost = services.boost;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final tunnelBusy = boost.usesTunnel;
    final status = svc.status;
    final connected = !tunnelBusy && status == VpnProxyStatus.connected;
    final connecting = !tunnelBusy && status == VpnProxyStatus.connecting;
    final disconnecting =
        !tunnelBusy && status == VpnProxyStatus.disconnecting;
    final failed = !tunnelBusy && status == VpnProxyStatus.error;
    final keepsLan = svc.routing == WgRouting.internetOnly;

    final code = svc.connectedCountry;
    final country = code == null ? null : svc.findCountryByCode(code);
    final countryName = country?.countryName ?? code ?? '';
    final net = services.network.currentNetwork;

    final (String headline, Color headColor, Color orbColor) = tunnelBusy
        ? ('ใช้โดยโหมดลดปิงเกม', p.text, p.amber)
        : connected
            ? ('เชื่อมต่อแล้ว', p.green, p.green)
            : connecting
                ? ('กำลังเชื่อมต่อ…', p.text, p.amber)
                : disconnecting
                    ? ('กำลังตัดการเชื่อมต่อ…', p.text, p.amber)
                    : failed
                        ? ('เชื่อมต่อไม่สำเร็จ', p.red, p.red)
                        : ('พร้อมเชื่อมต่อ', p.text, p.text3);

    final String detail;
    if (tunnelBusy) {
      detail = 'อุโมงค์ WireGuard มีได้ทีละหนึ่ง — '
          'ปิดโหมดลดปิงเกมก่อนจึงจะเลือกประเทศได้';
    } else if (connected) {
      detail = keepsLan
          ? 'อินเทอร์เน็ตของเครื่องนี้ออกที่ $countryName · '
              'LAN ในบ้านและวง LAN เสมือนยังใช้ได้ตามปกติ'
          : 'อินเทอร์เน็ตของเครื่องนี้ออกที่ $countryName';
    } else if (connecting) {
      detail = 'กำลังขอค่าเชื่อมต่อและเปิดอุโมงค์ — '
          'ถ้าเซิร์ฟเวอร์ไม่ตอบ จะลองเซิร์ฟเวอร์ถัดไปให้เอง';
    } else if (disconnecting) {
      detail = 'กำลังปิดอุโมงค์และคืนเส้นทางอินเทอร์เน็ตตามปกติ';
    } else if (failed) {
      detail = 'ลองใหม่อีกครั้ง หรือเลือกประเทศอื่นด้านล่าง';
    } else if (svc.countries.isEmpty) {
      detail = 'กำลังรอรายชื่อประเทศจากเซิร์ฟเวอร์';
    } else {
      detail = 'เลือกประเทศด้านล่าง หรือกดเชื่อมต่อด่วน — '
          'เว็บและเกมจะเห็นคุณอยู่ในประเทศนั้น';
    }

    // Country line
    Widget? countryLine;
    if (tunnelBusy) {
      final r = boost.activeRelay;
      if (r != null) {
        countryLine = _CountryLine(
            code: r.countryCode, name: 'ผ่าน ${r.countryName}', muted: true);
      }
    } else if ((connected || connecting || disconnecting) && code != null) {
      countryLine = _CountryLine(code: code, name: countryName);
    } else if (quick != null) {
      countryLine = _CountryLine(
        code: quick!.$1.countryCode,
        name: quick!.$1.countryName,
        muted: true,
        note: switch (quick!.$2) {
          _Quick.recent => 'ใช้ล่าสุด',
          _Quick.fastest => 'ปิงต่ำสุด',
          _Quick.first => null,
        },
      );
    }

    // Server hostname + fallback progress + LAN sharing
    final host = svc.connectedHostname;
    final info = svc.connectingServerInfo
        ?.replaceFirst('server ', 'เซิร์ฟเวอร์ ')
        .replaceFirst('round ', 'รอบที่ ');
    final tags = <Widget>[
      if ((connected || connecting) && host != null && host.isNotEmpty)
        Text(host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: M3Text.mono(context, size: 12.5)),
      if (connecting && info != null) M3Tag(info, tone: M3Tone.amber),
      if (connected && keepsLan && net != null)
        M3Tag('แชร์ VPN ให้วง "${net.name}"',
            tone: M3Tone.gold, icon: Icons.share_rounded),
    ];

    // Live numbers
    final ping = connected ? svc.currentPing : null;
    final tone = _pingTone(ping);
    final metrics = <Widget>[
      _Metric(
        label: 'ปิง',
        value: ping == null ? '—' : '$ping ms',
        color: tone == null ? null : p.toneColor(tone),
        red: tone == M3Tone.red,
        narrow: narrow,
      ),
      _Metric(
        label: 'เวลาเชื่อมต่อ',
        value: connected ? _fmtDuration(svc.duration) : '—',
        narrow: narrow,
      ),
      _Metric(
        label: 'ดาวน์โหลด',
        icon: Icons.south_rounded,
        value: connected ? (svc.byteIn ?? '0 B') : '—',
        narrow: narrow,
      ),
      _Metric(
        label: 'อัปโหลด',
        icon: Icons.north_rounded,
        value: connected ? (svc.byteOut ?? '0 B') : '—',
        narrow: narrow,
      ),
    ];

    // Main button
    final Widget mainButton;
    if (tunnelBusy) {
      mainButton = const GlossButton(
        label: 'เชื่อมต่อด่วน',
        icon: Icons.power_settings_new,
        size: GlossSize.large,
        expand: true,
      );
    } else if (disconnecting) {
      mainButton = const GlossButton(
        label: 'กำลังตัดการเชื่อมต่อ…',
        variant: GlossVariant.red,
        size: GlossSize.large,
        expand: true,
        loading: true,
      );
    } else if (connected || connecting) {
      mainButton = GlossButton(
        label: connecting ? 'ยกเลิกการเชื่อมต่อ' : 'ตัดการเชื่อมต่อ',
        icon: Icons.stop_rounded,
        variant: GlossVariant.red,
        size: GlossSize.large,
        expand: true,
        onPressed: onDisconnect,
      );
    } else {
      final target = quick?.$1;
      mainButton = GlossButton(
        label: failed ? 'ลองใหม่' : 'เชื่อมต่อด่วน',
        icon: failed ? Icons.refresh_rounded : Icons.power_settings_new,
        size: GlossSize.large,
        expand: true,
        loading: acting,
        onPressed:
            target == null || acting ? null : () => onConnect(target),
      );
    }

    final paid = services.license.state.isPaid;
    final side = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        mainButton,
        const SizedBox(height: 10),
        Center(
          child: M3Tag(
            paid
                ? 'PRO · VPN ทุกประเทศ'
                : 'FREE · ${svc.countries.length} ประเทศ',
            tone: paid ? M3Tone.gold : M3Tone.neutral,
            icon: paid ? Icons.workspace_premium_rounded : null,
          ),
        ),
      ],
    );

    final orb = Icon3D(
      M3Icons.vpnProxy,
      size: narrow ? 92 : 132,
      opacity: tunnelBusy ? 0.55 : 1,
      glow: connected
          ? p.green.withValues(alpha: 0.45)
          : connecting
              ? p.amber.withValues(alpha: 0.32)
              : null,
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusOrb(
              color: orbColor,
              size: 11,
              pulse: connected || connecting,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                headline,
                style: TextStyle(
                  fontFamily: M3Fonts.head,
                  fontSize: narrow ? 24 : 31,
                  fontWeight: FontWeight.w700,
                  color: headColor,
                  shadows: p.titleShadow,
                ),
              ),
            ),
          ],
        ),
        if (countryLine != null) ...[
          const SizedBox(height: 6),
          countryLine,
        ],
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: tags,
          ),
        ],
        const SizedBox(height: 6),
        Text(detail, style: M3Text.sub(context).copyWith(fontSize: 13.5)),
      ],
    );

    final numbers = Wrap(
      spacing: narrow ? 20 : 30,
      runSpacing: 10,
      children: metrics,
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: connected
          ? p.green
          : failed
              ? p.red
              : connecting
                  ? p.amber
                  : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    orb,
                    const SizedBox(width: 14),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: 16),
                numbers,
                const SizedBox(height: 16),
                side,
              ],
            )
          : Row(
              children: [
                orb,
                const SizedBox(width: 22),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      text,
                      const SizedBox(height: 16),
                      numbers,
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                SizedBox(width: 250, child: side),
              ],
            ),
    );
  }
}

class _CountryLine extends StatelessWidget {
  final String code;
  final String name;
  final bool muted;
  final String? note;

  const _CountryLine({
    required this.code,
    required this.name,
    this.muted = false,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Row(
      children: [
        _Flag(code: code, size: narrow ? 24 : 28),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: M3Fonts.head,
              fontSize: narrow ? 17 : 20,
              fontWeight: FontWeight.w600,
              color: muted ? p.text2 : p.text,
            ),
          ),
        ),
        if (note != null) ...[
          const SizedBox(width: 8),
          M3Tag(note!, tone: M3Tone.neutral),
        ],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color? color;
  final bool red;
  final bool narrow;

  const _Metric({
    required this.label,
    required this.value,
    required this.narrow,
    this.icon,
    this.color,
    this.red = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: M3Text.num(context,
              size: narrow ? 20 : 24, color: color, red: red),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: p.text3),
              const SizedBox(width: 3),
            ],
            Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
          ],
        ),
      ],
    );
  }
}

// ── Country grid ────────────────────────────────────────────────────────

class _Grid extends StatelessWidget {
  final List<Widget> children;
  const _Grid({required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      // Name, flag and ping tag need ~270 px per tile.
      final cols = c.maxWidth >= 1120
          ? 4
          : c.maxWidth >= 880
              ? 3
              : c.maxWidth >= 560
                  ? 2
                  : 1;
      const gap = 14.0;
      final w = ((c.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: w, child: child),
        ],
      );
    });
  }
}

class _CountryTile extends StatelessWidget {
  final ServerCountry country;
  final _TileState state;
  final bool locked;
  final bool recent;
  final bool dimmed;
  final VoidCallback onTap;

  const _CountryTile({
    required this.country,
    required this.state,
    required this.onTap,
    this.locked = false,
    this.recent = false,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final best = country.bestServer;
    final load = best?.load;
    final active = state != _TileState.idle;
    final faded = locked || dimmed;

    Widget dim(Widget w) => faded ? Opacity(opacity: 0.5, child: w) : w;

    final servers = '${country.serverCount} เซิร์ฟเวอร์';
    final subline = switch (state) {
      _TileState.connected => 'เชื่อมต่ออยู่ · $servers',
      _TileState.connecting => 'กำลังเชื่อมต่อ…',
      _TileState.idle => recent ? '$servers · ใช้ล่าสุด' : servers,
    };

    final loadTone = load == null
        ? M3Tone.cyan
        : load < 30
            ? M3Tone.green
            : load < 70
                ? M3Tone.amber
                : M3Tone.red;

    final Widget trailing;
    if (locked) {
      trailing = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon3D(M3Icons.crown, size: 30),
          SizedBox(width: 4),
          M3Tag('PRO', tone: M3Tone.gold),
        ],
      );
    } else {
      final ms = best?.measuredPing;
      final tone = _pingTone(ms);
      trailing = dim(M3Tag(
        ms == null ? '—' : '$ms ms',
        tone: tone ?? M3Tone.neutral,
        dot: tone != null,
      ));
    }

    return GlassPanel(
      onTap: onTap,
      highlight: active,
      accent: switch (state) {
        _TileState.connected => p.green,
        _TileState.connecting => p.amber,
        _TileState.idle => null,
      },
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              dim(_Flag(code: country.countryCode, size: 34)),
              const SizedBox(width: 12),
              Expanded(
                child: dim(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            country.countryName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: M3Text.h2(context),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 6),
                          StatusOrb(
                            color: state == _TileState.connected
                                ? p.green
                                : p.amber,
                            size: 9,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: M3Text.sub(context).copyWith(
                        fontSize: 12,
                        color: state == _TileState.connected
                            ? p.green
                            : null,
                      ),
                    ),
                  ],
                )),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
          const SizedBox(height: 12),
          dim(Row(
            children: [
              Expanded(
                child: M3ProgressBar(
                  value: load == null ? 0 : load / 100,
                  height: 8,
                  tone: loadTone,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                load == null ? 'โหลด —' : 'โหลด $load%',
                style: M3Text.sub(context).copyWith(fontSize: 11.5),
              ),
            ],
          )),
        ],
      ),
    );
  }
}

/// Country flag. Windows' emoji font has no flag glyphs (it prints two
/// loose letters), so there the country code goes on a small glass plate.
class _Flag extends StatelessWidget {
  final String code;
  final double size;

  const _Flag({required this.code, required this.size});

  @override
  Widget build(BuildContext context) {
    final emoji = _flagEmoji(code);
    if (!isWindows && emoji.isNotEmpty) {
      return SizedBox(
        width: size * 1.3,
        child: Text(
          emoji,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: size, height: 1.15),
        ),
      );
    }
    final p = context.m3;
    final r = BorderRadius.circular(size * 0.22);
    return Container(
      width: size * 1.3,
      height: size * 0.95,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: p.glassBtn,
        borderRadius: r,
        border: Border.all(color: p.isNight ? p.line : p.inputLine),
      ),
      foregroundDecoration: BoxDecoration(
        gradient: M3Fx.btnGloss,
        borderRadius: r,
      ),
      child: Text(
        code.isEmpty ? '?' : code.toUpperCase(),
        style: TextStyle(
          fontFamily: M3Fonts.head,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          height: 1,
          color: p.glassBtnText,
        ),
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  final String text;
  const _Perk(this.text);

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: p.gold),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: M3Text.body(context))),
        ],
      ),
    );
  }
}

class _BusyNote extends StatelessWidget {
  final String text;
  const _BusyNote(this.text);

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 2, color: p.cyan),
        ),
        const SizedBox(width: 7),
        Text(text, style: M3Text.sub(context)),
      ],
    );
  }
}
