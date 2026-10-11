import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/network.dart';
import '../services/sound_service.dart';
import '../widgets/m3/m3.dart';
import 'create_network_screen.dart';
import 'network_detail_screen.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "เครือข่าย LAN" — a game-lobby browser: the network you are in (or a
/// create/join hero), then every public network as a card you can join.
class NetworkListScreen extends StatefulWidget {
  final AppServices services;

  const NetworkListScreen({super.key, required this.services});

  @override
  State<NetworkListScreen> createState() => _NetworkListScreenState();
}

enum _Filter { all, online, public, private }

enum _Sort { online, newest, name }

class _NetworkListScreenState extends State<NetworkListScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.online;

  bool _hasLoaded = false;
  bool _loading = false;
  String? _loadError;

  /// Slug of the network being joined right now (one join at a time).
  String? _joiningSlug;

  /// The running join came from the "join by code" dialog.
  bool _codeJoin = false;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    // Start loading before listening: listNetworks() notifies synchronously.
    _loadNetworks();
    s.network.addListener(_refresh);
    s.vpn.addListener(_refresh);
  }

  @override
  void dispose() {
    s.network.removeListener(_refresh);
    s.vpn.removeListener(_refresh);
    _search.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadNetworks() async {
    if (_loading) return;
    _loading = true;
    if (_hasLoaded && mounted) setState(() {});
    await s.network.listNetworks();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _hasLoaded = true;
      _loadError = s.network.error;
    });
  }

  // ── Filtering ─────────────────────────────────────────────────────────

  List<VpnNetwork> _visible(List<VpnNetwork> all) {
    final q = _query.trim().toLowerCase();
    final kept = <(int, VpnNetwork)>[];
    for (var i = 0; i < all.length; i++) {
      final n = all[i];
      if (q.isNotEmpty &&
          !n.name.toLowerCase().contains(q) &&
          !(n.description?.toLowerCase().contains(q) ?? false) &&
          !n.slug.toLowerCase().contains(q)) {
        continue;
      }
      final keep = switch (_filter) {
        _Filter.all => true,
        _Filter.online => n.onlineCount > 0,
        _Filter.public => n.isPublic,
        _Filter.private => !n.isPublic,
      };
      if (keep) kept.add((i, n));
    }
    // Stable sort: ties keep the server's order (newest first).
    kept.sort((a, b) {
      final (ia, na) = a;
      final (ib, nb) = b;
      final c = switch (_sort) {
        _Sort.online => nb.onlineCount != na.onlineCount
            ? nb.onlineCount.compareTo(na.onlineCount)
            : nb.memberCount.compareTo(na.memberCount),
        _Sort.newest => _newerFirst(na, nb),
        _Sort.name => na.name.toLowerCase().compareTo(nb.name.toLowerCase()),
      };
      return c != 0 ? c : ia.compareTo(ib);
    });
    return [for (final (_, n) in kept) n];
  }

  static int _newerFirst(VpnNetwork a, VpnNetwork b) {
    final ta = a.createdAt;
    final tb = b.createdAt;
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  }

  // ── Navigation ────────────────────────────────────────────────────────

  void _openDetail() {
    final net = s.network.currentNetwork;
    if (net == null) return;
    Navigator.of(context)
        .push(M3PageRoute(
          builder: (_) => NetworkDetailScreen(services: s, network: net),
        ))
        .then((_) {
      if (mounted) _loadNetworks();
    });
  }

  void _openCreate() {
    Navigator.of(context)
        .push(M3PageRoute(builder: (_) => CreateNetworkScreen(services: s)))
        .then((_) {
      if (mounted) _loadNetworks();
    });
  }

  // ── Join ──────────────────────────────────────────────────────────────

  /// Asks before leaving the current network for another one.
  Future<bool> _confirmSwitch(String targetName) async {
    final current = s.network.currentNetwork;
    if (current == null) return true;
    final lan = s.vpn.isConnected;
    return m3Confirm(
      context,
      icon3d: M3Icons.networks,
      title: 'ย้ายไปวง "$targetName"?',
      message: 'ตอนนี้คุณอยู่ในวง "${current.name}"'
          '${lan ? ' และเชื่อมต่อ LAN อยู่ — LAN ของวงเดิมจะถูกตัดเมื่อย้ายสำเร็จ' : ''}'
          '\n\nคุณยังเป็นสมาชิกวงเดิมและกลับเข้าได้ภายหลัง',
      confirmLabel: 'ย้ายวง',
    );
  }

  Future<void> _join(VpnNetwork network) async {
    if (_joiningSlug != null) return;
    if (s.network.currentNetwork?.slug == network.slug) {
      _openDetail();
      return;
    }
    if (!await _confirmSwitch(network.name) || !mounted) return;

    String? password;
    if (!network.isPublic) {
      password = await _askPassword(network.name);
      if (password == null || !mounted) return;
    }
    await _doJoin(network.slug, network.name,
        password: password, askPasswordOnReject: password == null);
  }

  Future<void> _joinByCode() async {
    if (_joiningSlug != null) return;
    SoundService().play(SfxType.notification);
    final result = await showM3Dialog<(String, String?)>(
      context,
      icon3d: M3Icons.invite,
      title: 'เข้าร่วมด้วยรหัสวง',
      message: 'ใส่รหัสวงที่เพื่อนส่งมา (วงส่วนตัวต้องใส่รหัสผ่านด้วย)',
      content: const _JoinCodeForm(),
    );
    if (result == null || !mounted) return;
    final (slug, password) = result;
    if (s.network.currentNetwork?.slug == slug) {
      _openDetail();
      return;
    }
    if (!await _confirmSwitch(slug) || !mounted) return;
    _codeJoin = true;
    try {
      await _doJoin(slug, slug,
          password: password, askPasswordOnReject: password == null);
    } finally {
      _codeJoin = false;
    }
  }

  Future<void> _doJoin(
    String slug,
    String name, {
    String? password,
    required bool askPasswordOnReject,
  }) async {
    final hadLan = s.vpn.isConnected;
    setState(() => _joiningSlug = slug);
    final ok = await s.network.joinNetwork(slug, password: password);
    if (!mounted) return;
    setState(() => _joiningSlug = null);

    if (ok) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();
      if (hadLan && s.vpn.isConnected) {
        // The tunnel still carries the old network's IP — close it.
        await s.vpn.stopVpn();
        if (!mounted) return;
        m3Toast(context, 'ตัด LAN ของวงเดิมแล้ว กด "เชื่อมต่อ LAN" ในวงใหม่ได้เลย',
            tone: M3Tone.amber);
      }
      _openDetail();
      return;
    }

    final raw = s.network.error;
    s.network.clearError();
    // Listed networks can still carry a password: ask once and retry.
    if (askPasswordOnReject &&
        (raw?.toLowerCase().contains('password') ?? false)) {
      final pwd = await _askPassword(name);
      if (pwd == null || !mounted) return;
      await _doJoin(slug, name, password: pwd, askPasswordOnReject: false);
      return;
    }
    SoundService().play(SfxType.error);
    m3Toast(context, _friendlyError(raw, 'ไม่สามารถเข้าร่วมได้'),
        tone: M3Tone.red);
  }

  Future<String?> _askPassword(String networkName) {
    SoundService().play(SfxType.notification);
    return showM3Dialog<String>(
      context,
      icon3d: M3Icons.lock,
      title: 'เครือข่ายส่วนตัว',
      message: 'กรอกรหัสผ่านเพื่อเข้าร่วม "$networkName"',
      content: const _PasswordForm(),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final all = s.network.publicNetworks;
    final visible = _visible(all);
    final online = all.fold<int>(0, (sum, n) => sum + n.onlineCount);

    return M3PageBody(
      onRefresh: _loadNetworks,
      children: [
        M3PageHeader(
          icon3d: M3Icons.networks,
          title: 'เครือข่าย LAN',
          subtitle: _hasLoaded
              ? 'วงสาธารณะ ${all.length} วง · ออนไลน์รวม $online คน'
              : 'ค้นหา เข้าร่วม หรือสร้างวง LAN ของคุณเอง',
          trailing: const ShellBadges(),
        ),
        const SizedBox(height: 16),
        _LobbyHero(
          services: s,
          busy: _joiningSlug != null,
          codeJoining: _codeJoin && _joiningSlug != null,
          onOpen: _openDetail,
          onCreate: _openCreate,
          onJoinCode: _joinByCode,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 16),
        _buildToolbar().animate().fadeIn(delay: 80.ms, duration: 300.ms),
        const SizedBox(height: 18),
        M3SectionTitle(
          'ล็อบบี้วงสาธารณะ',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_hasLoaded) M3Tag('${visible.length} วง', tone: M3Tone.cyan),
              const SizedBox(width: 10),
              if (_loading && _hasLoaded)
                SizedBox(
                  width: 34,
                  height: 34,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.m3.cyan),
                    ),
                  ),
                )
              else
                GlossIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'รีเฟรช',
                  onPressed: _loading ? null : _loadNetworks,
                ),
            ],
          ),
        ),
        _buildLobby(all, visible),
      ],
    );
  }

  Widget _buildToolbar() {
    final field = M3Field(
      controller: _search,
      hint: 'ค้นหาชื่อวง คำอธิบาย หรือรหัสวง…',
      prefixIcon: Icons.search_rounded,
      textInputAction: TextInputAction.search,
      onChanged: (v) => setState(() => _query = v),
      suffix: _query.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'ล้างคำค้นหา',
              onPressed: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
    );

    final filters = <(_Filter, String, IconData?)>[
      (_Filter.all, 'ทั้งหมด', null),
      (_Filter.online, 'มีคนออนไลน์', Icons.sensors_rounded),
      (_Filter.public, 'สาธารณะ', Icons.public_rounded),
      (_Filter.private, 'ส่วนตัว', Icons.lock_rounded),
    ];
    final sorts = <(_Sort, String)>[
      (_Sort.online, 'ออนไลน์มากสุด'),
      (_Sort.newest, 'ใหม่ล่าสุด'),
      (_Sort.name, 'ตามชื่อ'),
    ];

    final filterChips = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (f, label, icon) in filters)
          M3Chip(
            label: label,
            icon: icon,
            selected: _filter == f,
            onTap: () => setState(() => _filter = f),
          ),
      ],
    );
    final sortChips = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(Icons.sort_rounded, size: 18, color: context.m3.text3),
        for (final (o, label) in sorts)
          M3Chip(
            label: label,
            selected: _sort == o,
            onTap: () => setState(() => _sort = o),
          ),
      ],
    );

    return GlassPanel(
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 820;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            const SizedBox(height: 12),
            if (wide)
              Row(
                children: [
                  Expanded(child: filterChips),
                  const SizedBox(width: 16),
                  sortChips,
                ],
              )
            else ...[
              filterChips,
              const SizedBox(height: 10),
              sortChips,
            ],
          ],
        );
      }),
    );
  }

  Widget _buildLobby(List<VpnNetwork> all, List<VpnNetwork> visible) {
    if (!_hasLoaded) {
      return GlassPanel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Column(
            children: [
              CircularProgressIndicator(color: context.m3.cyan),
              const SizedBox(height: 14),
              Text('กำลังโหลดรายการวง…', style: M3Text.sub(context)),
            ],
          ),
        ),
      );
    }

    if (all.isEmpty && _loadError != null) {
      return GlassPanel(
        accent: context.m3.red,
        child: M3EmptyState(
          icon3d: M3Icons.networks,
          title: 'โหลดรายการวงไม่สำเร็จ',
          message: _friendlyError(_loadError, 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้'),
          action: GlossButton(
            label: 'ลองอีกครั้ง',
            icon: Icons.refresh_rounded,
            loading: _loading,
            onPressed: _loading ? null : _loadNetworks,
          ),
        ),
      );
    }

    if (visible.isEmpty) {
      final searching = _query.trim().isNotEmpty || _filter != _Filter.all;
      return GlassPanel(
        child: M3EmptyState(
          icon3d: searching ? M3Icons.scan : M3Icons.createNetwork,
          title: searching ? 'ไม่พบวงที่ค้นหา' : 'ยังไม่มีวงสาธารณะ',
          message: searching
              ? 'ลองคำค้นหาหรือตัวกรองอื่น หรือสร้างวงใหม่ของคุณเอง'
              : 'สร้างวงใหม่ หรือใส่รหัสวงที่เพื่อนส่งมา',
          action: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              if (searching)
                GlossButton(
                  label: 'ล้างตัวกรอง',
                  variant: GlossVariant.glass,
                  icon: Icons.filter_alt_off_rounded,
                  onPressed: () {
                    _search.clear();
                    setState(() {
                      _query = '';
                      _filter = _Filter.all;
                    });
                  },
                ),
              GlossButton(
                label: 'สร้างเครือข่าย',
                icon3d: M3Icons.createNetwork,
                onPressed: _joiningSlug != null ? null : _openCreate,
              ),
            ],
          ),
        ),
      );
    }

    final currentSlug = s.network.currentNetwork?.slug;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 1000
          ? 3
          : c.maxWidth >= 640
              ? 2
              : 1;
      const gap = 14.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (var i = 0; i < visible.length; i++)
            SizedBox(
              key: ValueKey(visible[i].slug),
              width: w,
              child: _LobbyCard(
                network: visible[i],
                isCurrent: visible[i].slug == currentSlug,
                joining: _joiningSlug == visible[i].slug,
                disabled: _joiningSlug != null &&
                    _joiningSlug != visible[i].slug,
                onJoin: () => _join(visible[i]),
                onOpen: _openDetail,
              )
                  .animate()
                  .fadeIn(delay: ((i < 8 ? i : 8) * 40).ms, duration: 300.ms)
                  .slideY(begin: 0.05, end: 0),
            ),
        ],
      );
    });
  }
}

/// Server errors arrive in English; show them in friendly Thai.
String _friendlyError(String? raw, String fallback) {
  if (raw == null || raw.trim().isEmpty) return fallback;
  final e = raw.toLowerCase();
  if (e.contains('password')) return 'รหัสผ่านไม่ถูกต้อง';
  if (e.contains('limited to 5')) {
    return 'วงนี้ครบ 5 คนแล้ว (เจ้าของวงใช้แบบฟรี)';
  }
  if (e.contains('full')) return 'วงนี้เต็มแล้ว';
  if (e.contains('not found') || e.contains('inactive')) {
    return 'ไม่พบวงนี้ หรือวงถูกปิดไปแล้ว — ตรวจสอบรหัสวงอีกครั้ง';
  }
  if (e.contains('license') || e.contains('device')) {
    return 'ตรวจสอบไลเซนส์หรืออุปกรณ์ไม่ผ่าน ลองเปิดแอปใหม่อีกครั้ง';
  }
  // Messages written by the service are already Thai.
  if (RegExp(r'[฀-๿]').hasMatch(raw)) return raw;
  return fallback;
}

// ── Hero ────────────────────────────────────────────────────────────────

class _LobbyHero extends StatelessWidget {
  final AppServices services;
  final bool busy;
  final bool codeJoining;
  final VoidCallback onOpen;
  final VoidCallback onCreate;
  final VoidCallback onJoinCode;

  const _LobbyHero({
    required this.services,
    required this.busy,
    required this.codeJoining,
    required this.onOpen,
    required this.onCreate,
    required this.onJoinCode,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final s = services;
    final net = s.network.currentNetwork;
    final connected = net != null && s.vpn.isConnected;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final members = s.network.members;
    final total = members.isEmpty ? (net?.memberCount ?? 0) : members.length;
    final online = members.isEmpty
        ? (net?.onlineCount ?? 0)
        : members.where((m) => m.isOnline).length;

    final orb = Icon3D(
      net == null
          ? M3Icons.createNetwork
          : (connected ? M3Icons.p2pDirect : M3Icons.networks),
      size: narrow ? 84 : 124,
      glow: connected ? p.green.withValues(alpha: 0.45) : p.logoGlow,
    );

    final title = net?.name ?? 'ยังไม่ได้อยู่ในวงไหน';
    final detail = net == null
        ? 'สร้างวงของคุณเอง เลือกวงสาธารณะด้านล่าง หรือใส่รหัสวงที่เพื่อนส่งมา '
            'แล้วเล่นเกม LAN และแชร์ไฟล์เหมือนอยู่บ้านเดียวกัน'
        : connected
            ? 'เชื่อมต่อ LAN แล้ว — เครื่องในวงมองเห็นกันเหมือนเสียบสาย LAN เดียวกัน'
            : 'คุณอยู่ในวงนี้ เปิดหน้าวงแล้วกด "เชื่อมต่อ LAN" เพื่อเริ่มเล่น';

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(net == null ? 'VIRTUAL LAN LOBBY' : 'YOUR NETWORK',
            style: M3Text.eyebrow(context)),
        const SizedBox(height: 4),
        Row(
          children: [
            if (net != null) ...[
              StatusOrb(
                color: connected ? p.green : p.amber,
                size: 11,
                pulse: connected,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: M3Fonts.head,
                  fontSize: narrow ? 22 : 29,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: connected ? p.green : p.text,
                  shadows: p.titleShadow,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(detail, style: M3Text.sub(context).copyWith(fontSize: 13.5)),
        if (net != null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: narrow ? 18 : 30,
            runSpacing: 10,
            children: [
              _HeroMetric(
                label: 'Virtual IP',
                value: s.vpn.virtualIp ?? s.network.ownVirtualIp ?? '—',
                mono: true,
              ),
              _HeroMetric(label: 'ออนไลน์', value: '$online/$total'),
              _HeroMetric(
                label: 'ซับเน็ต',
                value: net.virtualSubnet ?? '—',
                mono: true,
              ),
            ],
          ),
        ],
      ],
    );

    final buttons = Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
      children: [
        if (net != null) ...[
          GlossButton(
            label: 'เปิดหน้าวง',
            icon: Icons.arrow_forward_rounded,
            size: GlossSize.large,
            onPressed: onOpen,
          ),
          GlossButton(
            label: 'สร้างวงใหม่',
            icon3d: M3Icons.createNetwork,
            variant: GlossVariant.glass,
            onPressed: busy ? null : onCreate,
          ),
        ] else
          GlossButton(
            label: 'สร้างวงใหม่',
            icon3d: M3Icons.createNetwork,
            size: GlossSize.large,
            onPressed: busy ? null : onCreate,
          ),
        GlossButton(
          label: 'เข้าร่วมด้วยรหัสวง',
          icon3d: M3Icons.invite,
          variant: GlossVariant.glass,
          size: net == null ? GlossSize.large : GlossSize.medium,
          loading: codeJoining,
          onPressed: busy ? null : onJoinCode,
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
                SizedBox(width: 250, child: buttons),
              ],
            ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _HeroMetric({
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: mono
              ? M3Text.mono(context,
                  size: narrow ? 15 : 18,
                  weight: FontWeight.w700,
                  color: context.m3.numText)
              : M3Text.num(context, size: narrow ? 19 : 23),
        ),
        Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
      ],
    );
  }
}

// ── Lobby card ──────────────────────────────────────────────────────────

class _LobbyCard extends StatelessWidget {
  final VpnNetwork network;
  final bool isCurrent;
  final bool joining;
  final bool disabled;
  final VoidCallback onJoin;
  final VoidCallback onOpen;

  const _LobbyCard({
    required this.network,
    required this.isCurrent,
    required this.joining,
    required this.disabled,
    required this.onJoin,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final n = network;
    final desc = n.description?.trim() ?? '';
    final action = isCurrent ? onOpen : onJoin;

    return GlassPanel(
      onTap: disabled || joining ? null : action,
      accent: isCurrent ? p.green : null,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon3D(n.isPublic ? M3Icons.networks : M3Icons.lock, size: 58),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: M3Text.h2(context).copyWith(
                          fontSize: 16.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        M3Tag(
                          n.isPublic ? 'สาธารณะ' : 'ส่วนตัว',
                          tone: n.isPublic ? M3Tone.cyan : M3Tone.gold,
                          icon: n.isPublic
                              ? Icons.public_rounded
                              : Icons.lock_rounded,
                        ),
                        if (isCurrent)
                          const M3Tag('อยู่ในวงนี้',
                              tone: M3Tone.green, dot: true),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: Text(
              desc.isEmpty ? 'ไม่มีคำอธิบาย' : desc,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: M3Text.sub(context)
                  .copyWith(color: desc.isEmpty ? p.text3 : p.text2),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: M3Inset(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  radius: 12,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _CardMetric(
                            value: '${n.memberCount}', label: 'สมาชิก'),
                        const SizedBox(width: 16),
                        _CardMetric(
                          value: '${n.onlineCount}',
                          label: 'ออนไลน์',
                          orb: n.onlineCount > 0 ? p.green : p.text3,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GlossButton(
                label: isCurrent ? 'เปิด' : 'เข้าร่วม',
                size: GlossSize.small,
                variant: isCurrent ? GlossVariant.glass : GlossVariant.aqua,
                icon: isCurrent
                    ? Icons.arrow_forward_rounded
                    : (n.isPublic
                        ? Icons.login_rounded
                        : Icons.lock_open_rounded),
                loading: joining,
                onPressed: disabled || joining ? null : action,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color? orb;

  const _CardMetric({required this.value, required this.label, this.orb});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (orb != null) ...[
          StatusOrb(color: orb!, size: 8, pulse: false),
          const SizedBox(width: 6),
        ],
        Text(value, style: M3Text.num(context, size: 19)),
        const SizedBox(width: 5),
        Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
      ],
    );
  }
}

// ── Dialog bodies (own their controllers, so nothing is disposed while
//    the dialog is still animating out) ──────────────────────────────────

class _PasswordForm extends StatefulWidget {
  const _PasswordForm();

  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      SoundService().play(SfxType.error);
      return;
    }
    SoundService().play(SfxType.tapHeavy);
    Navigator.of(context).pop(_ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3Field(
            controller: _ctrl,
            label: 'รหัสผ่าน',
            hint: 'กรอกรหัสผ่าน',
            obscure: _obscure,
            prefixIcon: Icons.key_rounded,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'กรุณากรอกรหัสผ่าน' : null,
            suffix: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                size: 18,
              ),
              tooltip: _obscure ? 'แสดงรหัสผ่าน' : 'ซ่อนรหัสผ่าน',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 10,
            children: [
              GlossButton(
                label: 'ยกเลิก',
                variant: GlossVariant.glass,
                onPressed: () => Navigator.of(context).pop(),
              ),
              GlossButton(
                label: 'เข้าร่วม',
                icon: Icons.login_rounded,
                onPressed: _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _JoinCodeForm extends StatefulWidget {
  const _JoinCodeForm();

  @override
  State<_JoinCodeForm> createState() => _JoinCodeFormState();
}

class _JoinCodeFormState extends State<_JoinCodeForm> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Accepts a bare code or the whole invite text copied from a friend.
  static String _extractCode(String input) {
    var t = input.trim();
    const marker = 'รหัสวง:';
    final at = t.indexOf(marker);
    if (at >= 0) t = t.substring(at + marker.length).trim();
    final parts = t.split(RegExp(r'\s+'));
    return parts.isEmpty ? '' : parts.first.trim();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      SoundService().play(SfxType.error);
      return;
    }
    SoundService().play(SfxType.tapHeavy);
    final pwd = _password.text.trim();
    Navigator.of(context)
        .pop<(String, String?)>((_extractCode(_code.text), pwd.isEmpty ? null : pwd));
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3Field(
            controller: _code,
            label: 'รหัสวง',
            hint: 'เช่น friday-gamers',
            prefixIcon: Icons.tag_rounded,
            mono: true,
            autofocus: true,
            textInputAction: TextInputAction.next,
            validator: (v) {
              final code = _extractCode(v ?? '');
              if (code.isEmpty) return 'กรุณากรอกรหัสวง';
              if (code.length > 120) return 'รหัสวงยาวเกินไป';
              return null;
            },
          ),
          const SizedBox(height: 12),
          M3Field(
            controller: _password,
            label: 'รหัสผ่าน (ถ้ามี)',
            hint: 'เว้นว่างได้ถ้าเป็นวงสาธารณะ',
            obscure: _obscure,
            prefixIcon: Icons.key_rounded,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            suffix: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                size: 18,
              ),
              tooltip: _obscure ? 'แสดงรหัสผ่าน' : 'ซ่อนรหัสผ่าน',
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 10,
            children: [
              GlossButton(
                label: 'ยกเลิก',
                variant: GlossVariant.glass,
                onPressed: () => Navigator.of(context).pop(),
              ),
              GlossButton(
                label: 'เข้าร่วม',
                icon: Icons.login_rounded,
                onPressed: _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
