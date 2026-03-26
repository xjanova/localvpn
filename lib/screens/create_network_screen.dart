import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/network_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/neon_button.dart';
import 'network_detail_screen.dart';

class CreateNetworkScreen extends StatefulWidget {
  final NetworkService networkService;

  const CreateNetworkScreen({
    super.key,
    required this.networkService,
  });

  @override
  State<CreateNetworkScreen> createState() => _CreateNetworkScreenState();
}

class _CreateNetworkScreenState extends State<CreateNetworkScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isPublic = true;
  double _maxMembers = 10;
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _createNetwork() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showError('กรุณากรอกชื่อเครือข่าย');
      return;
    }

    if (name.length < 3) {
      _showError('ชื่อเครือข่ายต้องมีอย่างน้อย 3 ตัวอักษร');
      return;
    }

    if (!_isPublic && _passwordController.text.trim().isEmpty) {
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
      password:
          !_isPublic ? _passwordController.text.trim() : null,
      maxMembers: _maxMembers.round(),
    );

    if (!mounted) return;

    setState(() => _isCreating = false);

    if (success) {
      final network = widget.networkService.currentNetwork;
      if (network != null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
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
            onPressed: () => Navigator.of(context).pop(),
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
    );
  }

  Widget _buildNameField() {
    return GlassCard(
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
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0);
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
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _isPublic
                  ? AppColors.primary.withValues(alpha: 0.1)
                  : AppColors.secondary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isPublic ? Icons.public : Icons.lock,
              color: _isPublic ? AppColors.primary : AppColors.secondary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isPublic ? 'สาธารณะ' : 'ส่วนตัว',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
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
    return GlassCard(
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
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
              max: 50,
              divisions: 48,
              onChanged: (value) {
                setState(() => _maxMembers = value);
              },
            ),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '2',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
              Text(
                '50',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(duration: 400.ms, delay: 300.ms)
        .slideY(begin: 0.1, end: 0);
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
