import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/license_state.dart';
import '../services/file_transfer_service.dart';
import '../services/license_service.dart';
import '../services/network_service.dart';
import '../services/p2p_service.dart';
import '../services/vpn_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';
import '../widgets/status_indicator.dart';
import 'file_transfer_screen.dart';
import 'network_list_screen.dart';
import 'network_detail_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final LicenseService licenseService;

  const HomeScreen({
    super.key,
    required this.licenseService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late final NetworkService _networkService;
  late final VpnService _vpnService;
  late final P2pService _p2pService;
  late final FileTransferService _fileTransferService;

  @override
  void initState() {
    super.initState();
    _networkService = NetworkService();
    _vpnService = VpnService();
    _p2pService = P2pService();
    _fileTransferService = FileTransferService();

    final deviceId = widget.licenseService.deviceId;
    if (deviceId != null) {
      _networkService.configure(
        deviceId: deviceId,
        licenseKey: widget.licenseService.state.licenseKey,
      );

      // Wire up P2P service
      _networkService.attachP2p(_p2pService);
      _vpnService.attachP2p(_p2pService);

      // Wire up file transfer
      _fileTransferService.configure(
        p2pService: _p2pService,
        deviceId: deviceId,
        licenseKey: widget.licenseService.state.licenseKey ?? '',
      );
      _p2pService.onFileMessage = (ip, data) {
        _fileTransferService.handleMessage(ip, data);
      };
    }

    _networkService.addListener(_onNetworkChanged);
    _vpnService.addListener(_onVpnChanged);
    _p2pService.addListener(_onP2pChanged);
    _fileTransferService.addListener(_onChanged);
  }

  void _onNetworkChanged() {
    _fileTransferService.setNetwork(_networkService.currentNetwork?.slug);
    if (mounted) setState(() {});
  }

  void _onVpnChanged() {
    if (mounted) setState(() {});
  }

  void _onP2pChanged() {
    if (mounted) setState(() {});
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _networkService.removeListener(_onNetworkChanged);
    _vpnService.removeListener(_onVpnChanged);
    _p2pService.removeListener(_onP2pChanged);
    _fileTransferService.removeListener(_onChanged);
    _networkService.dispose();
    _vpnService.dispose();
    _p2pService.dispose();
    _fileTransferService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: IndexedStack(
          index: _currentIndex,
          children: [
            _buildHomeTab(),
            NetworkListScreen(networkService: _networkService),
            FileTransferScreen(
              fileTransferService: _fileTransferService,
              p2pService: _p2pService,
            ),
            _buildDevicesTab(),
            SettingsScreen(
              licenseService: widget.licenseService,
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(
            color: AppColors.cardBorder,
            width: 1,
          ),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'หน้าแรก',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.lan_outlined),
            activeIcon: Icon(Icons.lan),
            label: 'เครือข่าย',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder_shared_outlined),
            activeIcon: Icon(Icons.folder_shared),
            label: 'ไฟล์',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.devices_outlined),
            activeIcon: Icon(Icons.devices),
            label: 'อุปกรณ์',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'ตั้งค่า',
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAppBar(),
            const SizedBox(height: 24),
            _buildConnectionStatus(),
            const SizedBox(height: 20),
            _buildCurrentNetwork(),
            const SizedBox(height: 20),
            _buildQuickActions(),
            const SizedBox(height: 20),
            _buildLicenseInfo(),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: AppTheme.primaryGradient,
          ),
          child: const Icon(
            Icons.vpn_lock,
            color: Colors.white,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LocalVPN',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                'Virtual LAN Manager',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        StatusIndicator(
          isOnline: _vpnService.isConnected,
          size: 12,
        ),
      ],
    ).animate().fadeIn(duration: 400.ms);
  }

  Widget _buildConnectionStatus() {
    final isConnected = _vpnService.isConnected;

    return GlassCard(
      borderColor: isConnected
          ? AppColors.success.withValues(alpha: 0.3)
          : AppColors.cardBorder,
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isConnected
                      ? AppColors.success.withValues(alpha: 0.1)
                      : AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  isConnected ? Icons.shield : Icons.shield_outlined,
                  color: isConnected ? AppColors.success : AppColors.textMuted,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isConnected ? 'เชื่อมต่อแล้ว' : 'ไม่ได้เชื่อมต่อ',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isConnected
                            ? AppColors.success
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isConnected
                          ? 'Virtual IP: ${_vpnService.virtualIp ?? "N/A"}'
                          : 'เลือกเครือข่ายเพื่อเริ่มเชื่อมต่อ',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                        fontFamily:
                            isConnected ? 'monospace' : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // P2P connection stats
          if (isConnected && _p2pService.isActive) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _buildP2pStat(
                  Icons.swap_horiz,
                  '${_vpnService.directPeers}',
                  'P2P ตรง',
                  AppColors.success,
                ),
                const SizedBox(width: 12),
                _buildP2pStat(
                  Icons.cloud_outlined,
                  '${_vpnService.relayPeers}',
                  'ผ่านเซิร์ฟเวอร์',
                  AppColors.warning,
                ),
              ],
            ),
          ],
          if (_networkService.currentNetwork != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: NeonButton(
                text: isConnected ? 'ยกเลิกการเชื่อมต่อ' : 'เชื่อมต่อ VPN',
                color: isConnected ? AppColors.error : AppColors.primary,
                icon: isConnected ? Icons.stop : Icons.play_arrow,
                isLoading: _vpnService.isStarting,
                onPressed: _vpnService.isStarting
                    ? null
                    : () async {
                        if (isConnected) {
                          await _vpnService.stopVpn();
                        } else {
                          await _vpnService.startVpn(
                            virtualIp: '10.10.0.2',
                            subnet: '255.255.255.0',
                            peers: [],
                          );
                        }
                      },
              ),
            ),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _buildP2pStat(IconData icon, String value, String label, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color.withValues(alpha: 0.7),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentNetwork() {
    final network = _networkService.currentNetwork;

    if (network == null) {
      return GlassCard(
        child: Column(
          children: [
            const Icon(
              Icons.lan_outlined,
              color: AppColors.textMuted,
              size: 40,
            ),
            const SizedBox(height: 8),
            const Text(
              'ยังไม่ได้เข้าร่วมเครือข่าย',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            NeonButton(
              text: 'ค้นหาเครือข่าย',
              icon: Icons.search,
              outlined: true,
              onPressed: () => setState(() => _currentIndex = 1),
            ),
          ],
        ),
      ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
    }

    return GlassCard(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NetworkDetailScreen(
              networkService: _networkService,
              network: network,
            ),
          ),
        );
      },
      borderColor: AppColors.primary.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.lan,
                color: AppColors.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              const Text(
                'เครือข่ายปัจจุบัน',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.arrow_forward_ios,
                color: AppColors.textMuted,
                size: 14,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            network.name,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildInfoChip(
                Icons.people,
                '${network.memberCount} สมาชิก',
              ),
              const SizedBox(width: 12),
              _buildInfoChip(
                Icons.circle,
                '${network.onlineCount} ออนไลน์',
                color: AppColors.success,
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
  }

  Widget _buildInfoChip(IconData icon, String text, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color ?? AppColors.textMuted),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: color ?? AppColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'การดำเนินการ',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ).animate().fadeIn(duration: 300.ms, delay: 300.ms),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildActionCard(
                icon: Icons.add_circle_outline,
                label: 'สร้างเครือข่าย',
                color: AppColors.primary,
                onTap: () => setState(() => _currentIndex = 1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionCard(
                icon: Icons.search,
                label: 'ค้นหาเครือข่าย',
                color: AppColors.secondary,
                onTap: () => setState(() => _currentIndex = 1),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GlassCard(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 400.ms).scale(
          begin: const Offset(0.9, 0.9),
          end: const Offset(1, 1),
          duration: 400.ms,
          delay: 400.ms,
        );
  }

  Widget _buildLicenseInfo() {
    final license = widget.licenseService.state;

    return GlassCard(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: license.status == LicenseStatus.active
                  ? AppColors.success.withValues(alpha: 0.1)
                  : AppColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              license.status == LicenseStatus.active
                  ? Icons.verified
                  : Icons.timer,
              color: license.status == LicenseStatus.active
                  ? AppColors.success
                  : AppColors.warning,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'License: ${license.statusDisplayName}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  license.status == LicenseStatus.trial
                      ? 'เหลือ ${license.demoMinutesLeft ?? 0} นาที'
                      : license.typeDisplayName,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 500.ms);
  }

  Widget _buildDevicesTab() {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Text(
              'อุปกรณ์ที่รู้จัก',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _networkService.members.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.devices_other,
                          size: 64,
                          color: AppColors.textMuted.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'ยังไม่พบอุปกรณ์',
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'เข้าร่วมเครือข่ายเพื่อค้นหาอุปกรณ์',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _networkService.members.length,
                    itemBuilder: (context, index) {
                      final member = _networkService.members[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: member.isOnline
                                ? AppColors.success.withValues(alpha: 0.2)
                                : AppColors.cardBorder,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: member.isOnline
                                    ? AppColors.success.withValues(alpha: 0.1)
                                    : AppColors.surfaceLight,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(
                                Icons.devices,
                                color: member.isOnline
                                    ? AppColors.success
                                    : AppColors.textMuted,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    member.displayName,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  if (member.virtualIp != null)
                                    Text(
                                      member.virtualIp!,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            StatusIndicator(isOnline: member.isOnline),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
