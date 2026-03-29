import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/proxy_server.dart';
import '../services/license_service.dart';
import '../services/network_service.dart';
import '../services/vpn_proxy_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/latency_gauge.dart';
import '../widgets/vpn_mascot.dart';

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
  Timer? _pingTimer;

  @override
  void initState() {
    super.initState();
    widget.vpnProxyService.addListener(_onChanged);
    if (widget.vpnProxyService.countries.isEmpty) {
      widget.vpnProxyService.fetchServers().then((_) {
        widget.vpnProxyService.pingAllCountries();
      });
    }
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    widget.vpnProxyService.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});

    // Start/stop ping timer based on connection status
    if (widget.vpnProxyService.status == VpnProxyStatus.connected &&
        _pingTimer == null) {
      _pingTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => widget.vpnProxyService.pingConnected(),
      );
      widget.vpnProxyService.pingConnected();
    } else if (widget.vpnProxyService.status != VpnProxyStatus.connected) {
      _pingTimer?.cancel();
      _pingTimer = null;
    }
  }

  bool get _isInNetwork => widget.networkService.currentNetwork != null;
  bool get _isPremium => widget.licenseService.state.isPaid;

  MascotState get _mascotState {
    return switch (widget.vpnProxyService.status) {
      VpnProxyStatus.connecting => MascotState.connecting,
      VpnProxyStatus.connected => MascotState.connected,
      VpnProxyStatus.error => MascotState.error,
      _ => MascotState.idle,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: AppColors.surface,
        onRefresh: () async {
          await widget.vpnProxyService.fetchServers();
          widget.vpnProxyService.pingAllCountries();
        },
        child: CustomScrollView(
          slivers: [
            // === Mascot + Status Hero ===
            SliverToBoxAdapter(child: _buildHero()),

            // === LAN info banners ===
            if (_isConnected && _isInNetwork)
              _sliverPad(_buildLanPausedBanner()),

            // === Error ===
            if (widget.vpnProxyService.error != null)
              _sliverPad(_buildErrorCard()),

            // === Content ===
            if (widget.vpnProxyService.isLoading)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            else if (widget.vpnProxyService.countries.isEmpty &&
                !_isConnected) ...[
              // Empty state — no servers available
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off,
                          size: 56, color: AppColors.textMuted),
                      const SizedBox(height: 16),
                      const Text(
                        'ไม่สามารถโหลดรายการ VPN ได้',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'เซิร์ฟเวอร์อาจไม่พร้อมใช้งานชั่วคราว\nกรุณาลองใหม่อีกครั้ง',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: () async {
                          await widget.vpnProxyService.fetchServers();
                          widget.vpnProxyService.pingAllCountries();
                        },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('ลองใหม่'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: AppColors.background,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              _sliverPad(_buildSectionTitle('เลือกประเทศ'), top: 8),
              _buildCountryGrid(),
              if (widget.vpnProxyService.lockedCountries.isNotEmpty) ...[
                _sliverPad(
                  Row(children: [
                    Icon(Icons.lock_outline, size: 14, color: AppColors.textMuted),
                    const SizedBox(width: 6),
                    Text('Premium Only',
                        style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ]),
                  top: 12,
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

  bool get _isConnected =>
      widget.vpnProxyService.status == VpnProxyStatus.connected ||
      widget.vpnProxyService.status == VpnProxyStatus.connecting;

  Widget _sliverPad(Widget child, {double top = 4}) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, top, 16, 4),
      sliver: SliverToBoxAdapter(child: child),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Text(text,
        style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600));
  }

  // ─────────────────────────────────────────────
  // HERO: Mascot + Status + Gauge
  // ─────────────────────────────────────────────
  Widget _buildHero() {
    final svc = widget.vpnProxyService;
    final country = svc.countries
        .where((c) => c.countryCode == svc.connectedCountry)
        .firstOrNull;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          // Mascot
          VpnMascot(
            state: _mascotState,
            size: 140,
            countryFlag: country?.flag,
          ).animate().fadeIn(duration: 500.ms).scale(
                begin: const Offset(0.8, 0.8),
                duration: 600.ms,
                curve: Curves.elasticOut,
              ),

          const SizedBox(height: 8),

          // Status text
          Text(
            _statusText,
            style: TextStyle(
              color: _statusColor,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ).animate().fadeIn(delay: 200.ms),

          if (country != null && _isConnected) ...[
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(country.flag, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 6),
                Text(
                  country.countryName,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                ),
              ],
            ),
          ],

          // Latency gauge (when connected)
          if (svc.status == VpnProxyStatus.connected) ...[
            const SizedBox(height: 8),
            LatencyGauge(pingMs: svc.currentPing, size: 140)
                .animate()
                .fadeIn(delay: 300.ms)
                .slideY(begin: 0.2, duration: 400.ms),
          ],

          // Stats row (when connected)
          if (svc.status == VpnProxyStatus.connected) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildStatChip(Icons.arrow_downward, svc.byteIn ?? '0', 'DL'),
                _buildStatChip(Icons.arrow_upward, svc.byteOut ?? '0', 'UL'),
                _buildStatChip(Icons.timer_outlined,
                    _fmtDuration(svc.duration), 'Time'),
              ],
            ).animate().fadeIn(delay: 400.ms),
          ],

          const SizedBox(height: 12),

          // Connect/Disconnect button
          _buildPowerButton(),

          // Premium badge
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _isPremium
                  ? 'PREMIUM - VPN ทุกประเทศ'
                  : 'FREE - 3 ประเทศ (JP, US, KR)',
              style: TextStyle(
                color: _isPremium ? AppColors.primary : AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _statusText {
    final svc = widget.vpnProxyService;
    if (svc.status == VpnProxyStatus.connecting && svc.connectingServerInfo != null) {
      return 'กำลังเชื่อมต่อ ${svc.connectingServerInfo}...';
    }
    return switch (svc.status) {
      VpnProxyStatus.disconnected => 'พร้อมเชื่อมต่อ',
      VpnProxyStatus.connecting => 'กำลังเชื่อมต่อ...',
      VpnProxyStatus.connected => 'เชื่อมต่อแล้ว',
      VpnProxyStatus.disconnecting => 'กำลังตัดการเชื่อมต่อ...',
      VpnProxyStatus.error => 'เกิดข้อผิดพลาด',
    };
  }

  Color get _statusColor {
    return switch (widget.vpnProxyService.status) {
      VpnProxyStatus.connected => AppColors.success,
      VpnProxyStatus.connecting ||
      VpnProxyStatus.disconnecting => AppColors.warning,
      VpnProxyStatus.error => AppColors.error,
      _ => AppColors.textSecondary,
    };
  }

  Widget _buildStatChip(IconData icon, String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.primary),
          const SizedBox(width: 4),
          Text(value,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(color: AppColors.textMuted, fontSize: 9)),
        ],
      ),
    );
  }

  String _fmtDuration(Duration? d) {
    if (d == null) return '0:00';
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (d.inHours > 0) return '${d.inHours}:${m.toString().padLeft(2, '0')}h';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildPowerButton() {
    final svc = widget.vpnProxyService;
    final isActive = svc.status == VpnProxyStatus.connected ||
        svc.status == VpnProxyStatus.connecting;

    return GestureDetector(
      onTap: isActive
          ? () {
              HapticFeedback.heavyImpact();
              svc.disconnect();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isActive
              ? LinearGradient(
                  colors: [Colors.red.shade700, Colors.red.shade900])
              : null,
          color: isActive ? null : AppColors.surfaceLight,
          border: Border.all(
            color: isActive
                ? Colors.red.shade500
                : AppColors.cardBorder,
            width: 2,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.red.withValues(alpha: 0.3),
                    blurRadius: 16,
                    spreadRadius: 2,
                  )
                ]
              : null,
        ),
        child: Icon(
          Icons.power_settings_new,
          color: isActive ? Colors.white : AppColors.textMuted,
          size: 28,
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  // BANNERS
  // ─────────────────────────────────────────────
  Widget _buildLanPausedBanner() {
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.info_outline, color: AppColors.warning, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Virtual LAN หยุดชั่วคราว — ปิด VPN เพื่อกลับไปใช้ LAN',
              style: TextStyle(color: AppColors.warning, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(widget.vpnProxyService.error!,
                style: TextStyle(color: Colors.orange.shade200, fontSize: 13)),
          ),
          IconButton(
            onPressed: () => widget.vpnProxyService.clearError(),
            icon: Icon(Icons.close, size: 18, color: AppColors.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // COUNTRY GRIDS
  // ─────────────────────────────────────────────
  Widget _buildCountryGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.5,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final country = widget.vpnProxyService.countries[index];
            final isConnected =
                widget.vpnProxyService.connectedCountry == country.countryCode &&
                widget.vpnProxyService.status == VpnProxyStatus.connected;

            return _CountryCard(
              country: country,
              isConnected: isConnected,
              onTap: () => _onCountryTap(country),
            ).animate(delay: (index * 60).ms).fadeIn().scale(
                  begin: const Offset(0.92, 0.92),
                  duration: 250.ms,
                  curve: Curves.easeOutCubic,
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

  // ─────────────────────────────────────────────
  // ACTIONS
  // ─────────────────────────────────────────────
  void _onCountryTap(ProxyCountry country) {
    HapticFeedback.mediumImpact();

    // Warn if user is in a LAN — VPN will replace the LAN tunnel
    if (_isInNetwork) {
      _showLanVpnWarning(country);
      return;
    }

    _connectToCountry(country);
  }

  void _connectToCountry(ProxyCountry country) {
    if (widget.vpnProxyService.status == VpnProxyStatus.connected ||
        widget.vpnProxyService.status == VpnProxyStatus.connecting) {
      // Use switchToCountry for race-condition-safe reconnect
      widget.vpnProxyService.switchToCountry(country);
    } else {
      widget.vpnProxyService.connectToCountry(country);
    }
  }

  void _showLanVpnWarning(ProxyCountry country) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 24),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Virtual LAN จะหยุดชั่วคราว',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          ),
        ]),
        content: const Text(
          'Android อนุญาต VPN ได้ครั้งละ 1 tunnel เท่านั้น\n\n'
          'เมื่อเปิด VPN Proxy → Virtual LAN จะหยุดทำงานชั่วคราว '
          'สมาชิกในวงจะเห็นคุณ offline\n\n'
          'ปิด VPN Proxy → Virtual LAN จะกลับมาทำงานอัตโนมัติ',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('ยกเลิก', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _connectToCountry(country);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('เปิด VPN ต่อ'),
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
        title: Row(children: [
          Icon(Icons.workspace_premium, color: Colors.amber, size: 24),
          const SizedBox(width: 8),
          const Text('Premium Only',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 18)),
        ]),
        content: const Text(
          'อัพเกรดเป็น Premium เพื่อ:\n'
          '- VPN มุดได้ทุกประเทศ\n'
          '- สมาชิกในวง LAN สูงสุด 50 คน\n'
          '- ซัพพอร์ตพรีเมียม',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('ปิด', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
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

// ─────────────────────────────────────────────
// COUNTRY CARD (with latency bar)
// ─────────────────────────────────────────────
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
    final ping = country.bestServer?.measuredPing;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: isConnected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.success.withValues(alpha: 0.15),
                    AppColors.success.withValues(alpha: 0.05),
                  ],
                )
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.surfaceLight,
                    AppColors.surface,
                  ],
                ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isConnected
                ? AppColors.success.withValues(alpha: 0.6)
                : AppColors.cardBorder,
            width: isConnected ? 2 : 1,
          ),
          boxShadow: isConnected
              ? [
                  BoxShadow(
                    color: AppColors.success.withValues(alpha: 0.1),
                    blurRadius: 12,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Flag + Name + Status dot
            Row(
              children: [
                Text(country.flag, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        country.countryName,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${country.serverCount} servers',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                if (isConnected)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.success,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.success.withValues(alpha: 0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
              ],
            ),

            // Latency bar + speed
            Row(
              children: [
                // Latency bar
                Expanded(
                  child: _LatencyBar(pingMs: ping),
                ),
                const SizedBox(width: 8),
                // Speed
                Text(
                  country.bestSpeedLabel,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 10,
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

// ─────────────────────────────────────────────
// LATENCY BAR (inline in country card)
// ─────────────────────────────────────────────
class _LatencyBar extends StatelessWidget {
  final int? pingMs;

  const _LatencyBar({this.pingMs});

  @override
  Widget build(BuildContext context) {
    final ratio = pingMs != null ? (pingMs! / 300).clamp(0.0, 1.0) : 0.0;

    return Row(
      children: [
        Icon(Icons.signal_cellular_alt, size: 10, color: _color),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(2),
            ),
            child: FractionallySizedBox(
              widthFactor: pingMs != null ? (1.0 - ratio).clamp(0.1, 1.0) : 0,
              alignment: Alignment.centerLeft,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [_color, _color.withValues(alpha: 0.5)]),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          pingMs != null ? '${pingMs}ms' : '--',
          style: TextStyle(
            color: _color,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Color get _color {
    if (pingMs == null) return AppColors.textMuted;
    if (pingMs! < 50) return const Color(0xFF69F0AE);
    if (pingMs! < 100) return const Color(0xFFB2FF59);
    if (pingMs! < 150) return const Color(0xFFFFD740);
    if (pingMs! < 250) return const Color(0xFFFF9100);
    return const Color(0xFFFF5252);
  }
}

// ─────────────────────────────────────────────
// LOCKED COUNTRY CHIP
// ─────────────────────────────────────────────
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
          color: AppColors.surfaceLight.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.cardBorder.withValues(alpha: 0.3)),
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
                    fontWeight: FontWeight.w500),
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
