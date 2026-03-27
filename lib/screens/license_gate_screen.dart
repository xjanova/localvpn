import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/license_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_background.dart';
import '../widgets/cyber_page_route.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';
import 'home_screen.dart';

class LicenseGateScreen extends StatefulWidget {
  final LicenseService licenseService;

  const LicenseGateScreen({
    super.key,
    required this.licenseService,
  });

  @override
  State<LicenseGateScreen> createState() => _LicenseGateScreenState();
}

class _LicenseGateScreenState extends State<LicenseGateScreen> {
  final TextEditingController _licenseController = TextEditingController();
  bool _showLicenseInput = false;
  bool _activating = false;
  bool _enteringFree = false;

  @override
  void dispose() {
    _licenseController.dispose();
    super.dispose();
  }

  Future<void> _activateLicense() async {
    final key = _licenseController.text.trim();
    if (key.isEmpty) {
      SoundService().play(SfxType.error);
      _showError('กรุณากรอก License Key');
      return;
    }

    setState(() => _activating = true);

    final success = await widget.licenseService.activate(key);

    if (!mounted) return;

    setState(() => _activating = false);

    if (success) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();
      _navigateToHome();
    } else {
      SoundService().play(SfxType.error);
      _showError(
        widget.licenseService.state.errorMessage ??
            'ไม่สามารถเปิดใช้งาน License ได้',
      );
      widget.licenseService.clearError();
    }
  }

  void _navigateToHome() {
    Navigator.of(context).pushReplacement(
      CyberPageRoute(
        builder: (_) => HomeScreen(
          licenseService: widget.licenseService,
        ),
      ),
    );
  }

  Future<void> _openPurchaseUrl(String plan) async {
    SoundService().play(SfxType.tap);
    final url = widget.licenseService.getPurchaseUrl(plan);
    final uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        if (mounted) {
          _showError('ไม่สามารถเปิดเว็บเบราว์เซอร์ได้');
        }
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error.withValues(alpha: 0.9),
      ),
    );
  }

  void _copyDeviceId() {
    final deviceId = widget.licenseService.deviceId;
    if (deviceId != null) {
      Clipboard.setData(ClipboardData(text: deviceId));
      SoundService().play(SfxType.coin);
      HapticFeedback.lightImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('คัดลอก Device ID แล้ว'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                _buildHeader(),
                const SizedBox(height: 32),
                if (_showLicenseInput) ...[
                  _buildLicenseInput(),
                  const SizedBox(height: 24),
                ] else ...[
                  _buildPricingCards(),
                  const SizedBox(height: 24),
                  _buildActionButtons(),
                ],
                const SizedBox(height: 16),
                _buildDeviceInfo(),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: AppTheme.primaryGradient,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(
            Icons.vpn_lock,
            size: 40,
            color: Colors.white,
          ),
        )
            .animate()
            .scale(
              begin: const Offset(0.5, 0.5),
              end: const Offset(1, 1),
              duration: 600.ms,
              curve: Curves.elasticOut,
            )
            .fadeIn(duration: 400.ms)
            .then()
            .shimmer(
              duration: 2000.ms,
              color: Colors.white.withValues(alpha: 0.2),
            ),
        const SizedBox(height: 16),
        const Text(
          'LocalVPN',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        )
            .animate()
            .fadeIn(duration: 500.ms, delay: 200.ms)
            .slideY(begin: 0.3, end: 0),
        const SizedBox(height: 8),
        const Text(
          'สร้าง Virtual LAN ระหว่างอุปกรณ์ผ่านอินเทอร์เน็ต',
          style: TextStyle(
            fontSize: 14,
            color: AppColors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ).animate().fadeIn(duration: 500.ms, delay: 400.ms),
      ],
    );
  }

  Widget _buildPricingCards() {
    return Column(
      children: [
        // Free plan card
        _buildFreePlanCard(),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(child: Divider(color: AppColors.cardBorder)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'อัพเกรด Premium',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(child: Divider(color: AppColors.cardBorder)),
            ],
          ),
        ),
        _buildPricingCard(
          title: 'รายเดือน',
          price: '399',
          period: 'บาท/เดือน',
          plan: 'monthly',
          color: AppColors.primary,
          features: 'สมาชิกสูงสุด 50 คน/ห้อง',
          index: 0,
        ),
        _buildPricingCard(
          title: 'รายปี',
          price: '2,500',
          period: 'บาท/ปี',
          plan: 'yearly',
          color: AppColors.secondary,
          badge: 'ประหยัด 48%',
          features: 'สมาชิกสูงสุด 50 คน/ห้อง',
          index: 1,
        ),
        _buildPricingCard(
          title: 'ตลอดชีพ',
          price: '5,000',
          period: 'บาท (จ่ายครั้งเดียว)',
          plan: 'lifetime',
          color: AppColors.warning,
          badge: 'คุ้มที่สุด',
          features: 'สมาชิกสูงสุด 50 คน/ห้อง',
          index: 2,
        ),
      ],
    );
  }

  Widget _buildFreePlanCard() {
    return GlassCard(
      borderColor: AppColors.success.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'ฟรี',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.success,
                  ),
                ),
              ),
              const Spacer(),
              const Icon(Icons.check_circle, color: AppColors.success, size: 20),
            ],
          ),
          const SizedBox(height: 10),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '0',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(width: 4),
              Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'บาท ตลอดไป',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildFeatureRow(Icons.check, 'Global Torrent ใช้ได้เต็มรูปแบบ', true),
          _buildFeatureRow(Icons.check, 'สร้าง/เข้าร่วมเครือข่าย VPN', true),
          _buildFeatureRow(Icons.check, 'แชร์ไฟล์ในเครือข่าย', true),
          _buildFeatureRow(Icons.remove, 'จำกัดสมาชิกสูงสุด 5 คน/ห้อง', false),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
  }

  Widget _buildFeatureRow(IconData icon, String text, bool included) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14,
            color: included ? AppColors.success : AppColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: included ? AppColors.textSecondary : AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPricingCard({
    required String title,
    required String price,
    required String period,
    required String plan,
    required Color color,
    String? badge,
    String? features,
    int index = 0,
  }) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 12),
      borderColor: color.withValues(alpha: 0.3),
      onTap: () => _openPurchaseUrl(plan),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      )
                          .animate()
                          .shimmer(
                            duration: 2000.ms,
                            delay: (500 + index * 200).ms,
                            color: color.withValues(alpha: 0.3),
                          ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      price,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        period,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                if (features != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    features,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(
            Icons.arrow_forward_ios,
            color: color,
            size: 16,
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(
            duration: 400.ms, delay: (300 + index * 100).ms)
        .slideX(
            begin: 0.1,
            end: 0,
            duration: 400.ms,
            delay: (300 + index * 100).ms);
  }

  void _enterFreeMode() {
    if (_enteringFree) return;
    _enteringFree = true;
    widget.licenseService.setFreeMode();
    SoundService().play(SfxType.coin);
    HapticFeedback.mediumImpact();
    _navigateToHome();
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: NeonButton(
            text: 'เข้าใช้ฟรี',
            icon: Icons.play_arrow,
            color: AppColors.success,
            onPressed: _enterFreeMode,
          ),
        ).animate().fadeIn(duration: 400.ms, delay: 700.ms),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: NeonButton(
            text: 'มี License Key แล้ว',
            icon: Icons.key,
            outlined: true,
            onPressed: () {
              SoundService().play(SfxType.notification);
              setState(() => _showLicenseInput = true);
            },
          ),
        ).animate().fadeIn(duration: 400.ms, delay: 800.ms),
      ],
    );
  }

  Widget _buildLicenseInput() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'กรอก License Key',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: AppColors.textMuted),
                onPressed: () {
                  SoundService().play(SfxType.tap);
                  setState(() => _showLicenseInput = false);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _licenseController,
            maxLength: 30,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
            decoration: const InputDecoration(
              hintText: 'XXXX-XXXX-XXXX-XXXX',
              prefixIcon: Icon(Icons.key, color: AppColors.primary),
              counterText: '',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _activateLicense(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: NeonButton(
              text: 'เปิดใช้งาน',
              isLoading: _activating,
              onPressed: _activating ? null : _activateLicense,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => _openPurchaseUrl('monthly'),
              child: const Text(
                'ซื้อ License Key',
                style: TextStyle(
                  color: AppColors.secondary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.1, end: 0);
  }

  Widget _buildDeviceInfo() {
    final deviceId = widget.licenseService.deviceId;
    if (deviceId == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: _copyDeviceId,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.fingerprint,
              size: 14,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 8),
            Text(
              'Device ID: ${deviceId.substring(0, 12)}...',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textMuted,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.copy,
              size: 12,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 900.ms);
  }
}
