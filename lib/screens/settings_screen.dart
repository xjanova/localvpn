import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../database/database_helper.dart';
import '../models/license_state.dart';
import '../services/license_service.dart';
import '../services/sound_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/cyber_page_route.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';
import 'license_gate_screen.dart';

class SettingsScreen extends StatefulWidget {
  final LicenseService licenseService;

  const SettingsScreen({
    super.key,
    required this.licenseService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final UpdateService _updateService = UpdateService();
  final SoundService _soundService = SoundService();
  bool _autoConnect = false;

  @override
  void initState() {
    super.initState();
    _updateService.addListener(_onUpdateChanged);
    _updateService.checkForUpdate();
    _loadAutoConnect();
  }

  Future<void> _loadAutoConnect() async {
    final value = await DatabaseHelper().getSetting('auto_connect');
    if (mounted) {
      setState(() => _autoConnect = value == 'true');
    }
  }

  void _onUpdateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _updateService.removeListener(_onUpdateChanged);
    _updateService.dispose();
    super.dispose();
  }

  Future<void> _deactivateLicense() async {
    SoundService().play(SfxType.notification);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'ยกเลิก License',
          style: TextStyle(color: AppColors.error),
        ),
        content: const Text(
          'ต้องการยกเลิก License ใช่หรือไม่? คุณจะต้องเปิดใช้งานใหม่อีกครั้ง',
          style: TextStyle(color: AppColors.textSecondary),
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
              'ยืนยัน',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.licenseService.deactivate();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      CyberPageRoute(
        builder: (_) => LicenseGateScreen(
          licenseService: widget.licenseService,
        ),
      ),
      (_) => false,
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
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ตั้งค่า',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ).animate().fadeIn(duration: 300.ms),
            const SizedBox(height: 24),
            _buildLicenseSection(),
            const SizedBox(height: 16),
            _buildUpdateSection(),
            const SizedBox(height: 16),
            _buildPreferencesSection(),
            const SizedBox(height: 16),
            _buildSoundSection(),
            const SizedBox(height: 16),
            _buildAboutSection(),
            const SizedBox(height: 16),
            _buildLogoutButton(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildLicenseSection() {
    final license = widget.licenseService.state;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: license.isValid
                      ? AppColors.success.withValues(alpha: 0.1)
                      : AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  license.isValid ? Icons.verified : Icons.warning_amber,
                  color: license.isValid
                      ? AppColors.success
                      : AppColors.warning,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'License',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: license.isValid
                      ? AppColors.success.withValues(alpha: 0.1)
                      : AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  license.statusDisplayName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: license.isValid
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildInfoRow('ประเภท', license.typeDisplayName),
          if (license.expiresAt != null)
            _buildInfoRow(
              'หมดอายุ',
              '${license.expiresAt!.day}/${license.expiresAt!.month}/${license.expiresAt!.year}',
            ),
          if (license.status == LicenseStatus.trial &&
              license.demoMinutesLeft != null)
            _buildInfoRow(
              'เวลาที่เหลือ',
              '${license.demoMinutesLeft} นาที',
            ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _copyDeviceId,
            child: _buildInfoRow(
              'Device ID',
              license.deviceId != null
                  ? '${license.deviceId!.substring(0, 16)}... (แตะเพื่อคัดลอก)'
                  : 'ไม่ทราบ',
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms);
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textMuted,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateSection() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _updateService.updateAvailable
                      ? AppColors.warning.withValues(alpha: 0.1)
                      : AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _updateService.updateAvailable
                      ? Icons.system_update
                      : Icons.check_circle,
                  color: _updateService.updateAvailable
                      ? AppColors.warning
                      : AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'อัปเดต',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      _updateService.updateAvailable
                          ? 'มีเวอร์ชันใหม่ ${_updateService.latestVersion}'
                          : 'เวอร์ชันล่าสุดแล้ว (${_updateService.currentVersion})',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_updateService.isChecking)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                )
              else if (_updateService.updateAvailable)
                SizedBox(
                  height: 32,
                  child: ElevatedButton(
                    onPressed: () {
                      SoundService().play(SfxType.tapHeavy);
                      _updateService.downloadUpdate();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.warning,
                      foregroundColor: AppColors.background,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text(
                      'ดาวน์โหลด',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(
                    Icons.refresh,
                    color: AppColors.primary,
                  ),
                  onPressed: () {
                    SoundService().play(SfxType.tap);
                    _updateService.checkForUpdate(force: true);
                  },
                ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
  }

  Widget _buildPreferencesSection() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'การตั้งค่า',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.wifi,
                color: AppColors.textMuted,
                size: 20,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'เชื่อมต่ออัตโนมัติ',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      'เชื่อมต่อเครือข่ายล่าสุดเมื่อเปิดแอป',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _autoConnect,
                onChanged: (value) {
                  SoundService().play(SfxType.toggle);
                  HapticFeedback.selectionClick();
                  setState(() => _autoConnect = value);
                  DatabaseHelper()
                      .setSetting('auto_connect', value.toString());
                },
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 300.ms);
  }

  Widget _buildSoundSection() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'เสียง',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, anim) {
                  return ScaleTransition(scale: anim, child: child);
                },
                child: Icon(
                  _soundService.enabled
                      ? Icons.volume_up
                      : Icons.volume_off,
                  key: ValueKey(_soundService.enabled),
                  color: _soundService.enabled
                      ? AppColors.primary
                      : AppColors.textMuted,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'เอฟเฟกต์เสียง 16-bit',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      'เสียงตอบรับเมื่อกดปุ่มและเปลี่ยนสถานะ',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _soundService.enabled,
                onChanged: (value) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _soundService.setEnabled(value);
                  });
                  // Play a test sound if enabling
                  if (value) {
                    Future.delayed(const Duration(milliseconds: 100), () {
                      SoundService().play(SfxType.coin);
                    });
                  }
                },
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 350.ms);
  }

  Widget _buildAboutSection() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'เกี่ยวกับ',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          _buildInfoRow('แอป', 'LocalVPN'),
          _buildInfoRow('เวอร์ชัน', _updateService.currentVersion),
          _buildInfoRow('ผู้พัฒนา', 'xmanstudio'),
          _buildInfoRow('เว็บไซต์', 'xman4289.com'),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 400.ms);
  }

  Widget _buildLogoutButton() {
    return SizedBox(
      width: double.infinity,
      child: NeonButton(
        text: 'ยกเลิก License',
        icon: Icons.logout,
        color: AppColors.error,
        outlined: true,
        onPressed: _deactivateLicense,
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 500.ms);
  }
}
