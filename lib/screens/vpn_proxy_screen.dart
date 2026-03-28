import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/proxy_server.dart';
import '../services/license_service.dart';
import '../services/network_service.dart';
import '../services/vpn_proxy_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

class VpnProxyScreen extends StatefulWidget {
  final VpnProxyService vpnProxyService;
  final LicenseService licenseService;
  final NetworkService networkService;

  const VpnProxyScreen({
    super.key,
    required this.vpnProxyService,
    required this.licenseService,
    required this.networkService,
  });

  @override
  State<VpnProxyScreen> createState() => _VpnProxyScreenState();
}

class _VpnProxyScreenState extends State<VpnProxyScreen> {
  @override
  void initState() {
    super.initState();
    widget.vpnProxyService.addListener(_onChanged);
    if (widget.vpnProxyService.countries.isEmpty) {
      widget.vpnProxyService.fetchServers();
    }
  }

  @override
  void dispose() {
    widget.vpnProxyService.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: AppColors.surface,
        onRefresh: () => widget.vpnProxyService.fetchServers(),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(child: _buildHeader()),
            ),
            if (_isConnectedOrConnecting)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(child: _buildConnectionCard()),
              ),
            // Show LAN routing info for Premium users hosting while VPN is active
            if (_isConnectedOrConnecting && _isInNetwork && _isPremium)
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                sliver: SliverToBoxAdapter(
                  child: GlassCard(
                    child: Row(
                      children: [
                        Icon(Icons.lan, color: AppColors.primary, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'สมาชิกในวง LAN จะออก IP เดียวกัน (${widget.vpnProxyService.connectedCountry ?? ""})',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Warning for free users in network
            if (!_isConnectedOrConnecting && _isInNetwork && !_isPremium)
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                sliver: SliverToBoxAdapter(
                  child: GlassCard(
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: Colors.orange, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'คุณอยู่ในวง LAN อยู่ — ออกจากวงก่อนใช้ VPN ฟรี หรืออัพเกรด Premium เพื่อใช้พร้อมกัน',
                            style: TextStyle(
                              color: Colors.orange.shade200,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (widget.vpnProxyService.error != null)
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                sliver: SliverToBoxAdapter(child: _buildErrorCard()),
              ),
            if (widget.vpnProxyService.isLoading)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    'เลือกประเทศ',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _buildCountryGrid(),
              if (widget.vpnProxyService.lockedCountries.isNotEmpty) ...[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline,
                            size: 16, color: AppColors.textMuted),
                        const SizedBox(width: 6),
                        Text(
                          'Premium Only',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _buildLockedGrid(),
              ],
              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          ],
        ),
      ),
    );
  }

  bool get _isConnectedOrConnecting =>
      widget.vpnProxyService.status == VpnProxyStatus.connected ||
      widget.vpnProxyService.status == VpnProxyStatus.connecting;

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: AppTheme.primaryGradient,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.public, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'VPN Proxy',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _isPremium
                    ? 'Premium - ทุกประเทศ + โฮสต์ LAN ผ่าน VPN'
                    : 'Free - มุดเดี่ยว 3 ประเทศ',
                style: TextStyle(
                  color: _isPremium ? AppColors.primary : AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => widget.vpnProxyService.fetchServers(),
          icon: Icon(Icons.refresh, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildConnectionCard() {
    final svc = widget.vpnProxyService;
    final isConnecting = svc.status == VpnProxyStatus.connecting;
    final country = svc.countries
        .where((c) => c.countryCode == svc.connectedCountry)
        .firstOrNull;

    return GlassCard(
      margin: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Row(
            children: [
              // Country flag
              Text(
                country?.flag ?? '',
                style: const TextStyle(fontSize: 36),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      country?.countryName ?? svc.connectedCountry ?? '',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                isConnecting ? Colors.orange : Colors.green,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isConnecting ? 'กำลังเชื่อมต่อ...' : 'เชื่อมต่อแล้ว',
                          style: TextStyle(
                            color: isConnecting
                                ? Colors.orange
                                : Colors.green,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (svc.status == VpnProxyStatus.connected) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (svc.byteIn != null)
                  _buildStat(Icons.arrow_downward, svc.byteIn!, 'Download'),
                if (svc.byteOut != null)
                  _buildStat(Icons.arrow_upward, svc.byteOut!, 'Upload'),
                if (svc.duration != null)
                  _buildStat(
                    Icons.timer_outlined,
                    _formatDuration(svc.duration!),
                    'Duration',
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isConnecting ? null : () => svc.disconnect(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: isConnecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.power_settings_new, size: 20),
              label: Text(isConnecting ? 'กำลังเชื่อมต่อ...' : 'ตัดการเชื่อมต่อ'),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.1);
  }

  Widget _buildStat(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${s}s';
  }

  Widget _buildErrorCard() {
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.vpnProxyService.error!,
              style: TextStyle(color: Colors.orange.shade200, fontSize: 13),
            ),
          ),
          IconButton(
            onPressed: () => widget.vpnProxyService.clearError(),
            icon:
                Icon(Icons.close, size: 18, color: AppColors.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildCountryGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.6,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final country = widget.vpnProxyService.countries[index];
            final isConnected =
                widget.vpnProxyService.connectedCountry ==
                    country.countryCode &&
                widget.vpnProxyService.status == VpnProxyStatus.connected;

            return _CountryCard(
              country: country,
              isConnected: isConnected,
              onTap: () => _onCountryTap(country),
            ).animate(delay: (index * 50).ms).fadeIn().scale(
                  begin: const Offset(0.95, 0.95),
                  duration: 200.ms,
                );
          },
          childCount: widget.vpnProxyService.countries.length,
        ),
      ),
    );
  }

  Widget _buildLockedGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.0,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final country = widget.vpnProxyService.lockedCountries[index];
            return _LockedCountryChip(
              country: country,
              onTap: () => _showPremiumDialog(),
            );
          },
          childCount: widget.vpnProxyService.lockedCountries.length,
        ),
      ),
    );
  }

  /// Check if user is currently in a Virtual LAN network
  bool get _isInNetwork => widget.networkService.currentNetwork != null;

  /// Check if user has premium license
  bool get _isPremium => widget.licenseService.state.isPaid;

  void _onCountryTap(ProxyCountry country) {
    HapticFeedback.mediumImpact();

    // Free user hosting a network → block VPN proxy
    if (_isInNetwork && !_isPremium) {
      _showHostVpnPremiumDialog();
      return;
    }

    if (widget.vpnProxyService.status == VpnProxyStatus.connected) {
      // Disconnect first, then connect to new country
      widget.vpnProxyService.disconnect().then((_) {
        Future.delayed(const Duration(milliseconds: 500), () {
          widget.vpnProxyService.connectToCountry(country);
        });
      });
    } else {
      widget.vpnProxyService.connectToCountry(country);
    }
  }

  void _showHostVpnPremiumDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.workspace_premium, color: Colors.amber, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Premium Only',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
              ),
            ),
          ],
        ),
        content: const Text(
          'ใช้ VPN พร้อมกับโฮสต์ Virtual LAN ได้เฉพาะ Premium\n\n'
          'Premium: สมาชิกในวงจะออก IP เดียวกันกับประเทศที่คุณเลือก\n\n'
          'หากต้องการใช้ VPN แบบฟรี ให้ออกจากเครือข่ายก่อน',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('ปิด', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              // TODO: Navigate to pricing
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('ดูแพ็กเกจ'),
          ),
        ],
      ),
    );
  }

  void _showPremiumDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.workspace_premium, color: Colors.amber, size: 24),
            const SizedBox(width: 8),
            const Text(
              'Premium Only',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
            ),
          ],
        ),
        content: const Text(
          'อัพเกรดเป็น Premium เพื่อ:\n'
          '- ใช้ VPN ได้ทุกประเทศ\n'
          '- โฮสต์ LAN + VPN พร้อมกัน\n'
          '- สมาชิกในวงออก IP เดียวกัน',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('ปิด', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Navigate to pricing
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('ดูแพ็กเกจ'),
          ),
        ],
      ),
    );
  }
}

class _CountryCard extends StatelessWidget {
  final ProxyCountry country;
  final bool isConnected;
  final VoidCallback onTap;

  const _CountryCard({
    required this.country,
    required this.isConnected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: isConnected
              ? LinearGradient(colors: [
                  Colors.green.shade900.withValues(alpha: 0.5),
                  Colors.green.shade800.withValues(alpha: 0.3),
                ])
              : null,
          color: isConnected ? null : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isConnected ? Colors.green.shade600 : AppColors.cardBorder,
            width: isConnected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(country.flag, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    country.countryName,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isConnected)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                    ),
                  ),
              ],
            ),
            Row(
              children: [
                Icon(Icons.dns_outlined,
                    size: 12, color: AppColors.textMuted),
                const SizedBox(width: 4),
                Text(
                  '${country.serverCount} servers',
                  style:
                      TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Icon(Icons.speed, size: 12, color: AppColors.textMuted),
                const SizedBox(width: 4),
                Text(
                  country.bestSpeedLabel,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedCountryChip extends StatelessWidget {
  final ProxyCountry country;
  final VoidCallback onTap;

  const _LockedCountryChip({required this.country, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceLight.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.cardBorder.withValues(alpha: 0.5)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(country.flag, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                country.countryCode,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.lock, size: 10, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
