import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/network.dart';
import '../services/network_service.dart';
import '../services/sound_service.dart';
import '../services/vpn_proxy_service.dart';
import '../services/vpn_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/member_tile.dart';
import '../widgets/neon_button.dart';

class NetworkDetailScreen extends StatefulWidget {
  final NetworkService networkService;
  final VpnNetwork network;
  final VpnService? vpnService;
  final VpnProxyService? vpnProxyService;

  const NetworkDetailScreen({
    super.key,
    required this.networkService,
    required this.network,
    this.vpnService,
    this.vpnProxyService,
  });

  @override
  State<NetworkDetailScreen> createState() => _NetworkDetailScreenState();
}

class _NetworkDetailScreenState extends State<NetworkDetailScreen> {
  Timer? _refreshTimer;
  int _previousMemberCount = 0;

  @override
  void initState() {
    super.initState();
    _previousMemberCount = widget.networkService.members.length;
    _loadMembers();
    widget.networkService.addListener(_onChanged);

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _loadMembers(),
    );
  }

  void _onChanged() {
    if (mounted) {
      // Play notification when new member joins
      final currentCount = widget.networkService.members.length;
      if (currentCount > _previousMemberCount && _previousMemberCount > 0) {
        SoundService().play(SfxType.notification);
      }
      _previousMemberCount = currentCount;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    widget.networkService.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _loadMembers() async {
    await widget.networkService.getMembers(widget.network.slug);
  }

  Future<void> _leaveNetwork() async {
    SoundService().play(SfxType.notification);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'ออกจากเครือข่าย',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'ต้องการออกจาก "${widget.network.name}" ใช่หรือไม่?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () {
              SoundService().play(SfxType.tap);
              Navigator.pop(ctx, false);
            },
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () {
              SoundService().play(SfxType.disconnect);
              Navigator.pop(ctx, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text(
              'ออก',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (widget.vpnService?.isConnected == true) {
      await widget.vpnService!.stopVpn();
    }

    final success =
        await widget.networkService.leaveNetwork(widget.network.slug);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop();
    } else {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.networkService.error ?? 'ไม่สามารถออกจากเครือข่ายได้',
          ),
          backgroundColor: AppColors.error.withValues(alpha: 0.9),
        ),
      );
      widget.networkService.clearError();
    }
  }

  Future<void> _deleteNetwork() async {
    SoundService().play(SfxType.notification);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'ลบเครือข่าย',
          style: TextStyle(color: AppColors.error),
        ),
        content: Text(
          'ต้องการลบ "${widget.network.name}" ใช่หรือไม่? การกระทำนี้ไม่สามารถยกเลิกได้',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () {
              SoundService().play(SfxType.tap);
              Navigator.pop(ctx, false);
            },
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () {
              SoundService().play(SfxType.disconnect);
              Navigator.pop(ctx, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text(
              'ลบ',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (widget.vpnService?.isConnected == true) {
      await widget.vpnService!.stopVpn();
    }

    final success =
        await widget.networkService.deleteNetwork(widget.network.slug);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop();
    } else {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.networkService.error ?? 'ไม่สามารถลบเครือข่ายได้',
          ),
          backgroundColor: AppColors.error.withValues(alpha: 0.9),
        ),
      );
      widget.networkService.clearError();
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.networkService.members;
    final network = widget.networkService.currentNetwork ?? widget.network;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              Expanded(
                child: RefreshIndicator(
                  color: AppColors.primary,
                  backgroundColor: AppColors.surface,
                  onRefresh: _loadMembers,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildNetworkInfo(network),
                        if (_hasGateway) ...[
                          const SizedBox(height: 12),
                          _buildGatewayBanner(),
                        ],
                        const SizedBox(height: 20),
                        _buildMembersHeader(members.length),
                        const SizedBox(height: 12),
                        if (members.isEmpty)
                          _buildEmptyMembers()
                        else
                          ...members.asMap().entries.map(
                                (entry) => MemberTile(
                                  member: entry.value,
                                  index: entry.key,
                                ),
                              ),
                        const SizedBox(height: 24),
                        _buildActions(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.primary),
            onPressed: () {
              SoundService().play(SfxType.swoosh);
              Navigator.of(context).pop();
            },
          ),
          Expanded(
            child: Text(
              widget.network.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
            color: AppColors.surface,
            onSelected: (value) {
              if (value == 'delete') {
                _deleteNetwork();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete, color: AppColors.error, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'ลบเครือข่าย',
                      style: TextStyle(color: AppColors.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms);
  }

  Widget _buildNetworkInfo(VpnNetwork network) {
    return GlassCard(
      borderColor: AppColors.primary.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.lan,
                  color: Colors.white,
                  size: 24,
                ),
              )
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .shimmer(
                    duration: 3000.ms,
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      network.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (network.description != null &&
                        network.description!.isNotEmpty)
                      Text(
                        network.description!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildInfoItem(
                Icons.people,
                '${network.memberCount}',
                'สมาชิก',
              ),
              const SizedBox(width: 20),
              _buildInfoItem(
                Icons.circle,
                '${network.onlineCount}',
                'ออนไลน์',
                color: AppColors.success,
              ),
              const SizedBox(width: 20),
              _buildInfoItem(
                network.isPublic ? Icons.public : Icons.lock,
                network.isPublic ? 'สาธารณะ' : 'ส่วนตัว',
                'ประเภท',
                color: network.isPublic
                    ? AppColors.primary
                    : AppColors.secondary,
              ),
            ],
          ),
          if (network.virtualSubnet != null) ...[
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.router,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Subnet: ${network.virtualSubnet}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _buildInfoItem(
    IconData icon,
    String value,
    String label, {
    Color? color,
  }) {
    return Column(
      children: [
        Icon(icon, size: 18, color: color ?? AppColors.textMuted),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: color ?? AppColors.textPrimary,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildMembersHeader(int count) {
    return Row(
      children: [
        const Text(
          'สมาชิก',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, anim) {
            return ScaleTransition(scale: anim, child: child);
          },
          child: Container(
            key: ValueKey(count),
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: 300.ms, delay: 200.ms);
  }

  Widget _buildEmptyMembers() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Icon(
            Icons.people_outline,
            size: 48,
            color: AppColors.textMuted,
          )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .moveY(begin: 0, end: -6, duration: 2000.ms),
          const SizedBox(height: 12),
          const Text(
            'ยังไม่มีสมาชิก',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'แชร์ลิงก์เครือข่ายเพื่อเชิญเพื่อน',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  bool get _hasGateway => widget.networkService.hasVpnGateway;

  Widget _buildGatewayBanner() {
    final gateway = widget.networkService.vpnGatewayMember;
    if (gateway == null) return const SizedBox.shrink();

    final isSelf = widget.networkService.isSelfGateway &&
        gateway.machineId == widget.networkService.deviceId;

    return GlassCard(
      borderColor: AppColors.primary.withValues(alpha: 0.4),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primary.withValues(alpha: 0.2),
                  AppColors.secondary.withValues(alpha: 0.2),
                ],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                gateway.vpnGatewayFlag,
                style: const TextStyle(fontSize: 20),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isSelf ? 'คุณเป็น VPN Gateway' : 'VPN Gateway',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                Text(
                  isSelf
                      ? 'สมาชิกสามารถเชื่อมต่อ VPN ตามคุณได้'
                      : '${gateway.displayName} · ${gateway.vpnGatewayCountry?.toUpperCase() ?? ''}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (!isSelf && widget.vpnProxyService != null)
            SizedBox(
              height: 32,
              child: ElevatedButton.icon(
                onPressed: _followGateway,
                icon: const Icon(Icons.vpn_key, size: 14),
                label: const Text(
                  'Follow',
                  style: TextStyle(fontSize: 12),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0);
  }

  Future<void> _followGateway() async {
    final proxy = widget.vpnProxyService;
    if (proxy == null) return;

    final gateway = widget.networkService.vpnGatewayMember;
    if (gateway == null || !gateway.isVpnGateway) return;

    // Warn about LAN pause
    SoundService().play(SfxType.notification);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'เชื่อมต่อ VPN Gateway',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'เชื่อมต่อ VPN ไปยัง ${gateway.vpnGatewayCountry?.toUpperCase() ?? ''} '
          'ตาม ${gateway.displayName}\n\n'
          'Android อนุญาต VPN ได้ครั้งละ 1 tunnel เท่านั้น '
          'การเชื่อมต่อ LAN จะถูกหยุดชั่วคราว',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
            ),
            child: const Text(
              'เชื่อมต่อ',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Ensure server list is loaded
    if (proxy.countries.isEmpty) {
      await proxy.fetchServers();
    }

    // Try to find same server by hostname
    if (gateway.vpnGatewayHostname != null) {
      final server = proxy.findServerByHostname(gateway.vpnGatewayHostname!);
      if (server != null) {
        await proxy.connect(server);
        return;
      }
    }

    // Fallback: connect to same country
    if (gateway.vpnGatewayCountry != null) {
      final country = proxy.findCountryByCode(gateway.vpnGatewayCountry!);
      if (country != null) {
        await proxy.connectToCountry(country);
        return;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ไม่พบ VPN server สำหรับ gateway นี้'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Widget _buildActions() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: NeonButton(
            text: 'ออกจากเครือข่าย',
            icon: Icons.exit_to_app,
            color: AppColors.error,
            outlined: true,
            onPressed: _leaveNetwork,
          ),
        ),
      ],
    ).animate().fadeIn(duration: 400.ms, delay: 400.ms);
  }
}
