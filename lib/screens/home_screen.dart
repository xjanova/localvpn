import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/member.dart';
import '../platform/platform_info.dart';
import '../services/game_boost_service.dart';
import '../services/vpn_proxy_service.dart';
import '../widgets/m3/m3.dart';
import '../services/p2p_service.dart';
import '../widgets/peer_path_tag.dart';
import 'network_detail_screen.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "ภาพรวม" — the dashboard: connection hero, live numbers, the current
/// network's members and shortcuts to every feature.
class HomeScreen extends StatefulWidget {
  final AppServices services;

  const HomeScreen({super.key, required this.services});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    for (final l in _listenables) {
      l.addListener(_refresh);
    }
  }

  List<Listenable> get _listenables =>
      [s.vpn, s.network, s.p2p, s.proxy, s.boost, s.license];

  @override
  void dispose() {
    for (final l in _listenables) {
      l.removeListener(_refresh);
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleLan() async {
    if (s.vpn.isConnected) {
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.power,
        title: 'ตัดการเชื่อมต่อ LAN เสมือน?',
        message: 'เกมและไฟล์ที่แชร์ผ่านวงนี้จะหยุดทำงานจนกว่าจะเชื่อมต่อใหม่',
        confirmLabel: 'ตัดการเชื่อมต่อ',
        destructive: true,
      );
      if (ok) await s.vpn.stopVpn();
      return;
    }
    final vip = s.network.ownVirtualIp;
    if (vip == null) {
      m3Toast(context, 'ยังไม่ได้รับ Virtual IP จากเซิร์ฟเวอร์ ลองอีกครั้งในไม่กี่วินาที',
          tone: M3Tone.amber);
      return;
    }
    final ok = await s.vpn.startVpn(
      virtualIp: vip,
      subnet: s.network.currentNetwork?.virtualSubnet ?? '10.10.0.0/24',
      peers: const [],
    );
    if (!mounted) return;
    if (!ok && s.vpn.needsAdmin) {
      _askAdmin();
    } else if (!ok && s.vpn.error != null) {
      m3Toast(context, s.vpn.error!, tone: M3Tone.red);
    }
  }

  void _askAdmin() {
    showM3Dialog(
      context,
      icon3d: M3Icons.adapter,
      title: 'ต้องใช้สิทธิ์ผู้ดูแลระบบ',
      message: 'การสร้างการ์ดเครือข่ายเสมือนบน Windows ต้องเปิด LocalVPN '
          'แบบ "Run as administrator" กดปุ่มด้านล่างเพื่อเปิดใหม่ '
          '(Windows จะถามยืนยัน)',
      actions: (ctx) => [
        GlossButton(
          label: 'ไว้ทีหลัง',
          variant: GlossVariant.glass,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
        GlossButton(
          label: 'เปิดใหม่แบบผู้ดูแลระบบ',
          icon: Icons.admin_panel_settings_rounded,
          onPressed: () {
            Navigator.of(ctx).pop();
            AppShellScope.of(context).relaunchAsAdmin();
          },
        ),
      ],
    );
  }

  void _openNetwork() {
    final net = s.network.currentNetwork;
    if (net == null) {
      AppShellScope.of(context).goTo(ShellTab.networks);
      return;
    }
    Navigator.of(context).push(M3PageRoute(
      builder: (_) => NetworkDetailScreen(services: s, network: net),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final shell = AppShellScope.of(context);
    // With LocalVPNService the virtual LAN needs no admin rights; VPN and
    // the boost say so on their own pages.
    final showAdmin = isWindows && !shell.canRunLan;

    return M3PageBody(
      onRefresh: () async {
        final slug = s.network.currentNetwork?.slug;
        if (slug != null) await s.network.getMembers(slug);
      },
      children: [
        M3PageHeader(
          icon3d: M3Icons.power,
          title: 'ภาพรวม',
          subtitle: 'LAN เสมือน · ลดปิงเกม · ส่งไฟล์ ในที่เดียว',
          trailing: const ShellBadges(),
        ),
        const SizedBox(height: 16),
        if (showAdmin) ...[
          M3Banner(
            tone: M3Tone.amber,
            icon3d: M3Icons.adapter,
            title: 'ยังไม่ได้เปิดแบบผู้ดูแลระบบ',
            message: 'การ์ดเครือข่ายเสมือน, VPN และการปรับแต่งเพื่อลดปิง '
                'ต้องใช้สิทธิ์ผู้ดูแลระบบของ Windows',
            action: GlossButton(
              label: 'เปิดใหม่แบบผู้ดูแล',
              size: GlossSize.small,
              variant: GlossVariant.gold,
              onPressed: shell.relaunchAsAdmin,
            ),
          ),
          const SizedBox(height: 14),
        ],
        // Members that can't be reached yet: NAT, blocked UDP, relay quota
        if (s.p2p.securityNotice == null)
          if (s.p2p.connectivityNotice case final notice?) ...[
            M3Banner(
              tone: M3Tone.amber,
              icon: Icons.wifi_tethering_error_rounded,
              title: 'ยังเชื่อมต่อเพื่อนบางคนไม่ได้',
              message: notice,
            ),
            const SizedBox(height: 14),
          ],
        // Members that can't be reached because of the app version
        if (s.p2p.securityNotice case final notice?) ...[
          M3Banner(
            tone: M3Tone.amber,
            icon: Icons.lock_outline,
            title: 'เชื่อมต่อกับบางคนในวงไม่ได้',
            message: notice,
          ),
          const SizedBox(height: 14),
        ],
        _Hero(
          services: s,
          onToggle: _toggleLan,
          onOpenNetwork: _openNetwork,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 16),
        _StatGrid(services: s, columns: w >= 1100 ? 4 : 2)
            .animate()
            .fadeIn(delay: 80.ms, duration: 350.ms),
        const SizedBox(height: 16),
        if (w >= 1100)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: _MembersCard(services: s, onOpen: _openNetwork),
              ),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: _Shortcuts(services: s)),
            ],
          )
        else ...[
          _Shortcuts(services: s),
          const SizedBox(height: 16),
          _MembersCard(services: s, onOpen: _openNetwork),
        ],
      ],
    );
  }
}

// ── Hero ────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final AppServices services;
  final VoidCallback onToggle;
  final VoidCallback onOpenNetwork;

  const _Hero({
    required this.services,
    required this.onToggle,
    required this.onOpenNetwork,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final s = services;
    final net = s.network.currentNetwork;
    final connected = s.vpn.isConnected;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final headline = connected
        ? 'เชื่อมต่อ LAN แล้ว'
        : (net == null ? 'ยังไม่ได้เข้าร่วมวง' : 'พร้อมเชื่อมต่อ');
    final detail = connected
        ? 'อยู่ในวง "${net?.name ?? '-'}" — เครื่องในวงมองเห็นกันเหมือนเสียบสาย LAN เดียวกัน'
        : net == null
            ? 'สร้างวงใหม่หรือเข้าร่วมวงของเพื่อน แล้วกดเชื่อมต่อ'
            : 'วง "${net.name}" — กดเชื่อมต่อเพื่อเปิดการ์ดเครือข่ายเสมือน';

    final metrics = <(String, String)>[
      ('Virtual IP', s.vpn.virtualIp ?? s.network.ownVirtualIp ?? '—'),
      (
        'ออนไลน์',
        net == null
            ? '—'
            : '${s.network.members.where((m) => m.isOnline).length}/${s.network.members.length}'
      ),
      ('P2P ตรง', connected ? '${s.vpn.directPeers}' : '—'),
      ('ผ่านรีเลย์', connected ? '${s.vpn.relayPeers}' : '—'),
    ];

    final orb = Icon3D(
      connected ? M3Icons.p2pDirect : M3Icons.power,
      size: narrow ? 92 : 132,
      glow: connected ? p.green.withValues(alpha: 0.45) : p.logoGlow,
    );

    final buttons = Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
      children: [
        if (net != null)
          GlossButton(
            label: connected ? 'ตัดการเชื่อมต่อ' : 'เชื่อมต่อ LAN',
            icon: connected ? Icons.stop_rounded : Icons.power_settings_new,
            variant: connected ? GlossVariant.red : GlossVariant.aqua,
            size: GlossSize.large,
            loading: s.vpn.isStarting,
            onPressed: s.vpn.isStarting ? null : onToggle,
          )
        else
          GlossButton(
            label: 'ค้นหาวง',
            icon3d: M3Icons.scan,
            size: GlossSize.large,
            onPressed: () =>
                AppShellScope.of(context).goTo(ShellTab.networks),
          ),
        GlossButton(
          label: net == null ? 'สร้างวงใหม่' : 'รายละเอียดวง',
          variant: GlossVariant.glass,
          size: GlossSize.large,
          onPressed: onOpenNetwork,
        ),
      ],
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusOrb(
              color: connected ? p.green : (net == null ? p.text3 : p.amber),
              size: 11,
              pulse: connected,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                headline,
                style: TextStyle(
                  fontFamily: M3Fonts.head,
                  fontSize: narrow ? 24 : 31,
                  fontWeight: FontWeight.w700,
                  color: connected ? p.green : p.text,
                  shadows: p.titleShadow,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(detail, style: M3Text.sub(context).copyWith(fontSize: 13.5)),
        const SizedBox(height: 14),
        Wrap(
          spacing: narrow ? 18 : 30,
          runSpacing: 10,
          children: [
            for (final (label, value) in metrics)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: label == 'Virtual IP'
                        ? M3Text.mono(context,
                            size: narrow ? 16 : 19,
                            weight: FontWeight.w700,
                            color: p.numText)
                        : M3Text.num(context, size: narrow ? 20 : 24),
                  ),
                  Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
                ],
              ),
          ],
        ),
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: connected ? p.green : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    orb,
                    const SizedBox(width: 14),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: 16),
                buttons,
              ],
            )
          : Row(
              children: [
                orb,
                const SizedBox(width: 22),
                Expanded(child: text),
                const SizedBox(width: 18),
                SizedBox(width: 230, child: buttons),
              ],
            ),
    );
  }
}

// ── Stats ───────────────────────────────────────────────────────────────

class _StatGrid extends StatelessWidget {
  final AppServices services;
  final int columns;

  const _StatGrid({required this.services, required this.columns});

  @override
  Widget build(BuildContext context) {
    final s = services;
    final shell = AppShellScope.of(context);
    final online = s.network.members.where((m) => m.isOnline).length;
    final boost = s.boost;
    final live = boost.live.where((v) => v >= 0).toList();
    final pingNow = live.isNotEmpty
        ? live.last
        : (boost.direct?.sample.medianMs);
    final proxyOn = s.proxy.status == VpnProxyStatus.connected &&
        !boost.usesTunnel;

    final tiles = [
      M3StatTile(
        label: 'สมาชิกออนไลน์',
        value: '$online',
        sub: s.network.currentNetwork == null
            ? 'ยังไม่ได้เข้าร่วมวง'
            : 'จากทั้งหมด ${s.network.members.length} เครื่องในวง',
        icon3d: M3Icons.members,
        tone: online > 0 ? M3Tone.green : null,
        onTap: () => shell.goTo(ShellTab.devices),
      ),
      M3StatTile(
        label: 'เชื่อมตรงแบบ P2P',
        value: s.vpn.isConnected ? '${s.vpn.directPeers}' : '—',
        sub: s.vpn.isConnected
            ? 'ผ่านรีเลย์ ${s.vpn.relayPeers} เครื่อง'
            : 'เชื่อมต่อ LAN เพื่อเริ่ม',
        icon3d: M3Icons.p2pDirect,
        tone: M3Tone.cyan,
      ),
      M3StatTile(
        label: boost.isActive ? 'ปิงเกม (ลดปิงอยู่)' : 'ปิงไปเซิร์ฟเกม',
        value: pingNow == null ? '—' : '${pingNow.round()} ms',
        sub: boost.isActive
            ? 'ผ่าน ${boost.activeRelay?.countryName ?? ''} → ${boost.targetLabel}'
            : (boost.direct == null
                ? 'ยังไม่ได้วัด — ไปที่ลดปิงเกม'
                : 'เส้นทางตรงไป ${boost.targetLabel}'),
        icon3d: M3Icons.ping,
        tone: pingNow == null
            ? null
            : (pingNow < 60
                ? M3Tone.green
                : pingNow < 120
                    ? M3Tone.amber
                    : M3Tone.red),
        onTap: () => shell.goTo(ShellTab.boost),
      ),
      M3StatTile(
        label: 'VPN ประเทศ',
        value: proxyOn ? (s.proxy.connectedCountry ?? 'ON') : 'ปิด',
        sub: proxyOn
            ? (s.proxy.connectedHostname ?? '')
            : 'เปลี่ยนประเทศเพื่อปลดล็อกเกม/เว็บ',
        icon3d: M3Icons.vpnProxy,
        tone: proxyOn ? M3Tone.cyan : null,
        onTap: () => shell.goTo(ShellTab.vpn),
      ),
    ];

    return LayoutBuilder(builder: (context, c) {
      const gap = 14.0;
      final tileW = (c.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final t in tiles) SizedBox(width: tileW, child: t),
        ],
      );
    });
  }
}

// ── Members ─────────────────────────────────────────────────────────────

class _MembersCard extends StatelessWidget {
  final AppServices services;
  final VoidCallback onOpen;

  const _MembersCard({required this.services, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final net = services.network.currentNetwork;
    final members = [...services.network.members]
      ..sort((a, b) => (b.isOnline ? 1 : 0).compareTo(a.isOnline ? 1 : 0));

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.members,
            title: net == null ? 'สมาชิกในวง' : net.name,
            subtitle: net == null
                ? null
                : 'ซับเน็ต ${net.virtualSubnet ?? '-'} · ${net.isPublic ? 'วงสาธารณะ' : 'วงส่วนตัว'}',
            trailing: net == null
                ? null
                : GlossButton(
                    label: 'ดูทั้งหมด',
                    size: GlossSize.small,
                    variant: GlossVariant.glass,
                    onPressed: onOpen,
                  ),
          ),
          const SizedBox(height: 12),
          if (net == null)
            M3EmptyState(
              icon3d: M3Icons.networks,
              title: 'ยังไม่ได้เข้าร่วมวง LAN',
              message: 'วงคือกลุ่มเครื่องที่มองเห็นกันเหมือนอยู่ในบ้านเดียวกัน',
              action: GlossButton(
                label: 'ไปหน้าเครือข่าย',
                icon3d: M3Icons.scan,
                onPressed: () =>
                    AppShellScope.of(context).goTo(ShellTab.networks),
              ),
            )
          else if (members.isEmpty)
            const M3EmptyState(
              icon3d: M3Icons.members,
              title: 'กำลังโหลดรายชื่อสมาชิก…',
            )
          else
            for (final m in members.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _MemberRow(
                  member: m,
                  self: m.virtualIp == services.network.ownVirtualIp,
                  path: services.p2p.pathOf(m.virtualIp),
                ),
              ),
          if (members.length > 6)
            Text('และอีก ${members.length - 6} เครื่อง',
                textAlign: TextAlign.center,
                style: M3Text.sub(context).copyWith(color: p.text3)),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final NetworkMember member;
  final bool self;
  final P2pPath? path;

  const _MemberRow({required this.member, required this.self, this.path});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final m = member;
    return M3Row(
      leading: Icon3D(
        m.displayName.toLowerCase().contains('android') ||
                m.displayName.toLowerCase().contains('phone')
            ? M3Icons.devicePhone
            : M3Icons.devicePc,
        size: 38,
        opacity: m.isOnline ? 1 : 0.45,
      ),
      title: m.displayName,
      subtitleWidget: Row(
        children: [
          if (m.virtualIp != null)
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.virtualIp!));
                m3Toast(context, 'คัดลอก ${m.virtualIp} แล้ว',
                    tone: M3Tone.green);
              },
              child: Text(m.virtualIp!, style: M3Text.mono(context, size: 12)),
            ),
          if (m.isVpnGateway) ...[
            const SizedBox(width: 8),
            M3Tag('VPN ${m.vpnGatewayCountry}', tone: M3Tone.gold),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (self)
            const M3Tag('เครื่องนี้', tone: M3Tone.cyan)
          else if (m.isOnline && path != null)
            PeerPathTag(path!),
          const SizedBox(width: 10),
          StatusOrb(
            color: m.isOnline ? p.green : p.text3,
            size: 9,
            pulse: false,
          ),
        ],
      ),
    );
  }
}

// ── Shortcuts ───────────────────────────────────────────────────────────

class _Shortcuts extends StatelessWidget {
  final AppServices services;
  const _Shortcuts({required this.services});

  @override
  Widget build(BuildContext context) {
    final shell = AppShellScope.of(context);
    final items = <(String, String, String, VoidCallback)>[
      ('สร้างวงใหม่', 'ห้อง LAN ส่วนตัว', M3Icons.createNetwork,
          () => shell.goTo(ShellTab.networks)),
      ('ค้นหาวง', 'วงสาธารณะที่เปิดอยู่', M3Icons.scan,
          () => shell.goTo(ShellTab.networks)),
      ('ลดปิงเกม', _boostSub(services.boost), M3Icons.gameBoost,
          () => shell.goTo(ShellTab.boost)),
      ('VPN ประเทศ', 'ปลดล็อกเกม/เว็บต่างประเทศ', M3Icons.vpnProxy,
          () => shell.goTo(ShellTab.vpn)),
      ('ส่งไฟล์', 'ส่งตรงถึงเครื่องในวง', M3Icons.fileTransfer,
          () => shell.goTo(ShellTab.files)),
      ('Torrent', 'คลังไฟล์ของชุมชน', M3Icons.torrent,
          () => shell.goTo(ShellTab.torrent)),
    ];
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(icon3d: M3Icons.smartRoute, title: 'ทางลัด'),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth > 520 ? 3 : 2;
            const gap = 10.0;
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final (title, sub, icon, onTap) in items)
                  SizedBox(
                    width: w,
                    child: _ShortcutTile(
                        title: title, sub: sub, icon: icon, onTap: onTap),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }

  static String _boostSub(GameBoostService b) {
    if (b.isActive) return 'กำลังลดปิงผ่าน ${b.activeRelay?.countryName ?? ''}';
    return 'วัดและเลือกเส้นทางที่เร็วที่สุด';
  }
}

class _ShortcutTile extends StatefulWidget {
  final String title;
  final String sub;
  final String icon;
  final VoidCallback onTap;

  const _ShortcutTile({
    required this.title,
    required this.sub,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_ShortcutTile> createState() => _ShortcutTileState();
}

class _ShortcutTileState extends State<_ShortcutTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.inset,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _hover ? p.cyanSoftLine : p.line),
          ),
          child: Column(
            children: [
              AnimatedScale(
                scale: _hover ? 1.08 : 1,
                duration: const Duration(milliseconds: 160),
                child: Icon3D(widget.icon, size: 56),
              ),
              const SizedBox(height: 6),
              Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: M3Text.h3(context)),
              const SizedBox(height: 2),
              Text(
                widget.sub,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: M3Text.sub(context).copyWith(fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
