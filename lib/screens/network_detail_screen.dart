import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/member.dart';
import '../models/network.dart';
import '../platform/platform_info.dart';
import '../services/net/latency_probe.dart';
import '../services/sound_service.dart';
import '../services/vpn_proxy_service.dart';
import '../widgets/m3/m3.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// One network: connect/disconnect the virtual LAN, members with their P2P
/// state and ping, the VPN gateway shared in the network, network info and
/// leave/delete.
class NetworkDetailScreen extends StatefulWidget {
  final AppServices services;
  final VpnNetwork network;

  const NetworkDetailScreen({
    super.key,
    required this.services,
    required this.network,
  });

  @override
  State<NetworkDetailScreen> createState() => _NetworkDetailScreenState();
}

enum _Busy { none, leave, delete, follow }

class _NetworkDetailScreenState extends State<NetworkDetailScreen> {
  Timer? _refreshTimer;
  int _previousMemberCount = 0;
  bool _membersLoaded = false;
  bool _refreshingMembers = false;
  _Busy _busy = _Busy.none;

  bool _pinging = false;

  /// Virtual IP → median ping in ms (null = no reply) from the last run.
  final Map<String, double?> _ping = {};
  DateTime? _pingAt;

  AppServices get s => widget.services;

  /// False once the user left, deleted or switched to another network
  /// while this page is still open.
  bool get _isCurrent =>
      s.network.currentNetwork?.slug == widget.network.slug;

  VpnNetwork get _net =>
      _isCurrent ? s.network.currentNetwork! : widget.network;

  bool get _isCreator {
    final createdBy = _net.createdBy;
    final deviceId = s.network.deviceId;
    return createdBy != null && deviceId != null && createdBy == deviceId;
  }

  @override
  void initState() {
    super.initState();
    _previousMemberCount = s.network.members.length;
    _membersLoaded = _isCurrent && s.network.members.isNotEmpty;
    _loadMembers();
    s.network.addListener(_onNetworkChanged);
    s.vpn.addListener(_refresh);
    s.p2p.addListener(_refresh);
    s.proxy.addListener(_refresh);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _loadMembers(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    s.network.removeListener(_onNetworkChanged);
    s.vpn.removeListener(_refresh);
    s.p2p.removeListener(_refresh);
    s.proxy.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onNetworkChanged() {
    if (!mounted) return;
    // Chime when a new member joins.
    final count = s.network.members.length;
    if (_isCurrent && count > _previousMemberCount && _previousMemberCount > 0) {
      SoundService().play(SfxType.notification);
    }
    _previousMemberCount = count;
    setState(() {});
  }

  Future<void> _loadMembers() async {
    // getMembers() replaces the shared member list — never load another
    // network's members over the current one.
    if (!_isCurrent) return;
    await s.network.getMembers(widget.network.slug);
    if (mounted && !_membersLoaded) setState(() => _membersLoaded = true);
  }

  Future<void> _manualRefresh() async {
    if (_refreshingMembers) return;
    setState(() => _refreshingMembers = true);
    await _loadMembers();
    if (!mounted) return;
    setState(() => _refreshingMembers = false);
  }

  // ── LAN ───────────────────────────────────────────────────────────────

  Future<void> _toggleLan() async {
    if (!_isCurrent) return;
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
      m3Toast(context,
          'ยังไม่ได้รับ Virtual IP จากเซิร์ฟเวอร์ ลองอีกครั้งในไม่กี่วินาที',
          tone: M3Tone.amber);
      return;
    }
    final ok = await s.vpn.startVpn(
      virtualIp: vip,
      subnet: _net.virtualSubnet ?? '10.10.0.0/24',
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

  // ── Ping ──────────────────────────────────────────────────────────────

  Future<void> _pingAll() async {
    if (_pinging || !_isCurrent || !s.vpn.isConnected) return;
    final own = s.network.ownVirtualIp;
    final me = s.network.deviceId;
    final targets = s.network.members
        .where((m) =>
            m.isOnline &&
            m.virtualIp != null &&
            m.virtualIp != own &&
            (me == null || m.machineId != me))
        .map((m) => m.virtualIp!)
        .toSet()
        .toList();
    if (targets.isEmpty) {
      m3Toast(context, 'ยังไม่มีเครื่องอื่นออนไลน์ให้วัดปิง', tone: M3Tone.amber);
      return;
    }

    final slug = widget.network.slug;
    setState(() => _pinging = true);
    Future<MapEntry<String, double?>> probe(String ip) async {
      try {
        final r = await LatencyProbe.icmp(ip, count: 3, timeoutMs: 1000);
        return MapEntry<String, double?>(ip, r.medianMs);
      } catch (_) {
        return MapEntry<String, double?>(ip, null);
      }
    }

    // A few at a time — a 50-member network must not spawn 50 pings at once.
    final results = <MapEntry<String, double?>>[];
    for (var i = 0; i < targets.length; i += 8) {
      final end = i + 8 < targets.length ? i + 8 : targets.length;
      results.addAll(await Future.wait(targets.sublist(i, end).map(probe)));
      if (!mounted) return;
    }
    if (!mounted) return;
    // Drop the results if the network changed while we were measuring.
    final stillHere = s.network.currentNetwork?.slug == slug;
    setState(() {
      _pinging = false;
      if (stillHere) {
        _ping
          ..clear()
          ..addEntries(results);
        _pingAt = DateTime.now();
      }
    });
    if (stillHere && results.every((e) => e.value == null)) {
      m3Toast(
        context,
        'ไม่มีเครื่องไหนตอบกลับ — เครื่องปลายทางอาจปิดการตอบ ping ในไฟร์วอลล์',
        tone: M3Tone.amber,
      );
    }
  }

  // ── Leave / delete ────────────────────────────────────────────────────

  Future<void> _leave() async {
    if (_busy != _Busy.none || !_isCurrent) return;
    SoundService().play(SfxType.notification);

    // The creator cannot leave a network that still has members.
    final others = s.network.members
        .where((m) => m.machineId != s.network.deviceId)
        .length;
    if (_isCreator && others > 0) {
      final delete = await showM3Dialog<bool>(
        context,
        icon3d: M3Icons.crown,
        title: 'คุณเป็นผู้สร้างเครือข่าย',
        message: 'เครือข่าย "${_net.name}" ยังมีสมาชิกอยู่ $others คน\n\n'
            'หากต้องการออก ให้ "ลบเครือข่าย" แทน ซึ่งจะเตะสมาชิกทุกคนออก\n\n'
            'หรือรอให้สมาชิกทุกคนออกก่อนแล้วค่อยออก',
        actions: (ctx) => [
          GlossButton(
            label: 'เข้าใจแล้ว',
            variant: GlossVariant.glass,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          GlossButton(
            label: 'ลบเครือข่าย',
            icon: Icons.delete_forever_rounded,
            variant: GlossVariant.red,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      );
      if (delete == true && mounted) await _delete();
      return;
    }

    final lan = _isCurrent && s.vpn.isConnected;
    final ok = await m3Confirm(
      context,
      icon3d: M3Icons.networks,
      title: 'ออกจากเครือข่าย',
      message: 'ต้องการออกจาก "${_net.name}" ใช่หรือไม่?'
          '${lan ? '\n\nLAN เสมือนจะถูกตัดการเชื่อมต่อด้วย' : ''}',
      confirmLabel: 'ออก',
      destructive: true,
    );
    if (!ok || !mounted) return;

    SoundService().play(SfxType.disconnect);
    setState(() => _busy = _Busy.leave);
    final success = await s.network.leaveNetwork(widget.network.slug);
    // The tunnel carries this network's IP — close it once we're out.
    if (success && lan && s.vpn.isConnected) await s.vpn.stopVpn();
    if (!mounted) return;
    setState(() => _busy = _Busy.none);

    if (success) {
      SoundService().play(SfxType.success);
      m3Toast(context, 'ออกจาก "${_net.name}" แล้ว', tone: M3Tone.green);
      Navigator.of(context).pop();
    } else {
      SoundService().play(SfxType.error);
      m3Toast(
        context,
        s.network.error ?? 'ไม่สามารถออกจากเครือข่ายได้ กรุณาลองใหม่',
        tone: M3Tone.red,
        duration: const Duration(seconds: 4),
      );
      s.network.clearError();
    }
  }

  Future<void> _delete() async {
    if (_busy != _Busy.none || !_isCurrent) return;
    SoundService().play(SfxType.notification);
    final lan = _isCurrent && s.vpn.isConnected;
    final ok = await m3Confirm(
      context,
      icon3d: M3Icons.networks,
      title: 'ลบเครือข่าย',
      message: 'ต้องการลบ "${_net.name}" ใช่หรือไม่? '
          'สมาชิกทุกคนจะถูกนำออก การกระทำนี้ไม่สามารถยกเลิกได้'
          '${lan ? '\n\nLAN เสมือนจะถูกตัดการเชื่อมต่อด้วย' : ''}',
      confirmLabel: 'ลบ',
      destructive: true,
    );
    if (!ok || !mounted) return;

    SoundService().play(SfxType.disconnect);
    setState(() => _busy = _Busy.delete);
    final name = _net.name;
    final success = await s.network.deleteNetwork(widget.network.slug);
    if (success && lan && s.vpn.isConnected) await s.vpn.stopVpn();
    if (!mounted) return;
    setState(() => _busy = _Busy.none);

    if (success) {
      m3Toast(context, 'ลบเครือข่าย "$name" แล้ว', tone: M3Tone.green);
      Navigator.of(context).pop();
    } else {
      SoundService().play(SfxType.error);
      m3Toast(
        context,
        '${s.network.error ?? 'ไม่สามารถลบเครือข่ายได้'} '
        '(ลบได้เฉพาะผู้สร้างเครือข่าย)',
        tone: M3Tone.red,
        duration: const Duration(seconds: 4),
      );
      s.network.clearError();
    }
  }

  // ── VPN gateway ───────────────────────────────────────────────────────

  Future<void> _followGateway(NetworkMember gateway) async {
    if (_busy != _Busy.none || !gateway.isVpnGateway) return;
    final proxy = s.proxy;
    if (s.boost.usesTunnel) {
      m3Toast(context,
          'กำลังใช้ระบบลดปิงเกมอยู่ — หยุดลดปิงก่อน แล้วค่อยเชื่อมต่อ VPN ตาม Gateway',
          tone: M3Tone.amber);
      return;
    }

    SoundService().play(SfxType.notification);
    final cc = gateway.vpnGatewayCountry?.toUpperCase() ?? '';
    final ok = await m3Confirm(
      context,
      icon3d: M3Icons.vpnProxy,
      title: 'เชื่อมต่อ VPN Gateway',
      message: 'เชื่อมต่อ VPN ไปยัง $cc ตาม ${gateway.displayName}\n\n'
          '${isAndroid ? 'Android อนุญาต VPN ได้ครั้งละ 1 tunnel เท่านั้น '
              'การเชื่อมต่อ LAN จะถูกหยุดชั่วคราว' : 'อินเทอร์เน็ตของเครื่องนี้จะออกผ่านประเทศเดียวกับ Gateway'}',
      confirmLabel: 'เชื่อมต่อ',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = _Busy.follow);
    bool? started;
    // Ensure the server list is loaded.
    if (proxy.countries.isEmpty) await proxy.fetchServers();
    // Same server by hostname first …
    final host = gateway.vpnGatewayHostname;
    if (host != null) {
      final server = proxy.findServerByHostname(host);
      if (server != null) started = await proxy.connect(server);
    }
    // … then any server in the same country.
    if (started == null && gateway.vpnGatewayCountry != null) {
      final country = proxy.findCountryByCode(gateway.vpnGatewayCountry!);
      if (country != null) started = await proxy.connectToCountry(country);
    }
    if (!mounted) return;
    setState(() => _busy = _Busy.none);

    if (started == null) {
      m3Toast(context, 'ไม่พบ VPN server สำหรับ gateway นี้',
          tone: M3Tone.amber);
    } else if (started) {
      m3Toast(context, 'กำลังเชื่อมต่อ VPN ไป $cc ตาม ${gateway.displayName}',
          tone: M3Tone.cyan);
    } else {
      m3Toast(context,
          'เชื่อมต่อ VPN ไม่สำเร็จ — ลองอีกครั้ง หรือเลือกประเทศเองที่หน้า VPN ประเทศ',
          tone: M3Tone.red);
    }
  }

  // ── Copy helpers ──────────────────────────────────────────────────────

  void _copy(String text, [String? what]) {
    Clipboard.setData(ClipboardData(text: text));
    m3Toast(context, 'คัดลอก ${what ?? text} แล้ว', tone: M3Tone.green);
  }

  void _copyInvite() {
    final n = _net;
    final text = 'มาเล่น LAN ด้วยกันใน LocalVPN!\n'
        'วง: ${n.name}\n'
        'รหัสวง: ${n.slug}'
        '${n.isPublic ? '' : '\n(วงส่วนตัว — ขอรหัสผ่านจากเจ้าของวง)'}';
    Clipboard.setData(ClipboardData(text: text));
    SoundService().play(SfxType.coin);
    m3Toast(context,
        'คัดลอกข้อความชวนแล้ว — ส่งให้เพื่อน แล้วให้กด "เข้าร่วมด้วยรหัสวง"',
        tone: M3Tone.green);
  }

  // ── Build ─────────────────────────────────────────────────────────────

  List<NetworkMember> _sortedMembers() {
    return [...s.network.members]..sort((a, b) {
        final sa = _isSelf(a);
        final sb = _isSelf(b);
        if (sa != sb) return sa ? -1 : 1;
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });
  }

  bool _isSelf(NetworkMember m) {
    final me = s.network.deviceId;
    final own = s.network.ownVirtualIp;
    return (me != null && m.machineId == me) ||
        (own != null && m.virtualIp == own);
  }

  @override
  Widget build(BuildContext context) {
    final net = _net;
    final isCurrent = _isCurrent;
    final members = isCurrent ? _sortedMembers() : const <NetworkMember>[];
    final desc = net.description?.trim() ?? '';

    return M3PageBody(
      onRefresh: _loadMembers,
      children: [
        M3PageHeader(
          icon3d: M3Icons.networks,
          title: net.name,
          subtitle: desc.isNotEmpty
              ? desc
              : '${net.isPublic ? 'วงสาธารณะ' : 'วงส่วนตัว'}'
                  '${net.virtualSubnet == null ? '' : ' · ซับเน็ต ${net.virtualSubnet}'}',
          onBack: () => Navigator.of(context).pop(),
          trailing: GlossIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'รีเฟรชรายชื่อสมาชิก',
            onPressed:
                isCurrent && !_refreshingMembers ? _manualRefresh : null,
          ),
        ),
        const SizedBox(height: 16),
        if (!isCurrent) ...[
          M3Banner(
            tone: M3Tone.amber,
            icon3d: M3Icons.networks,
            title: 'คุณไม่ได้อยู่ในวงนี้แล้ว',
            message: 'อาจออกจากวง วงถูกลบ หรือย้ายไปวงอื่น — '
                'เข้าร่วมใหม่ได้จากหน้าเครือข่าย',
            action: GlossButton(
              label: 'กลับ',
              size: GlossSize.small,
              variant: GlossVariant.glass,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(height: 14),
        ],
        _DetailHero(
          services: s,
          network: net,
          isCurrent: isCurrent,
          isCreator: _isCreator,
          onToggle: _toggleLan,
          onInvite: _copyInvite,
          onCopy: _copy,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 880;
          final membersCard = _buildMembers(members, isCurrent,
              compact: c.maxWidth < 420);
          final gateway = isCurrent ? _buildGateway() : null;
          final side = <Widget>[
            _buildInfo(net, members, isCurrent),
            ?gateway,
            _buildManage(),
          ];
          final sideColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < side.length; i++) ...[
                if (i > 0) const SizedBox(height: 16),
                side[i],
              ],
            ],
          );
          final body = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: membersCard),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: sideColumn),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    membersCard,
                    const SizedBox(height: 16),
                    sideColumn,
                  ],
                );
          return body.animate().fadeIn(delay: 80.ms, duration: 350.ms);
        }),
      ],
    );
  }

  Widget _buildMembers(List<NetworkMember> members, bool isCurrent,
      {required bool compact}) {
    final p = context.m3;
    final connected = isCurrent && s.vpn.isConnected;
    final online = members.where((m) => m.isOnline).length;
    final peers = s.p2p.peers;
    final pingAt = _pingAt;

    String? subtitle;
    if (isCurrent && members.isNotEmpty) {
      subtitle = 'ออนไลน์ $online จาก ${members.length} เครื่อง';
      if (connected && pingAt != null) {
        subtitle += ' · วัดปิงเมื่อ '
            '${pingAt.hour.toString().padLeft(2, '0')}:'
            '${pingAt.minute.toString().padLeft(2, '0')}';
      }
    }

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.members,
            title: 'สมาชิก',
            subtitle: subtitle,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (members.isNotEmpty) ...[
                  M3Count(members.length),
                  const SizedBox(width: 10),
                ],
                GlossButton(
                  label: 'วัดปิง',
                  icon: Icons.speed_rounded,
                  size: GlossSize.small,
                  variant: GlossVariant.glass,
                  loading: _pinging,
                  tooltip: connected ? null : 'เชื่อมต่อ LAN ก่อนจึงจะวัดปิงได้',
                  onPressed: connected && !_pinging ? _pingAll : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (!isCurrent)
            const M3EmptyState(
              icon3d: M3Icons.networks,
              title: 'ไม่ได้อยู่ในวงนี้',
              message: 'เข้าร่วมวงอีกครั้งเพื่อดูรายชื่อสมาชิก',
            )
          else if (members.isEmpty && !_membersLoaded)
            const M3EmptyState(
              icon3d: M3Icons.members,
              title: 'กำลังโหลดรายชื่อสมาชิก…',
            )
          else if (members.isEmpty)
            const M3EmptyState(
              icon3d: M3Icons.invite,
              title: 'ยังไม่มีสมาชิก',
              message: 'แชร์รหัสวงเพื่อเชิญเพื่อน',
            )
          else
            for (var i = 0; i < members.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _MemberRow(
                  member: members[i],
                  self: _isSelf(members[i]),
                  direct: peers[members[i].virtualIp]?.isDirectConnected,
                  showPing: connected &&
                      members[i].virtualIp != null &&
                      _ping.containsKey(members[i].virtualIp),
                  pingMs: _ping[members[i].virtualIp],
                  compact: compact,
                  onCopy: _copy,
                )
                    .animate()
                    .fadeIn(delay: ((i < 8 ? i : 8) * 45).ms, duration: 280.ms)
                    .slideX(begin: 0.03, end: 0),
              ),
          if (isCurrent && members.isNotEmpty && !connected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'เชื่อมต่อ LAN เพื่อเชื่อมตรงแบบ P2P และวัดปิงถึงเครื่องเพื่อน',
                textAlign: TextAlign.center,
                style: M3Text.sub(context).copyWith(color: p.text3),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfo(
      VpnNetwork net, List<NetworkMember> members, bool isCurrent) {
    final vip =
        isCurrent ? (s.vpn.virtualIp ?? s.network.ownVirtualIp) : null;
    final pub = isCurrent && s.p2p.publicIp != null
        ? '${s.p2p.publicIp}:${s.p2p.publicPort ?? '-'}'
        : null;
    final total = members.isNotEmpty ? members.length : net.memberCount;
    final created = net.createdAt;
    const noCopy = SizedBox(width: 26);

    Widget copyBtn(String text, String what) => GlossIconButton(
          icon: Icons.copy_rounded,
          size: 26,
          tooltip: 'คัดลอก',
          onPressed: () => _copy(text, what),
        );

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(icon3d: M3Icons.adapter, title: 'ข้อมูลเครือข่าย'),
          const SizedBox(height: 10),
          M3KeyValue('รหัสวง', net.slug,
              mono: true, trailing: copyBtn(net.slug, 'รหัสวง')),
          M3KeyValue(
            'ประเภท',
            net.isPublic ? 'สาธารณะ' : 'ส่วนตัว (ต้องใช้รหัสผ่าน)',
            trailing: noCopy,
          ),
          M3KeyValue('ซับเน็ต', net.virtualSubnet ?? '—',
              mono: true, trailing: noCopy),
          M3KeyValue('Virtual IP ของคุณ', vip ?? '—',
              mono: true,
              trailing: vip == null ? noCopy : copyBtn(vip, 'Virtual IP')),
          M3KeyValue('ปลายทาง P2P สาธารณะ', pub ?? '—',
              mono: true,
              trailing: pub == null ? noCopy : copyBtn(pub, 'ปลายทาง P2P')),
          M3KeyValue(
            'การ์ดเครือข่ายเสมือน',
            isCurrent && s.vpn.isConnected ? 'ทำงาน' : 'ปิดอยู่',
            trailing: noCopy,
          ),
          M3KeyValue('สมาชิกทั้งหมด', '$total เครื่อง', trailing: noCopy),
          if (created != null)
            M3KeyValue('สร้างเมื่อ', _thaiDate(created), trailing: noCopy),
          const SizedBox(height: 10),
          GlossButton(
            label: 'คัดลอกข้อความชวนเพื่อน',
            icon3d: M3Icons.invite,
            variant: GlossVariant.glass,
            expand: true,
            onPressed: _copyInvite,
          ),
        ],
      ),
    );
  }

  Widget? _buildGateway() {
    if (!s.network.hasVpnGateway) return null;
    final gateway = s.network.vpnGatewayMember;
    if (gateway == null) return null;

    final p = context.m3;
    final isSelf = s.network.isSelfGateway &&
        gateway.machineId == s.network.deviceId;
    final cc = gateway.vpnGatewayCountry?.toUpperCase() ?? '';
    final proxy = s.proxy;
    final connecting = proxy.status == VpnProxyStatus.connecting;
    final following = !isSelf &&
        proxy.status == VpnProxyStatus.connected &&
        !s.boost.usesTunnel &&
        proxy.connectedCountry?.toUpperCase() == cc;
    // Windows has no flag emoji glyphs — show the country code there.
    final flag = isWindows || gateway.vpnGatewayFlag.isEmpty
        ? cc
        : gateway.vpnGatewayFlag;

    return GlassPanel(
      accent: p.gold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.vpnProxy,
            title: isSelf ? 'คุณเป็น VPN Gateway' : 'VPN Gateway',
            subtitle: isSelf
                ? 'สมาชิกสามารถเชื่อมต่อ VPN ตามคุณได้'
                : '${gateway.displayName} · $cc',
          ),
          const SizedBox(height: 12),
          M3Inset(
            child: Row(
              children: [
                Text(
                  flag,
                  style: TextStyle(
                    fontFamily: M3Fonts.head,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: p.gold,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isSelf
                        ? 'เครื่องนี้กำลังแชร์ VPN ประเทศ $cc ให้เพื่อนในวง'
                        : 'ใช้ VPN ออกประเทศเดียวกับ ${gateway.displayName} '
                            '— เหมาะกับการเข้าเซิร์ฟเกมเดียวกัน',
                    style: M3Text.sub(context).copyWith(color: p.text2),
                  ),
                ),
              ],
            ),
          ),
          if (!isSelf) ...[
            const SizedBox(height: 12),
            if (following)
              const Align(
                alignment: Alignment.centerLeft,
                child: M3Tag('เชื่อมต่อ VPN ตาม Gateway แล้ว',
                    tone: M3Tone.green, dot: true),
              )
            else
              GlossButton(
                label: 'เชื่อมต่อ VPN ตาม Gateway',
                icon: Icons.vpn_key_rounded,
                expand: true,
                loading: _busy == _Busy.follow || connecting,
                onPressed: _busy == _Busy.none && !connecting
                    ? () => _followGateway(gateway)
                    : null,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildManage() {
    // NetworkService.leave/deleteNetwork stop the *current* network's
    // heartbeat whatever the slug, so only act on the current network.
    final idle = _busy == _Busy.none && _isCurrent;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.settings,
            title: 'จัดการเครือข่าย',
            trailing: _isCreator
                ? const M3Tag('ผู้สร้าง',
                    tone: M3Tone.gold, icon: Icons.workspace_premium_rounded)
                : null,
          ),
          const SizedBox(height: 14),
          GlossButton(
            label: 'ออกจากเครือข่าย',
            icon: Icons.exit_to_app_rounded,
            variant: GlossVariant.red,
            expand: true,
            loading: _busy == _Busy.leave,
            onPressed: idle ? _leave : null,
          ),
          const SizedBox(height: 10),
          GlossButton(
            label: 'ลบเครือข่าย',
            icon: Icons.delete_forever_rounded,
            variant: GlossVariant.glass,
            expand: true,
            loading: _busy == _Busy.delete,
            onPressed: idle ? _delete : null,
          ),
          const SizedBox(height: 8),
          Text(
            'ลบได้เฉพาะผู้สร้างเครือข่าย — สมาชิกทุกคนจะถูกนำออกและลบถาวร',
            style: M3Text.sub(context).copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }

  static const _thMonths = [
    'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
    'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.',
  ];

  static String _thaiDate(DateTime t) {
    final d = t.toLocal();
    return '${d.day} ${_thMonths[d.month - 1]} ${d.year + 543}';
  }
}

// ── Hero ────────────────────────────────────────────────────────────────

class _DetailHero extends StatelessWidget {
  final AppServices services;
  final VpnNetwork network;
  final bool isCurrent;
  final bool isCreator;
  final VoidCallback onToggle;
  final VoidCallback onInvite;
  final void Function(String text, [String? what]) onCopy;

  const _DetailHero({
    required this.services,
    required this.network,
    required this.isCurrent,
    required this.isCreator,
    required this.onToggle,
    required this.onInvite,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final s = services;
    final net = network;
    final connected = isCurrent && s.vpn.isConnected;
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final vip = isCurrent ? (s.vpn.virtualIp ?? s.network.ownVirtualIp) : null;
    final members = isCurrent ? s.network.members : const <NetworkMember>[];
    final total = members.isNotEmpty ? members.length : net.memberCount;
    final online = members.isNotEmpty
        ? members.where((m) => m.isOnline).length
        : net.onlineCount;

    final headline = connected
        ? 'เชื่อมต่อ LAN แล้ว'
        : (isCurrent ? 'พร้อมเชื่อมต่อ' : 'ไม่ได้อยู่ในวงนี้');
    final detail = connected
        ? 'เครื่องในวงมองเห็นกันเหมือนเสียบสาย LAN เดียวกัน — เปิดเกมแล้วเลือกโหมด LAN ได้เลย'
        : isCurrent
            ? 'กดเชื่อมต่อเพื่อเปิดการ์ดเครือข่ายเสมือนและใช้ Virtual IP ของคุณ'
            : 'เข้าร่วมวงอีกครั้งจากหน้าเครือข่ายเพื่อใช้งาน';

    final orb = Icon3D(
      connected ? M3Icons.p2pDirect : M3Icons.networks,
      size: narrow ? 88 : 128,
      glow: connected ? p.green.withValues(alpha: 0.45) : p.logoGlow,
      opacity: isCurrent ? 1 : 0.5,
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            M3Tag(
              net.isPublic ? 'วงสาธารณะ' : 'วงส่วนตัว',
              tone: net.isPublic ? M3Tone.cyan : M3Tone.gold,
              icon: net.isPublic ? Icons.public_rounded : Icons.lock_rounded,
            ),
            if (isCreator)
              const M3Tag('ผู้สร้างวง',
                  tone: M3Tone.gold, icon: Icons.workspace_premium_rounded),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            StatusOrb(
              color: connected
                  ? p.green
                  : (isCurrent ? p.amber : p.text3),
              size: 11,
              pulse: connected,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                headline,
                style: TextStyle(
                  fontFamily: M3Fonts.head,
                  fontSize: narrow ? 23 : 30,
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
          spacing: narrow ? 18 : 28,
          runSpacing: 10,
          children: [
            _Metric(
              label: 'Virtual IP',
              value: vip ?? '—',
              mono: true,
              onTap: vip == null ? null : () => onCopy(vip),
            ),
            _Metric(
              label: 'ซับเน็ต',
              value: net.virtualSubnet ?? '—',
              mono: true,
            ),
            _Metric(label: 'ออนไลน์', value: '$online/$total'),
            _Metric(
              label: 'P2P ตรง · รีเลย์',
              value: connected
                  ? '${s.vpn.directPeers} · ${s.vpn.relayPeers}'
                  : '—',
            ),
          ],
        ),
      ],
    );

    final buttons = Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
      children: [
        if (isCurrent)
          GlossButton(
            label: connected ? 'ตัดการเชื่อมต่อ' : 'เชื่อมต่อ LAN',
            icon: connected ? Icons.stop_rounded : Icons.power_settings_new,
            variant: connected ? GlossVariant.red : GlossVariant.aqua,
            size: GlossSize.large,
            loading: s.vpn.isStarting,
            onPressed: s.vpn.isStarting ? null : onToggle,
          ),
        GlossButton(
          label: 'ชวนเพื่อน',
          icon3d: M3Icons.invite,
          variant: GlossVariant.glass,
          size: GlossSize.large,
          onPressed: onInvite,
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

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final VoidCallback? onTap;

  const _Metric({
    required this.label,
    required this.value,
    this.mono = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    Widget child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: mono
                  ? M3Text.mono(context,
                      size: narrow ? 15 : 18,
                      weight: FontWeight.w700,
                      color: p.numText)
                  : M3Text.num(context, size: narrow ? 19 : 23),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 5),
              Icon(Icons.copy_rounded, size: 13, color: p.text3),
            ],
          ],
        ),
        Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
      ],
    );
    if (onTap == null) return child;
    return Tooltip(
      message: 'คัดลอก',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: child),
      ),
    );
  }
}

// ── Member row ──────────────────────────────────────────────────────────

class _MemberRow extends StatelessWidget {
  final NetworkMember member;
  final bool self;
  final bool? direct;
  final bool showPing;
  final double? pingMs;
  final bool compact;
  final void Function(String text, [String? what]) onCopy;

  const _MemberRow({
    required this.member,
    required this.self,
    required this.direct,
    required this.showPing,
    required this.pingMs,
    required this.compact,
    required this.onCopy,
  });

  static bool _isPhone(String name) {
    final n = name.toLowerCase();
    return n.contains('android') || n.contains('phone') || n.contains('iphone');
  }

  static String _lastSeen(DateTime? t) {
    if (t == null) return 'ออฟไลน์';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'เพิ่งออฟไลน์';
    if (d.inHours < 1) return 'ออนไลน์ล่าสุด ${d.inMinutes} นาทีก่อน';
    if (d.inDays < 1) return 'ออนไลน์ล่าสุด ${d.inHours} ชม.ก่อน';
    return 'ออนไลน์ล่าสุด ${d.inDays} วันก่อน';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final m = member;
    final ip = m.virtualIp;
    final cc = m.vpnGatewayCountry?.toUpperCase() ?? '';

    return M3Row(
      selected: self,
      leading: Icon3D(
        _isPhone(m.displayName) ? M3Icons.devicePhone : M3Icons.devicePc,
        size: 40,
        opacity: m.isOnline ? 1 : 0.45,
      ),
      title: m.displayName,
      subtitleWidget: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (ip != null)
              Tooltip(
                message: 'คัดลอก IP',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => onCopy(ip),
                    child: Text(ip, style: M3Text.mono(context, size: 12)),
                  ),
                ),
              ),
            if (self)
              const M3Tag('เครื่องนี้', tone: M3Tone.cyan)
            else if (m.isOnline && direct != null)
              M3Tag(
                direct! ? 'P2P ตรง' : 'ผ่านรีเลย์',
                tone: direct! ? M3Tone.green : M3Tone.amber,
              ),
            if (!m.isOnline)
              M3Tag(_lastSeen(m.lastHeartbeat), tone: M3Tone.neutral),
            if (m.isVpnGateway)
              M3Tag(
                isWindows || m.vpnGatewayFlag.isEmpty
                    ? 'VPN $cc'
                    : 'VPN ${m.vpnGatewayFlag} $cc',
                tone: M3Tone.gold,
              ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showPing && m.isOnline && !self) ...[
            _PingMeter(ms: pingMs),
            const SizedBox(width: 8),
          ],
          if (!compact && ip != null) ...[
            GlossIconButton(
              icon: Icons.copy_rounded,
              size: 28,
              tooltip: 'คัดลอก IP',
              onPressed: () => onCopy(ip),
            ),
            const SizedBox(width: 10),
          ],
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

/// Small glass ping readout: four signal bars and the median in ms.
class _PingMeter extends StatelessWidget {
  final double? ms;

  const _PingMeter({required this.ms});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final v = ms;
    final tone = v == null
        ? M3Tone.neutral
        : v < 60
            ? M3Tone.green
            : v < 130
                ? M3Tone.amber
                : M3Tone.red;
    final lit = v == null
        ? 0
        : v < 30
            ? 4
            : v < 60
                ? 3
                : v < 130
                    ? 2
                    : 1;
    final color = p.toneColor(tone);

    return Tooltip(
      message: v == null ? 'ไม่ตอบกลับ ping' : 'ปิง ${v.round()} ms',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: p.toneSoft(tone),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.toneSoftLine(tone)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    width: 3.5,
                    height: 5.0 + i * 3,
                    margin: EdgeInsets.only(right: i == 3 ? 0 : 2),
                    decoration: BoxDecoration(
                      color: i < lit ? color : p.track,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 6),
            Text(
              v == null ? 'ไม่ตอบ' : '${v.round()} ms',
              style: M3Text.mono(context,
                  size: 11.5, weight: FontWeight.w700, color: p.toneText(tone)),
            ),
          ],
        ),
      ),
    );
  }
}
