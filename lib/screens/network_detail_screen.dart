import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/network.dart';
import '../services/network_service.dart';
import '../services/vpn_service.dart';  // Used for vpnService parameter
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/member_tile.dart';
import '../widgets/neon_button.dart';

class NetworkDetailScreen extends StatefulWidget {
  final NetworkService networkService;
  final VpnNetwork network;
  final VpnService? vpnService;

  const NetworkDetailScreen({
    super.key,
    required this.networkService,
    required this.network,
    this.vpnService,
  });

  @override
  State<NetworkDetailScreen> createState() => _NetworkDetailScreenState();
}

class _NetworkDetailScreenState extends State<NetworkDetailScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadMembers();
    widget.networkService.addListener(_onChanged);

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _loadMembers(),
    );
  }

  void _onChanged() {
    if (mounted) setState(() {});
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
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
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
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ยกเลิก'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
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
    // Use live network from service (updated by heartbeat) with fallback to snapshot
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
            onPressed: () => Navigator.of(context).pop(),
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
    );
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
      ],
    ).animate().fadeIn(duration: 300.ms, delay: 200.ms);
  }

  Widget _buildEmptyMembers() {
    return Container(
      padding: const EdgeInsets.all(32),
      child: const Column(
        children: [
          Icon(
            Icons.people_outline,
            size: 48,
            color: AppColors.textMuted,
          ),
          SizedBox(height: 12),
          Text(
            'ยังไม่มีสมาชิก',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          SizedBox(height: 4),
          Text(
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
