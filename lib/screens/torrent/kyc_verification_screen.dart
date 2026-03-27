import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/neon_button.dart';

class KycVerificationScreen extends StatefulWidget {
  final TorrentService torrentService;

  const KycVerificationScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<KycVerificationScreen> createState() => _KycVerificationScreenState();
}

class _KycVerificationScreenState extends State<KycVerificationScreen> {
  final TextEditingController _nameController = TextEditingController();
  DateTime? _birthDate;
  String? _idCardFrontBase64;
  String? _idCardBackBase64;
  String? _selfieBase64;
  String? _idCardFrontName;
  String? _idCardBackName;
  String? _selfieName;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(String type) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();

        // Limit file size to 5MB
        if (bytes.length > 5 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('ไฟล์ใหญ่เกิน 5MB'),
                backgroundColor: AppColors.error,
              ),
            );
          }
          return;
        }

        final base64 = base64Encode(bytes);

        setState(() {
          switch (type) {
            case 'front':
              _idCardFrontBase64 = base64;
              _idCardFrontName = result.files.single.name;
              break;
            case 'back':
              _idCardBackBase64 = base64;
              _idCardBackName = result.files.single.name;
              break;
            case 'selfie':
              _selfieBase64 = base64;
              _selfieName = result.files.single.name;
              break;
          }
        });

        SoundService().play(SfxType.coin);
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      debugPrint('KYC pickImage error: $e');
    }
  }

  Future<void> _selectBirthDate() async {
    SoundService().play(SfxType.tap);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2000, 1, 1),
      firstDate: DateTime(1930),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.primary,
              surface: AppColors.surface,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() => _birthDate = picked);
      HapticFeedback.selectionClick();
    }
  }

  Future<void> _submit() async {
    // Validation
    if (_nameController.text.trim().isEmpty) {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาใส่ชื่อ-นามสกุล')),
      );
      return;
    }

    if (_birthDate == null) {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาเลือกวันเกิด')),
      );
      return;
    }

    // Check age >= 18
    final age = DateTime.now().difference(_birthDate!).inDays ~/ 365;
    if (age < 18) {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ต้องมีอายุ 18 ปีขึ้นไป'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    if (_idCardFrontBase64 == null) {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาอัพโหลดรูปบัตรประชาชน (ด้านหน้า)')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final success = await widget.torrentService.submitKyc(
      displayName: _nameController.text.trim(),
      idCardFrontBase64: _idCardFrontBase64!,
      birthDate: _birthDate!.toIso8601String().split('T')[0],
      idCardBackBase64: _idCardBackBase64,
      selfieBase64: _selfieBase64,
    );

    if (!mounted) return;

    setState(() => _isSubmitting = false);

    if (success) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ส่งข้อมูลยืนยันตัวตนแล้ว รอการอนุมัติ'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context);
    } else {
      SoundService().play(SfxType.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(widget.torrentService.error ?? 'เกิดข้อผิดพลาด'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.backgroundGradient),
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
                      _buildWarningCard(),
                      const SizedBox(height: 16),
                      _buildNameField(),
                      const SizedBox(height: 16),
                      _buildBirthDateField(),
                      const SizedBox(height: 16),
                      _buildImageUpload(
                        'บัตรประชาชน (ด้านหน้า) *',
                        Icons.badge,
                        _idCardFrontName,
                        () => _pickImage('front'),
                      ),
                      const SizedBox(height: 12),
                      _buildImageUpload(
                        'บัตรประชาชน (ด้านหลัง)',
                        Icons.badge,
                        _idCardBackName,
                        () => _pickImage('back'),
                      ),
                      const SizedBox(height: 12),
                      _buildImageUpload(
                        'เซลฟี่ถือบัตร',
                        Icons.face,
                        _selfieName,
                        () => _pickImage('selfie'),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: NeonButton(
                          text: 'ส่งข้อมูลยืนยันตัวตน',
                          icon: Icons.send,
                          isLoading: _isSubmitting,
                          onPressed: _isSubmitting ? null : _submit,
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 400.ms, delay: 400.ms),
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
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios,
                color: AppColors.primary, size: 20),
            onPressed: () {
              SoundService().play(SfxType.swoosh);
              Navigator.pop(context);
            },
          ),
          const SizedBox(width: 4),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: AppColors.primary.withValues(alpha: 0.1),
            ),
            child: const Icon(Icons.verified_user,
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'ยืนยันตัวตน (KYC)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    ).animate().slideY(begin: -0.3, end: 0, duration: 400.ms);
  }

  Widget _buildWarningCard() {
    return GlassCard(
      borderColor: AppColors.warning.withValues(alpha: 0.3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            color: AppColors.warning,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'ข้อมูลส่วนตัวจะถูกเก็บเป็นความลับ',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warning,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'ใช้เพื่อยืนยันอายุเท่านั้น จะไม่ถูกเผยแพร่ ต้องมีอายุ 18 ปีขึ้นไป แอดมินจะตรวจสอบและอนุมัติ',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 100.ms);
  }

  Widget _buildNameField() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ชื่อ-นามสกุล *',
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
            decoration: const InputDecoration(
              hintText: 'ชื่อจริง นามสกุล',
              prefixIcon:
                  Icon(Icons.person, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 150.ms);
  }

  Widget _buildBirthDateField() {
    return GlassCard(
      onTap: _selectBirthDate,
      child: Row(
        children: [
          const Icon(Icons.calendar_today,
              color: AppColors.textMuted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'วันเกิด *',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _birthDate != null
                      ? '${_birthDate!.day}/${_birthDate!.month}/${_birthDate!.year}'
                      : 'เลือกวันเกิด',
                  style: TextStyle(
                    fontSize: 13,
                    color: _birthDate != null
                        ? AppColors.textSecondary
                        : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_drop_down,
              color: AppColors.textMuted),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 200.ms);
  }

  Widget _buildImageUpload(
    String label,
    IconData icon,
    String? fileName,
    VoidCallback onTap,
  ) {
    final hasFile = fileName != null;

    return GlassCard(
      onTap: onTap,
      borderColor: hasFile
          ? AppColors.success.withValues(alpha: 0.3)
          : null,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: hasFile
                  ? AppColors.success.withValues(alpha: 0.1)
                  : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              hasFile ? Icons.check_circle : icon,
              color: hasFile ? AppColors.success : AppColors.textMuted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  hasFile ? fileName : 'แตะเพื่อเลือกรูป',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasFile
                        ? AppColors.success
                        : AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(
            hasFile ? Icons.edit : Icons.add_photo_alternate,
            color: AppColors.primary,
            size: 20,
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 250.ms);
  }
}
