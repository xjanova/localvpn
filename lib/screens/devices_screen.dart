import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/member.dart';
import '../widgets/m3/m3.dart';
import '../services/p2p_service.dart';
import '../widgets/peer_path_tag.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "อุปกรณ์" — every machine in the current network as a glass card, plus a
/// card for this machine (its virtual IP and public P2P endpoint).
class DevicesScreen extends StatefulWidget {
  final AppServices services;

  const DevicesScreen({super.key, required this.services});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    s.network.addListener(_refresh);
    s.p2p.addListener(_refresh);
    s.vpn.addListener(_refresh);
  }

  @override
  void dispose() {
    s.network.removeListener(_refresh);
    s.p2p.removeListener(_refresh);
    s.vpn.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final net = s.network.currentNetwork;
    final members = [...s.network.members]..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return a.displayName.compareTo(b.displayName);
      });
    final own = s.network.ownVirtualIp;
    final others = members.where((m) => m.virtualIp != own).toList();
    final online = others.where((m) => m.isOnline).length;

    return M3PageBody(
      onRefresh: () async {
        if (net != null) await s.network.getMembers(net.slug);
      },
      children: [
        M3PageHeader(
          icon3d: M3Icons.devicePc,
          title: 'อุปกรณ์',
          subtitle: net == null
              ? 'เข้าร่วมวงเพื่อดูเครื่องอื่น ๆ'
              : 'วง "${net.name}" · ออนไลน์ $online จาก ${others.length} เครื่อง',
          trailing: const ShellBadges(),
        ),
        const SizedBox(height: 16),
        _ThisMachine(services: s),
        const SizedBox(height: 18),
        M3SectionTitle(
          'เครื่องอื่นในวง',
          trailing: net == null
              ? null
              : GlossIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'รีเฟรช',
                  onPressed: () => s.network.getMembers(net.slug),
                ),
        ),
        if (net == null)
          GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.networks,
              title: 'ยังไม่ได้เข้าร่วมวง',
              message: 'เครื่องที่อยู่ในวงเดียวกันจะแสดงที่นี่',
              action: GlossButton(
                label: 'ไปหน้าเครือข่าย',
                icon3d: M3Icons.scan,
                onPressed: () =>
                    AppShellScope.of(context).goTo(ShellTab.networks),
              ),
            ),
          )
        else if (others.isEmpty)
          const GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.invite,
              title: 'ยังไม่มีเครื่องอื่นในวง',
              message: 'ชวนเพื่อนเข้าวงด้วยชื่อวงและรหัสผ่าน',
            ),
          )
        else
          LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth >= 1000
                ? 3
                : c.maxWidth >= 620
                    ? 2
                    : 1;
            const gap = 14.0;
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < others.length; i++)
                  SizedBox(
                    width: w,
                    child: _DeviceCard(
                      member: others[i],
                      path: s.p2p.pathOf(others[i].virtualIp),
                    )
                        .animate()
                        .fadeIn(delay: (i * 50).ms, duration: 300.ms)
                        .slideY(begin: 0.06, end: 0),
                  ),
              ],
            );
          }),
      ],
    );
  }
}

class _ThisMachine extends StatelessWidget {
  final AppServices services;
  const _ThisMachine({required this.services});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final s = services;
    final vip = s.vpn.virtualIp ?? s.network.ownVirtualIp;
    final pub = s.p2p.publicIp == null
        ? null
        : '${s.p2p.publicIp}:${s.p2p.publicPort ?? '-'}';
    return GlassPanel(
      highlight: true,
      gloss: false,
      accent: s.vpn.isConnected ? p.green : null,
      child: Wrap(
        spacing: 24,
        runSpacing: 14,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon3D(M3Icons.adapter, size: 74,
                  glow: s.vpn.isConnected
                      ? p.green.withValues(alpha: 0.35)
                      : null),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('เครื่องนี้', style: M3Text.h2(context)),
                  const SizedBox(height: 2),
                  M3Tag(
                    s.vpn.isConnected
                        ? 'การ์ดเครือข่ายเสมือนทำงาน'
                        : 'การ์ดเครือข่ายเสมือนปิดอยู่',
                    tone: s.vpn.isConnected ? M3Tone.green : M3Tone.neutral,
                    dot: true,
                  ),
                ],
              ),
            ],
          ),
          _Readout(label: 'Virtual IP', value: vip ?? '—', copy: vip),
          _Readout(label: 'ปลายทาง P2P สาธารณะ', value: pub ?? '—', copy: pub),
          _Readout(
            label: 'การเชื่อมต่อกับเพื่อน',
            value: s.vpn.isConnected
                ? 'ตรง ${s.vpn.directPeers} · รีเลย์ ${s.vpn.relayPeers}'
                : '—',
          ),
        ],
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  final String label;
  final String value;
  final String? copy;

  const _Readout({required this.label, required this.value, this.copy});

  @override
  Widget build(BuildContext context) {
    return M3Inset(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
              const SizedBox(height: 2),
              Text(value,
                  style: M3Text.mono(context,
                      size: 15, weight: FontWeight.w700,
                      color: context.m3.numText)),
            ],
          ),
          if (copy != null) ...[
            const SizedBox(width: 10),
            GlossIconButton(
              icon: Icons.copy_rounded,
              size: 30,
              tooltip: 'คัดลอก',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: copy!));
                m3Toast(context, 'คัดลอกแล้ว', tone: M3Tone.green);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final NetworkMember member;
  final P2pPath? path;

  const _DeviceCard({required this.member, this.path});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final m = member;
    final phone = m.displayName.toLowerCase().contains('android') ||
        m.displayName.toLowerCase().contains('phone') ||
        m.displayName.toLowerCase().contains('iphone');
    return GlassPanel(
      accent: m.isOnline ? p.green.withValues(alpha: 0.8) : null,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon3D(phone ? M3Icons.devicePhone : M3Icons.devicePc,
              size: 62, opacity: m.isOnline ? 1 : 0.4),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(m.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: M3Text.h2(context)),
                    ),
                    StatusOrb(
                      color: m.isOnline ? p.green : p.text3,
                      size: 10,
                      pulse: m.isOnline,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (m.virtualIp != null)
                  Text(m.virtualIp!, style: M3Text.mono(context, size: 13.5)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (m.isOnline && path != null) PeerPathTag(path!),
                    if (!m.isOnline)
                      M3Tag(_lastSeen(m.lastHeartbeat),
                          tone: M3Tone.neutral),
                    if (m.isVpnGateway)
                      M3Tag('แชร์ VPN ${m.vpnGatewayCountry}',
                          tone: M3Tone.gold),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _lastSeen(DateTime? t) {
    if (t == null) return 'ออฟไลน์';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'เพิ่งออฟไลน์';
    if (d.inHours < 1) return 'ออนไลน์ล่าสุด ${d.inMinutes} นาทีก่อน';
    if (d.inDays < 1) return 'ออนไลน์ล่าสุด ${d.inHours} ชม.ก่อน';
    return 'ออนไลน์ล่าสุด ${d.inDays} วันก่อน';
  }
}
