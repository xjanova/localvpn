import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/neon_button.dart';

/// Top-level function for compute isolate
String _hashFileInIsolate(String filePath) {
  final bytes = File(filePath).readAsBytesSync();
  return sha256.convert(bytes).toString();
}

class UploadFileScreen extends StatefulWidget {
  final TorrentService torrentService;
  final List<BtCategory> categories;
  final BtCategory? initialCategory;

  const UploadFileScreen({
    super.key,
    required this.torrentService,
    required this.categories,
    this.initialCategory,
  });

  @override
  State<UploadFileScreen> createState() => _UploadFileScreenState();
}

class _UploadFileScreenState extends State<UploadFileScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  BtCategory? _selectedCategory;
  PlatformFile? _pickedFile;
  String? _fileHash;
  bool _isHashing = false;
  bool _isUploading = false;

  late final List<BtCategory> _availableCategories;

  @override
  void initState() {
    super.initState();
    final kycApproved = widget.torrentService.kycStatus == 'approved';
    _availableCategories = widget.categories
        .where((c) => !c.isAdult || kycApproved)
        .toList();
    if (widget.initialCategory != null) {
      final match = _availableCategories
          .where((c) => c.slug == widget.initialCategory!.slug)
          .toList();
      if (match.isNotEmpty) {
        _selectedCategory = match.first;
      }
    }
    if (_selectedCategory == null && _availableCategories.isNotEmpty) {
      _selectedCategory = _availableCategories.first;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ไม่สามารถเข้าถึงไฟล์ได้'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }

      setState(() {
        _pickedFile = file;
        _fileHash = null;
      });

      SoundService().play(SfxType.tap);
      HapticFeedback.lightImpact();

      await _computeHash(file.path!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('เลือกไฟล์ล้มเหลว: ${e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '')}'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _computeHash(String filePath) async {
    setState(() => _isHashing = true);

    try {
      // Use compute isolate to avoid blocking UI for large files
      final hash = await compute(_hashFileInIsolate, filePath);

      if (!mounted) return;
      setState(() {
        _fileHash = hash;
        _isHashing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isHashing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('คำนวณ hash ล้มเหลว: ${e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '')}'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _upload() async {
    if (_pickedFile == null || _fileHash == null || _selectedCategory == null) {
      return;
    }
    if (_isUploading) return;

    setState(() => _isUploading = true);
    SoundService().play(SfxType.tapHeavy);
    HapticFeedback.mediumImpact();

    try {
      final title = _titleController.text.trim().isEmpty
          ? null
          : _titleController.text.trim();
      final description = _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim();

      final result = await widget.torrentService.uploadFile(
        categorySlug: _selectedCategory!.slug,
        fileHash: _fileHash!,
        fileName: _pickedFile!.name,
        fileSize: _pickedFile!.size,
        title: title,
        description: description,
      );

      if (!mounted) return;

      if (result != null) {
        SoundService().play(SfxType.success);
        HapticFeedback.heavyImpact();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('อัพโหลดสำเร็จ!'),
            backgroundColor: AppColors.success,
          ),
        );

        Navigator.of(context).pop(result);
      } else {
        final errorMsg = widget.torrentService.error ?? 'อัพโหลดล้มเหลว';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg.replaceFirst(RegExp(r'^Exception:\s*'), '')),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('อัพโหลดล้มเหลว: ${e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '')}'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  bool get _canUpload =>
      _pickedFile != null &&
      _fileHash != null &&
      !_isHashing &&
      !_isUploading &&
      _selectedCategory != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.primary),
          onPressed: () {
            SoundService().play(SfxType.tap);
            Navigator.of(context).pop();
          },
        ),
        title: const Text(
          'อัพโหลดไฟล์',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFilePickerCard(),
              const SizedBox(height: 16),
              _buildTitleField(),
              const SizedBox(height: 16),
              _buildCategorySelector(),
              const SizedBox(height: 16),
              _buildDescriptionField(),
              const SizedBox(height: 32),
              _buildUploadButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilePickerCard() {
    return GlassCard(
      onTap: _isUploading ? null : _pickFile,
      padding: const EdgeInsets.all(20),
      child: _pickedFile == null
          ? _buildEmptyFilePicker()
          : _buildSelectedFileInfo(),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _buildEmptyFilePicker() {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
            ),
          ),
          child: const Icon(
            Icons.cloud_upload_outlined,
            color: AppColors.primary,
            size: 32,
          ),
        )
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .moveY(begin: 0, end: -6, duration: 2000.ms),
        const SizedBox(height: 16),
        const Text(
          'แตะเพื่อเลือกไฟล์',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'รองรับทุกประเภทไฟล์',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedFileInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.insert_drive_file,
                color: AppColors.success,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _pickedFile!.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatFileSize(_pickedFile!.size),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.swap_horiz, color: AppColors.primary),
              tooltip: 'เปลี่ยนไฟล์',
              onPressed: _isUploading ? null : _pickFile,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.background.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.cardBorder,
            ),
          ),
          child: Row(
            children: [
              Icon(
                _isHashing ? Icons.hourglass_top : Icons.fingerprint,
                color: _isHashing ? AppColors.warning : AppColors.primary,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _isHashing
                    ? const Text(
                        'กำลังคำนวณ SHA-256 hash...',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.warning,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    : Text(
                        _fileHash ?? '',
                        style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (_isHashing)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.warning,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTitleField() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.title, color: AppColors.primary, size: 18),
              SizedBox(width: 8),
              Text(
                'ชื่องาน',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(width: 6),
              Text(
                '(ไม่จำเป็น)',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            enabled: !_isUploading,
            maxLines: 1,
            maxLength: 255,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'ตั้งชื่องานสำหรับแสดงผล (ถ้าไม่กรอก จะใช้ชื่อไฟล์)',
              hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
              filled: true,
              fillColor: AppColors.background.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.cardBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 2),
              ),
              counterStyle: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 50.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _buildCategorySelector() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.category, color: AppColors.primary, size: 18),
              SizedBox(width: 8),
              Text(
                'หมวดหมู่',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<BtCategory>(
                value: _selectedCategory,
                isExpanded: true,
                dropdownColor: AppColors.surface,
                icon: const Icon(Icons.expand_more, color: AppColors.primary),
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
                items: _availableCategories.map((cat) {
                  return DropdownMenuItem<BtCategory>(
                    value: cat,
                    child: Row(
                      children: [
                        Icon(
                          _getCategoryIcon(cat.icon),
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Text(cat.name),
                        if (cat.isAdult) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '18+',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: AppColors.error,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
                onChanged: _isUploading
                    ? null
                    : (cat) {
                        SoundService().play(SfxType.tap);
                        setState(() => _selectedCategory = cat);
                      },
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 150.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _buildDescriptionField() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.description, color: AppColors.primary, size: 18),
              SizedBox(width: 8),
              Text(
                'คำอธิบาย',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(width: 6),
              Text(
                '(ไม่จำเป็น)',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            enabled: !_isUploading,
            maxLines: 3,
            maxLength: 500,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'รายละเอียดเกี่ยวกับไฟล์...',
              hintStyle: const TextStyle(color: AppColors.textMuted),
              filled: true,
              fillColor: AppColors.background.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.cardBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.primary, width: 2),
              ),
              counterStyle: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms, delay: 250.ms).slideY(begin: 0.1, end: 0);
  }

  Widget _buildUploadButton() {
    return NeonButton(
      text: 'อัพโหลด',
      icon: Icons.cloud_upload,
      color: AppColors.success,
      isLoading: _isUploading,
      onPressed: _canUpload ? _upload : null,
      width: double.infinity,
    ).animate().fadeIn(duration: 400.ms, delay: 350.ms).slideY(begin: 0.1, end: 0);
  }

  IconData _getCategoryIcon(String iconName) {
    switch (iconName) {
      case 'movie':
        return Icons.movie;
      case 'music_note':
        return Icons.music_note;
      case 'sports_esports':
        return Icons.sports_esports;
      case 'apps':
        return Icons.apps;
      case 'menu_book':
        return Icons.menu_book;
      case 'image':
        return Icons.image;
      case 'computer':
        return Icons.computer;
      case 'school':
        return Icons.school;
      case 'folder':
        return Icons.folder;
      case '18_up_rating':
        return Icons.eighteen_up_rating;
      default:
        return Icons.folder;
    }
  }
}
