import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/bt_models.dart';
import '../../platform/platform_info.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';
import 'category_files_screen.dart';
import 'file_detail_screen.dart';
import 'kyc_verification_screen.dart';

/// SHA-256 of a file, read 1 MB at a time so a large file never has to fit
/// in memory. Runs in a background isolate (see [compute]).
String _hashFileInIsolate(String filePath) {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  final raf = File(filePath).openSync();
  try {
    final buf = Uint8List(1 << 20);
    while (true) {
      final n = raf.readIntoSync(buf);
      if (n <= 0) break;
      input.add(n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
    }
  } finally {
    raf.closeSync();
  }
  input.close();
  return sink.value.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

/// Share a file with the community, in three steps: pick the file (hashed
/// in the background), name + category, description. On success the page
/// shows a result card; it pops with the uploaded [BtFile].
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

  late List<BtCategory> _allCategories;
  BtCategory? _selectedCategory;

  PlatformFile? _pickedFile;
  String? _fileHash;
  bool _isHashing = false;
  bool _hashFailed = false;
  int _hashGen = 0;

  bool _isPicking = false;
  bool _isUploading = false;
  bool _reloadingCategories = false;
  BtFile? _uploaded;
  String? _saveDir;

  TorrentService get t => widget.torrentService;

  bool get _kycApproved => t.kycStatus == 'approved';

  List<BtCategory> get _availableCategories =>
      _allCategories.where((c) => !c.isAdult || _kycApproved).toList();

  bool get _hasHiddenAdult =>
      !_kycApproved && _allCategories.any((c) => c.isAdult);

  /// The chosen category if it is still allowed, otherwise the first one.
  BtCategory? get _category {
    final available = _availableCategories;
    if (available.isEmpty) return null;
    final want = _selectedCategory?.slug;
    for (final c in available) {
      if (c.slug == want) return c;
    }
    return available.first;
  }

  bool get _dirty =>
      _uploaded == null &&
      (_pickedFile != null ||
          _titleController.text.trim().isNotEmpty ||
          _descriptionController.text.trim().isNotEmpty);

  bool get _canUpload =>
      _pickedFile != null &&
      _fileHash != null &&
      !_isHashing &&
      !_isUploading &&
      _category != null;

  @override
  void initState() {
    super.initState();
    _allCategories =
        widget.categories.isNotEmpty ? widget.categories : t.categories;
    _selectedCategory = widget.initialCategory;
    t.addListener(_onChanged);
    _resolveSaveDir();
  }

  @override
  void dispose() {
    _hashGen++;
    t.removeListener(_onChanged);
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolveSaveDir() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _saveDir = '${d.path}/LocalVPN/Torrent');
    } catch (_) {}
  }

  String get _torrentDirLabel {
    final dir = _saveDir;
    if (dir == null) {
      return isWindows ? r'Documents\LocalVPN\Torrent' : 'LocalVPN/Torrent';
    }
    return isWindows ? dir.replaceAll('/', r'\') : dir;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ── File ──────────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    if (_isPicking || _isUploading) return;
    setState(() => _isPicking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        withReadStream: false,
      );
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) {
        m3Toast(context, 'ไม่สามารถเข้าถึงไฟล์ได้', tone: M3Tone.red);
        return;
      }

      setState(() {
        _pickedFile = file;
        _fileHash = null;
        _hashFailed = false;
      });
      SoundService().play(SfxType.tap);
      HapticFeedback.lightImpact();
      _computeHash(file.path!);
    } catch (_) {
      if (!mounted) return;
      m3Toast(context, 'เลือกไฟล์ไม่สำเร็จ ลองใหม่อีกครั้ง', tone: M3Tone.red);
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _computeHash(String filePath) async {
    final gen = ++_hashGen;
    setState(() {
      _isHashing = true;
      _hashFailed = false;
    });
    try {
      final hash = await compute(_hashFileInIsolate, filePath);
      if (!mounted || gen != _hashGen) return;
      setState(() {
        _fileHash = hash;
        _isHashing = false;
      });
    } catch (_) {
      if (!mounted || gen != _hashGen) return;
      setState(() {
        _isHashing = false;
        _hashFailed = true;
      });
      m3Toast(
        context,
        'คำนวณ hash ไม่สำเร็จ — ตรวจสอบว่าไฟล์ไม่ได้ถูกโปรแกรมอื่นใช้อยู่ แล้วลองใหม่',
        tone: M3Tone.red,
      );
    }
  }

  // ── Upload ────────────────────────────────────────────────────────────

  Future<void> _upload() async {
    final file = _pickedFile;
    final hash = _fileHash;
    final category = _category;
    if (file == null || hash == null || category == null) return;
    if (_isUploading) return;

    setState(() => _isUploading = true);
    SoundService().play(SfxType.tapHeavy);
    HapticFeedback.mediumImpact();

    try {
      final title = _titleController.text.trim();
      final description = _descriptionController.text.trim();

      final result = await t.uploadFile(
        categorySlug: category.slug,
        fileHash: hash,
        fileName: file.name,
        fileSize: file.size,
        title: title.isEmpty ? null : title,
        description: description.isEmpty ? null : description,
        localPath: file.path,
      );
      if (!mounted) return;

      if (result != null) {
        SoundService().play(SfxType.success);
        HapticFeedback.heavyImpact();
        m3Toast(context, 'อัพโหลดสำเร็จ!', tone: M3Tone.green);
        setState(() => _uploaded = result);
      } else {
        final msg = (t.error ?? 'อัพโหลดล้มเหลว ลองใหม่อีกครั้ง')
            .replaceFirst(RegExp(r'^\w*Exception:\s*'), '');
        m3Toast(context, msg, tone: M3Tone.red);
      }
    } catch (_) {
      if (!mounted) return;
      m3Toast(context, 'อัพโหลดล้มเหลว ลองใหม่อีกครั้ง', tone: M3Tone.red);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _reset() {
    _hashGen++;
    _titleController.clear();
    _descriptionController.clear();
    setState(() {
      _pickedFile = null;
      _fileHash = null;
      _isHashing = false;
      _hashFailed = false;
      _uploaded = null;
    });
  }

  Future<void> _leave() async {
    if (_dirty) {
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.upload,
        title: 'ออกจากหน้าอัพโหลด?',
        message: _isUploading
            ? 'กำลังส่งข้อมูลอยู่ — ถ้าออกตอนนี้จะไม่เห็นผลการอัพโหลด'
            : 'ไฟล์ที่เลือกและข้อมูลที่กรอกไว้จะหายไป',
        confirmLabel: 'ออก',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    Navigator.of(context).pop(_uploaded);
  }

  Future<void> _reloadCategories() async {
    if (_reloadingCategories) return;
    setState(() => _reloadingCategories = true);
    await t.fetchCategories();
    if (!mounted) return;
    setState(() {
      _reloadingCategories = false;
      _allCategories = t.categories;
    });
  }

  Future<void> _openKyc() async {
    await Navigator.of(context).push(
      M3PageRoute(builder: (_) => KycVerificationScreen(torrentService: t)),
    );
    if (!mounted) return;
    await t.fetchKycStatus();
    if (mounted) setState(() {});
  }

  Future<void> _openTorrentFolder() async {
    final dir = _saveDir;
    if (dir == null) return;
    try {
      await Directory(dir).create(recursive: true);
      final r = await OpenFile.open(_torrentDirLabel);
      if (!mounted) return;
      if (r.type != ResultType.done) {
        m3Toast(context, 'เปิดโฟลเดอร์ไม่ได้', tone: M3Tone.amber);
      }
    } catch (_) {
      if (mounted) m3Toast(context, 'เปิดโฟลเดอร์ไม่ได้', tone: M3Tone.red);
    }
  }

  void _openUploadedFile(BtFile f) {
    Navigator.of(context).push(
      M3PageRoute(
        builder: (_) => FileDetailScreen(
          torrentService: t,
          fileId: f.id,
          initialFile: f,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: M3PageBody(
        children: [
          M3PageHeader(
            icon3d: M3Icons.upload,
            title: 'อัพโหลดไฟล์',
            subtitle: 'แชร์ไฟล์ให้ชุมชน — เครื่องนี้จะเป็น Seeder ให้คนอื่นดาวน์โหลด',
            onBack: _leave,
          ),
          const SizedBox(height: 16),
          if (_uploaded != null)
            _successCard(_uploaded!)
                .animate()
                .fadeIn(duration: 320.ms)
                .slideY(begin: 0.04, end: 0)
          else ...[
            if (_hasHiddenAdult) ...[
              _kycBanner(),
              const SizedBox(height: 14),
            ],
            LayoutBuilder(builder: (context, c) {
              final steps = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _stepFile()
                      .animate()
                      .fadeIn(duration: 320.ms)
                      .slideY(begin: 0.04, end: 0),
                  const SizedBox(height: 14),
                  _stepDetails().animate().fadeIn(delay: 60.ms, duration: 300.ms),
                  const SizedBox(height: 14),
                  _stepDescription()
                      .animate()
                      .fadeIn(delay: 120.ms, duration: 300.ms),
                ],
              );
              final summary =
                  _summaryCard().animate().fadeIn(delay: 160.ms, duration: 300.ms);
              if (c.maxWidth >= 980) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: steps),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: summary),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [steps, const SizedBox(height: 16), summary],
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _kycBanner() {
    final pending = t.kycStatus == 'pending';
    return M3Banner(
      tone: M3Tone.amber,
      icon3d: M3Icons.kyc,
      title: 'หมวด 18+ ถูกซ่อนอยู่',
      message: pending
          ? 'เอกสารยืนยันตัวตนของคุณกำลังรอตรวจสอบ — เมื่อผ่านแล้วจะอัพโหลดในหมวด 18+ ได้'
          : 'ยืนยันตัวตน (KYC) ก่อน จึงจะอัพโหลดในหมวดสำหรับผู้ใหญ่ได้',
      action: pending
          ? null
          : GlossButton(
              label: 'ยืนยันตัวตน',
              size: GlossSize.small,
              variant: GlossVariant.gold,
              onPressed: _isUploading ? null : _openKyc,
            ),
    );
  }

  Widget _stepFile() {
    final p = context.m3;
    final file = _pickedFile;
    final busy = _isPicking || _isUploading;

    Widget body;
    if (file == null) {
      body = MouseRegion(
        cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: busy ? null : _pickFile,
          child: M3Inset(
            padding: EdgeInsets.zero,
            child: M3EmptyState(
              icon3d: M3Icons.upload,
              title: isMobile ? 'แตะเพื่อเลือกไฟล์' : 'คลิกเพื่อเลือกไฟล์',
              message: 'รองรับทุกประเภทไฟล์',
              action: GlossButton(
                label: 'เลือกไฟล์',
                icon3d: M3Icons.folder,
                loading: _isPicking,
                onPressed: busy ? null : _pickFile,
              ),
            ),
          ),
        ),
      );
    } else {
      Widget hashRow;
      if (_isHashing) {
        hashRow = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.fingerprint_rounded, size: 16, color: p.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('กำลังคำนวณ SHA-256 hash…',
                      style: M3Text.sub(context).copyWith(color: p.amber)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const M3ProgressBar(height: 8, tone: M3Tone.amber),
          ],
        );
      } else if (_fileHash != null) {
        hashRow = Row(
          children: [
            Icon(Icons.fingerprint_rounded, size: 16, color: p.cyan),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _fileHash!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: M3Text.mono(context, size: 11.5, color: p.text2),
              ),
            ),
            const SizedBox(width: 8),
            const M3Tag('ตรวจสอบแล้ว',
                tone: M3Tone.green, icon: Icons.check_rounded),
          ],
        );
      } else {
        hashRow = Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: p.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _hashFailed ? 'คำนวณ hash ไม่สำเร็จ' : 'ยังไม่ได้คำนวณ hash',
                style: M3Text.sub(context).copyWith(color: p.red),
              ),
            ),
            GlossButton(
              label: 'ลองใหม่',
              icon: Icons.refresh_rounded,
              size: GlossSize.small,
              variant: GlossVariant.glass,
              onPressed:
                  busy || file.path == null ? null : () => _computeHash(file.path!),
            ),
          ],
        );
      }

      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon3D(M3Icons.file, size: 54),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: M3Text.h3(context)),
                    const SizedBox(height: 2),
                    Text(_formatFileSize(file.size),
                        style: M3Text.sub(context)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              GlossButton(
                label: 'เปลี่ยนไฟล์',
                icon: Icons.swap_horiz_rounded,
                size: GlossSize.small,
                variant: GlossVariant.glass,
                loading: _isPicking,
                onPressed: busy ? null : _pickFile,
              ),
            ],
          ),
          const SizedBox(height: 12),
          M3Inset(child: hashRow),
        ],
      );
    }

    return _StepCard(
      step: 1,
      title: 'เลือกไฟล์',
      subtitle: 'ไฟล์จะถูกตรวจ SHA-256 เพื่อให้คนดาวน์โหลดได้ไฟล์ที่ถูกต้อง',
      done: _fileHash != null,
      hero: true,
      child: body,
    );
  }

  Widget _stepDetails() {
    final available = _availableCategories;
    final selected = _category;

    return _StepCard(
      step: 2,
      title: 'ชื่องานและหมวดหมู่',
      done: selected != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3Field(
            controller: _titleController,
            label: 'ชื่องาน (ไม่จำเป็น)',
            hint: 'ตั้งชื่องานสำหรับแสดงผล (ถ้าไม่กรอก จะใช้ชื่อไฟล์)',
            prefixIcon: Icons.title_rounded,
            maxLength: 255,
            enabled: !_isUploading,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text('หมวดหมู่', style: M3Text.label(context)),
          ),
          if (available.isEmpty)
            M3Inset(
              child: Row(
                children: [
                  const Icon3D(M3Icons.folder, size: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('ยังไม่มีหมวดหมู่ให้เลือก',
                        style: M3Text.sub(context)),
                  ),
                  GlossButton(
                    label: 'โหลดใหม่',
                    icon: Icons.refresh_rounded,
                    size: GlossSize.small,
                    variant: GlossVariant.glass,
                    loading: _reloadingCategories,
                    onPressed:
                        _reloadingCategories ? null : _reloadCategories,
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in available)
                  M3Chip(
                    label: c.isAdult ? '${c.name} · 18+' : c.name,
                    icon: torrentCategoryGlyph(c.icon),
                    selected: selected?.slug == c.slug,
                    onTap: _isUploading
                        ? null
                        : () => setState(() => _selectedCategory = c),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _stepDescription() {
    final len = _descriptionController.text.characters.length;
    return _StepCard(
      step: 3,
      title: 'คำอธิบาย',
      subtitle: 'ไม่จำเป็น — บอกว่าไฟล์นี้คืออะไร เวอร์ชันไหน ใช้งานอย่างไร',
      done: len > 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3Field(
            controller: _descriptionController,
            hint: 'รายละเอียดเกี่ยวกับไฟล์...',
            maxLines: 4,
            maxLength: 500,
            enabled: !_isUploading,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          Text('$len/500',
              textAlign: TextAlign.right,
              style: M3Text.sub(context).copyWith(fontSize: 11.5)),
        ],
      ),
    );
  }

  String get _blockReason {
    if (_pickedFile == null) return 'เลือกไฟล์ก่อน';
    if (_isHashing) return 'รอคำนวณ hash ให้เสร็จก่อน';
    if (_fileHash == null) return 'คำนวณ hash ไม่สำเร็จ — กด "ลองใหม่" ที่ขั้นที่ 1';
    if (_category == null) return 'เลือกหมวดหมู่ก่อน';
    return '';
  }

  Widget _summaryCard() {
    final p = context.m3;
    final file = _pickedFile;
    final title = _titleController.text.trim();
    final hash = _fileHash;

    return GlassPanel(
      accent: _canUpload ? p.cyan.withValues(alpha: 0.8) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.upload,
            title: 'สรุปก่อนอัพโหลด',
          ),
          const SizedBox(height: 12),
          M3KeyValue('ไฟล์', file?.name ?? '—'),
          M3KeyValue(
              'ขนาด', file == null ? '—' : _formatFileSize(file.size)),
          M3KeyValue('หมวดหมู่', _category?.name ?? '—'),
          M3KeyValue('ชื่องาน', title.isEmpty ? 'ใช้ชื่อไฟล์' : title),
          M3KeyValue(
            'SHA-256',
            _isHashing
                ? 'กำลังคำนวณ…'
                : (hash == null ? '—' : '${hash.substring(0, 12)}…'),
            mono: hash != null,
          ),
          const SizedBox(height: 16),
          if (_isUploading) ...[
            const M3ProgressBar(),
            const SizedBox(height: 6),
            Text('กำลังส่งข้อมูลไฟล์ขึ้นเซิร์ฟเวอร์…',
                style: M3Text.sub(context)),
            const SizedBox(height: 12),
          ],
          GlossButton(
            label: 'อัพโหลด',
            icon3d: M3Icons.upload,
            size: GlossSize.large,
            expand: true,
            loading: _isUploading,
            onPressed: _canUpload ? _upload : null,
          ),
          if (!_canUpload && !_isUploading) ...[
            const SizedBox(height: 8),
            Text(_blockReason,
                textAlign: TextAlign.center,
                style: M3Text.sub(context).copyWith(fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Text(
            'เมื่ออัพโหลดแล้ว เครื่องนี้จะถูกลงทะเบียนเป็น Seeder ของไฟล์โดยอัตโนมัติ',
            style: M3Text.sub(context).copyWith(fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _successCard(BtFile f) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 600;

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: p.green,
      padding: EdgeInsets.all(narrow ? 18 : 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Icon3D(M3Icons.upload,
                    size: narrow ? 92 : 116,
                    glow: p.green.withValues(alpha: 0.45))
                .animate()
                .scale(
                    begin: const Offset(0.85, 0.85),
                    end: const Offset(1, 1),
                    duration: 350.ms,
                    curve: Curves.easeOutBack),
          ),
          const SizedBox(height: 12),
          Text(
            'อัพโหลดสำเร็จ!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: M3Fonts.head,
              fontSize: narrow ? 24 : 28,
              fontWeight: FontWeight.w700,
              color: p.green,
              shadows: p.titleShadow,
            ),
          ),
          const SizedBox(height: 4),
          Text(f.displayTitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: M3Text.h2(context)),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              M3Tag(f.fileSizeFormatted,
                  tone: M3Tone.neutral, icon: Icons.storage_rounded),
              if (f.category != null)
                M3Tag(f.category!.name, tone: M3Tone.gold),
              const M3Tag('เครื่องนี้เป็น Seeder แล้ว',
                  tone: M3Tone.green, dot: true),
            ],
          ),
          const SizedBox(height: 18),
          M3Inset(
            child: Row(
              children: [
                const Icon3D(M3Icons.folder, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ให้คนอื่นดาวน์โหลดผ่านเครื่องคุณ',
                          style: M3Text.h3(context)),
                      const SizedBox(height: 2),
                      Text(
                        'เครื่องอื่นจะขอชิ้นส่วนไฟล์จากไฟล์ต้นฉบับด้านล่างของเครื่องนี้ '
                        'อย่าย้ายหรือลบไฟล์ และเปิดแอปค้างไว้ระหว่างแชร์',
                        style: M3Text.sub(context),
                      ),
                      const SizedBox(height: 4),
                      Text(_pickedFile?.path ?? _torrentDirLabel,
                          style: M3Text.mono(context, size: 12, color: p.text2)),
                    ],
                  ),
                ),
                if (isDesktop && _saveDir != null) ...[
                  const SizedBox(width: 10),
                  GlossButton(
                    label: 'เปิดโฟลเดอร์',
                    icon: Icons.folder_open_rounded,
                    size: GlossSize.small,
                    variant: GlossVariant.glass,
                    onPressed: _openTorrentFolder,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              GlossButton(
                label: 'ดูหน้าไฟล์',
                icon3d: M3Icons.file,
                variant: GlossVariant.glass,
                onPressed: () => _openUploadedFile(f),
              ),
              GlossButton(
                label: 'อัพโหลดไฟล์อื่น',
                icon: Icons.add_rounded,
                variant: GlossVariant.glass,
                onPressed: _reset,
              ),
              GlossButton(
                label: 'เสร็จสิ้น',
                icon: Icons.check_rounded,
                onPressed: () => Navigator.of(context).pop(f),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Step card ───────────────────────────────────────────────────────────

class _StepCard extends StatelessWidget {
  final int step;
  final String title;
  final String? subtitle;
  final bool done;
  final bool hero;
  final Widget child;

  const _StepCard({
    required this.step,
    required this.title,
    required this.child,
    this.subtitle,
    this.done = false,
    this.hero = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      highlight: hero,
      gloss: !hero,
      radius: hero ? 24 : 20,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StepBadge(step: step, done: done),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: M3Text.h2(context)),
                    if (subtitle != null)
                      Text(subtitle!, style: M3Text.sub(context)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  final int step;
  final bool done;

  const _StepBadge({required this.step, required this.done});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: done ? M3Fx.greenGloss : M3Fx.aquaGloss,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: done ? M3Fx.greenEdge : M3Fx.aquaEdge),
      ),
      child: done
          ? const Icon(Icons.check_rounded, size: 18, color: M3Fx.greenText)
          : Text(
              '$step',
              style: const TextStyle(
                fontFamily: M3Fonts.head,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: M3Fx.aquaText,
                height: 1,
              ),
            ),
    );
  }
}
