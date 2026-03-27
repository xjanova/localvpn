import 'dart:math' show sin;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/license_service.dart';
import '../services/network_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../widgets/cyber_page_route.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';
import 'license_gate_screen.dart';
import 'network_detail_screen.dart';

class CreateNetworkScreen extends StatefulWidget {
  final NetworkService networkService;
  final LicenseService licenseService;

  const CreateNetworkScreen({
    super.key,
    required this.networkService,
    required this.licenseService,
  });

  @override
  State<CreateNetworkScreen> createState() => _CreateNetworkScreenState();
}

class _CreateNetworkScreenState extends State<CreateNetworkScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isPublic = true;
  double _maxMembers = 10;
  bool _isCreating = false;

  // Shake animation for errors
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _passwordController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _triggerShake() {
    _shakeController.forward().then((_) => _shakeController.reverse());
  }

  Future<void> _createNetwork() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      SoundService().play(SfxType.error);
      _triggerShake();
      _showError('กรุณากรอกชื่อเครือข่าย');
      return;
    }

    if (name.length < 3) {
      SoundService().play(SfxType.error);
      _triggerShake();
      _showError('ชื่อเครือข่ายต้องมีอย่างน้อย 3 ตัวอักษร');
      return;
    }

    if (!_isPublic && _passwordController.text.trim().isEmpty) {
      SoundService().play(SfxType.error);
      _triggerShake();
      _showError('กรุณากรอกรหัสผ่านสำหรับเครือข่ายส่วนตัว');
      return;
    }

    setState(() => _isCreating = true);

    final success = await widget.networkService.createNetwork(
      name: name,
      description: _descController.text.trim().isNotEmpty
          ? _descController.text.trim()
          : null,
      isPublic: _isPublic,
      password: !_isPublic ? _passwordController.text.trim() : null,
      maxMembers: _maxMembers.round(),
    );

    if (!mounted) return;

    setState(() => _isCreating = false);

    if (success) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();

      final network = widget.networkService.currentNetwork;
      if (network != null) {
        Navigator.of(context).pushReplacement(
          CyberPageRoute(
            builder: (_) => NetworkDetailScreen(
              networkService: widget.networkService,
              network: network,
            ),
          ),
        );
      } else {
        Navigator.of(context).pop();
      }
    } else {
      SoundService().play(SfxType.error);
      _showError(
        widget.networkService.error ?? 'ไม่สามารถสร้างเครือข่ายได้',
      );
      widget.networkService.clearError();
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

  @override
  Widget build(BuildContext context) {
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
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildNameField(),
                      const SizedBox(height: 16),
                      _buildDescriptionField(),
                      const SizedBox(height: 16),
                      _buildVisibilityToggle(),
                      if (!_isPublic) ...[
                        const SizedBox(height: 16),
                        _buildPasswordField(),
                      ],
                      const SizedBox(height: 16),
                      _buildMaxMembersSlider(),
                      const SizedBox(height: 32),
                      _buildCreateButton(),
                    ],
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
          const Expanded(
            child: Text(
              'สร้างเครือข่ายใหม่',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.1, end: 0);
  }

  Widget _buildNameField() {
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        final shake =
            sin(_shakeAnimation.value * 3 * 3.14159) * 8 * (1 - _shakeAnimation.value);
        return Transform.translate(
          offset: Offset(shake, 0),
          child: child,
        );
      },
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ชื่อเครือข่าย',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: AppColors.textPrimary),
              maxLength: 50,
              decoration: const InputDecoration(
                hintText: 'เช่น My Gaming LAN',
                prefixIcon: Icon(Icons.lan, color: AppColors.primary),
                counterStyle: TextStyle(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),
    );
  }

  Widget _buildDescriptionField() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'คำอธิบาย (ไม่จำเป็น)',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descController,
            style: const TextStyle(color: AppColors.textPrimary),
            maxLength: 200,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'อธิบายเกี่ยวกับเครือข่ายนี้...',
              counterStyle: TextStyle(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(duration: 400.ms, delay: 100.ms)
        .slideY(begin: 0.1, end: 0);
  }

  Widget _buildVisibilityToggle() {
    return GlassCard(
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _isPublic
                  ? AppColors.primary.withValues(alpha: 0.1)
                  : AppColors.secondary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, animation) {
                return RotationTransition(
                  turns: Tween(begin: 0.0, end: 1.0).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: Icon(
                _isPublic ? Icons.public : Icons.lock,
                key: ValueKey(_isPublic),
                color: _isPublic ? AppColors.primary : AppColors.secondary,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _isPublic ? 'สาธารณะ' : 'ส่วนตัว',
                    key: ValueKey(_isPublic),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  _isPublic
                      ? 'ทุกคนสามารถค้นหาและเข้าร่วมได้'
                      : 'ต้องมีรหัสผ่านจึงจะเข้าร่วมได้',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _isPublic,
            onChanged: (value) {
              SoundService().play(SfxType.toggle);
              HapticFeedback.selectionClick();
              setState(() => _isPublic = value);
            },
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(duration: 400.ms, delay: 200.ms)
        .slideY(begin: 0.1, end: 0);
  }

  Widget _buildPasswordField() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'รหัสผ่าน',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordController,
            obscureText: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'กรอกรหัสผ่านเครือข่าย',
              prefixIcon: Icon(Icons.key, color: AppColors.secondary),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05, end: 0);
  }

  Widget _buildMaxMembersSlider() {
    final isFree = widget.licenseService.state.isFree;
    final maxAllowed = widget.licenseService.state.maxNetworkMembers;
    // Clamp value to prevent slider assertion error
    _maxMembers = _maxMembers.clamp(2, maxAllowed.toDouble());

    return Column(
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'จำนวนสมาชิกสูงสุด',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    transitionBuilder: (child, anim) {
                      return ScaleTransition(scale: anim, child: child);
                    },
                    child: Container(
                      key: ValueKey(_maxMembers.round()),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_maxMembers.round()} คน',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: AppColors.primary,
                  inactiveTrackColor: AppColors.surfaceLight,
                  thumbColor: AppColors.primary,
                  overlayColor: AppColors.primary.withValues(alpha: 0.1),
                ),
                child: Slider(
                  value: _maxMembers,
                  min: 2,
                  max: maxAllowed.toDouble(),
                  divisions: maxAllowed - 2,
                  onChanged: (value) {
                    if (value.round() != _maxMembers.round()) {
                      HapticFeedback.selectionClick();
                    }
                    setState(() => _maxMembers = value);
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '2',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                  Text(
                    '$maxAllowed',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        )
            .animate()
            .fadeIn(duration: 400.ms, delay: 300.ms)
            .slideY(begin: 0.1, end: 0),
        if (isFree) ...[
          const SizedBox(height: 8),
          GlassCard(
            borderColor: AppColors.warning.withValues(alpha: 0.3),
            onTap: () {
              SoundService().play(SfxType.tap);
              Navigator.of(context).push(
                CyberPageRoute(
                  builder: (_) => LicenseGateScreen(
                    licenseService: widget.licenseService,
                  ),
                ),
              );
            },
            child: Row(
              children: [
                Icon(
                  Icons.workspace_premium,
                  color: AppColors.warning,
                  size: 20,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'อัพเกรด Premium เพื่อรองรับสูงสุด 50 คน/ห้อง',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.warning,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  color: AppColors.warning,
                  size: 14,
                ),
              ],
            ),
          ).animate().fadeIn(duration: 400.ms, delay: 350.ms),
        ],
      ],
    );
  }

  Widget _buildCreateButton() {
    return SizedBox(
      width: double.infinity,
      child: NeonButton(
        text: 'สร้างเครือข่าย',
        icon: Icons.add_circle,
        isLoading: _isCreating,
        onPressed: _isCreating ? null : _createNetwork,
      ),
    )
        .animate()
        .fadeIn(duration: 400.ms, delay: 400.ms)
        .slideY(begin: 0.1, end: 0);
  }
}

