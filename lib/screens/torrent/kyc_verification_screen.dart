import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';

/// "ยืนยันตัวตน (KYC)" — age verification for 18+ categories in three
/// steps: personal info, ID documents (picked from files — works on phones
/// and Windows), then review and submit.
class KycVerificationScreen extends StatefulWidget {
  final TorrentService torrentService;

  const KycVerificationScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<KycVerificationScreen> createState() => _KycVerificationScreenState();
}

/// Max size per image (same limit as before).
const int _maxBytes = 5 * 1024 * 1024;

enum _Doc {
  front('บัตรประชาชน (ด้านหน้า)', true, M3Icons.kyc),
  back('บัตรประชาชน (ด้านหลัง)', false, M3Icons.kyc),
  selfie('เซลฟี่ถือบัตร', false, M3Icons.profile);

  final String label;
  final bool required;
  final String icon3d;

  const _Doc(this.label, this.required, this.icon3d);
}

class _PickedImage {
  final Uint8List bytes;
  final String name;

  const _PickedImage(this.bytes, this.name);
}

enum _StepState { todo, current, done }

class _KycVerificationScreenState extends State<KycVerificationScreen> {
  TorrentService get t => widget.torrentService;

  final TextEditingController _nameController = TextEditingController();
  DateTime? _birthDate;
  final Map<_Doc, _PickedImage> _docs = {};
  _Doc? _picking;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    t.addListener(_onChanged);
    // For the status banner (pending / approved / rejected).
    t.fetchKycStatus();
  }

  @override
  void dispose() {
    t.removeListener(_onChanged);
    _nameController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ── State helpers ──

  static int _age(DateTime b) {
    final now = DateTime.now();
    var age = now.year - b.year;
    if (now.month < b.month || (now.month == b.month && now.day < b.day)) {
      age--;
    }
    return age;
  }

  static String _fmtDate(DateTime d) => '${d.day}/${d.month}/${d.year}';

  bool get _nameOk => _nameController.text.trim().isNotEmpty;
  bool get _ageOk => _birthDate != null && _age(_birthDate!) >= 18;
  bool get _step1Done => _nameOk && _ageOk;
  bool get _step2Done => _docs.containsKey(_Doc.front);

  bool get _dirty =>
      _nameController.text.trim().isNotEmpty ||
      _birthDate != null ||
      _docs.isNotEmpty;

  /// Already submitted or approved — nothing to send.
  bool get _locked => t.kycStatus == 'approved' || t.kycStatus == 'pending';

  // ── Actions ──

  Future<void> _leave() async {
    if (_isSubmitting) {
      m3Toast(context, 'กำลังส่งข้อมูล รอสักครู่…', tone: M3Tone.amber);
      return;
    }
    if (_dirty && !_locked) {
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.kyc,
        title: 'ออกจากหน้านี้?',
        message: 'ข้อมูลและรูปที่เลือกไว้ยังไม่ได้ส่ง และจะหายไปเมื่อออก',
        confirmLabel: 'ออก',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _pickImage(_Doc doc) async {
    if (_picking != null || _isSubmitting) return;
    setState(() => _picking = doc);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (!mounted || result == null || result.files.isEmpty) return;
      final f = result.files.single;

      // Limit file size to 5MB (checked before reading the file).
      if (f.size > _maxBytes) {
        SoundService().play(SfxType.error);
        m3Toast(context, 'ไฟล์ใหญ่เกิน 5MB', tone: M3Tone.red);
        return;
      }

      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null) {
        bytes = await File(f.path!).readAsBytes();
        if (!mounted) return;
      }
      final data = bytes;
      if (data == null || data.isEmpty) {
        m3Toast(context, 'อ่านไฟล์รูปไม่ได้ ลองเลือกไฟล์อื่น',
            tone: M3Tone.red);
        return;
      }
      if (data.length > _maxBytes) {
        SoundService().play(SfxType.error);
        m3Toast(context, 'ไฟล์ใหญ่เกิน 5MB', tone: M3Tone.red);
        return;
      }

      setState(() => _docs[doc] = _PickedImage(data, f.name));
      SoundService().play(SfxType.coin);
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('KYC pickImage error: $e');
      if (mounted) {
        m3Toast(context, 'เลือกรูปไม่สำเร็จ ลองอีกครั้ง', tone: M3Tone.red);
      }
    } finally {
      if (mounted) setState(() => _picking = null);
    }
  }

  Future<void> _removeImage(_Doc doc) async {
    final ok = await m3Confirm(
      context,
      icon3d: doc.icon3d,
      title: 'นำรูปนี้ออก?',
      message: 'รูป "${doc.label}" จะถูกนำออกจากแบบฟอร์ม (ยังไม่ได้ส่งให้ใคร)',
      confirmLabel: 'นำออก',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _docs.remove(doc));
  }

  Future<void> _selectBirthDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1930),
      lastDate: DateTime.now(),
      helpText: 'เลือกวันเกิด',
      cancelText: 'ยกเลิก',
      confirmText: 'ตกลง',
      fieldLabelText: 'วันเกิด',
      errorFormatText: 'รูปแบบวันที่ไม่ถูกต้อง',
      errorInvalidText: 'วันที่อยู่นอกช่วงที่เลือกได้',
      builder: (ctx, child) {
        final p = ctx.m3;
        return Theme(
          data: Theme.of(ctx).copyWith(
            datePickerTheme: DatePickerThemeData(
              backgroundColor: p.popup,
              surfaceTintColor: Colors.transparent,
              headerForegroundColor: p.text,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: p.popupLine),
              ),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _birthDate = picked);
    HapticFeedback.selectionClick();
  }

  void _fail(String message, {M3Tone tone = M3Tone.amber}) {
    SoundService().play(SfxType.error);
    m3Toast(context, message, tone: tone);
  }

  Future<void> _submit() async {
    if (_isSubmitting || _locked) return;
    FocusScope.of(context).unfocus();

    // Validation (same order and wording as before).
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _fail('กรุณาใส่ชื่อ-นามสกุล');
      return;
    }
    final birth = _birthDate;
    if (birth == null) {
      _fail('กรุณาเลือกวันเกิด');
      return;
    }
    if (_age(birth) < 18) {
      _fail('ต้องมีอายุ 18 ปีขึ้นไป', tone: M3Tone.red);
      return;
    }
    final front = _docs[_Doc.front];
    if (front == null) {
      _fail('กรุณาอัพโหลดรูปบัตรประชาชน (ด้านหน้า)');
      return;
    }
    final back = _docs[_Doc.back];
    final selfie = _docs[_Doc.selfie];

    setState(() => _isSubmitting = true);

    bool success;
    try {
      // Encode off the UI thread (up to 3 × 5 MB).
      final encoded = await Future.wait([
        compute(base64Encode, front.bytes),
        if (back != null) compute(base64Encode, back.bytes),
        if (selfie != null) compute(base64Encode, selfie.bytes),
      ]);
      var i = 1;
      success = await t.submitKyc(
        displayName: name,
        idCardFrontBase64: encoded[0],
        birthDate: birth.toIso8601String().split('T')[0],
        idCardBackBase64: back != null ? encoded[i++] : null,
        selfieBase64: selfie != null ? encoded[i++] : null,
      );
    } catch (e) {
      debugPrint('KYC submit error: $e');
      success = false;
    }

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (success) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();
      m3Toast(context, 'ส่งข้อมูลยืนยันตัวตนแล้ว รอการอนุมัติ',
          tone: M3Tone.green);
      Navigator.of(context).pop();
    } else {
      SoundService().play(SfxType.error);
      m3Toast(context, t.error ?? 'เกิดข้อผิดพลาด ลองอีกครั้ง',
          tone: M3Tone.red);
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final s1 = _step1Done;
    final s2 = _step2Done;
    final s3 = _locked;
    _StepState stateOf(int n) {
      final done = [s1, s2, s3][n - 1];
      if (done) return _StepState.done;
      final firstOpen = !s1 ? 1 : (!s2 ? 2 : 3);
      return n == firstOpen ? _StepState.current : _StepState.todo;
    }

    final step1 = _StepCard(
      number: 1,
      state: stateOf(1),
      title: 'ข้อมูลส่วนตัว',
      subtitle: 'ชื่อตามบัตรประชาชนและวันเกิด',
      child: _InfoStep(
        controller: _nameController,
        birthDate: _birthDate,
        enabled: !_isSubmitting,
        onNameChanged: () => setState(() {}),
        onPickDate: _selectBirthDate,
        age: _birthDate == null ? null : _age(_birthDate!),
        formatDate: _fmtDate,
      ),
    );
    final step2 = _StepCard(
      number: 2,
      state: stateOf(2),
      title: 'เอกสาร',
      subtitle: 'รูปบัตรประชาชนและเซลฟี่ ไม่เกิน 5MB ต่อรูป',
      child: _DocsStep(
        docs: _docs,
        picking: _picking,
        busy: _isSubmitting,
        onPick: _pickImage,
        onRemove: _removeImage,
      ),
    );
    final step3 = _StepCard(
      number: 3,
      state: stateOf(3),
      title: 'ตรวจสอบและส่ง',
      subtitle: 'แอดมินจะตรวจสอบและอนุมัติ',
      child: _SubmitStep(
        nameOk: _nameOk,
        ageOk: _ageOk,
        docs: _docs,
        status: t.kycStatus,
        submitting: _isSubmitting,
        onSubmit: (_locked || _isSubmitting || _picking != null)
            ? null
            : _submit,
      ),
    );

    return PopScope(
      // Honoured by maybePop (e.g. a nested navigator's back handling).
      canPop: !_dirty || _locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: M3PageBody(
        children: [
          M3PageHeader(
            icon3d: M3Icons.kyc,
            title: 'ยืนยันตัวตน (KYC)',
            subtitle: 'ยืนยันอายุ 18+ เพื่อเข้าถึงหมวดเนื้อหาสำหรับผู้ใหญ่',
            onBack: _leave,
          ),
          const SizedBox(height: 16),
          if (_statusBanner() case final banner?) ...[
            banner,
            const SizedBox(height: 14),
          ],
          _Hero(states: [stateOf(1), stateOf(2), stateOf(3)])
              .animate()
              .fadeIn(duration: 350.ms)
              .slideY(begin: 0.04, end: 0),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            if (c.maxWidth >= 900) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [step1, const SizedBox(height: 16), step2],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: step3),
                ],
              ).animate().fadeIn(delay: 80.ms, duration: 350.ms);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                step1,
                const SizedBox(height: 16),
                step2,
                const SizedBox(height: 16),
                step3,
              ],
            ).animate().fadeIn(delay: 80.ms, duration: 350.ms);
          }),
        ],
      ),
    );
  }

  Widget? _statusBanner() {
    switch (t.kycStatus) {
      case 'approved':
        return const M3Banner(
          tone: M3Tone.green,
          icon3d: M3Icons.kyc,
          title: 'ยืนยันตัวตนแล้ว',
          message: 'บัญชีนี้ผ่านการยืนยันอายุแล้ว ไม่ต้องส่งข้อมูลซ้ำ',
        );
      case 'pending':
        return const M3Banner(
          tone: M3Tone.amber,
          icon3d: M3Icons.kyc,
          title: 'รอการอนุมัติ',
          message: 'ส่งข้อมูลแล้ว รอแอดมินตรวจสอบและอนุมัติ',
        );
      case 'rejected':
        return const M3Banner(
          tone: M3Tone.red,
          icon3d: M3Icons.kyc,
          title: 'ถูกปฏิเสธ',
          message: 'ข้อมูลที่ส่งไปไม่ผ่านการตรวจสอบ '
              'ตรวจให้รูปชัดเจนและข้อมูลตรงกับบัตร แล้วส่งใหม่ได้',
        );
      default:
        return null;
    }
  }
}

// ── Hero ────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final List<_StepState> states;
  const _Hero({required this.states});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    const labels = ['ข้อมูล', 'เอกสาร', 'ส่ง'];

    final tracker = Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  gradient:
                      states[i - 1] == _StepState.done ? M3Fx.barGreen : null,
                  color: states[i - 1] == _StepState.done ? null : p.track,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StepBadge(number: i + 1, state: states[i], size: 36),
              const SizedBox(height: 5),
              Text(labels[i],
                  style: M3Text.sub(context).copyWith(
                      fontSize: 11.5,
                      color: states[i] == _StepState.todo ? p.text3 : p.text2)),
            ],
          ),
        ],
      ],
    );

    final privacy = M3Inset(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon3D(M3Icons.lock, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ข้อมูลส่วนตัวจะถูกเก็บเป็นความลับ',
                  style: M3Text.h3(context).copyWith(color: p.amberText),
                ),
                const SizedBox(height: 2),
                Text(
                  'ใช้เพื่อยืนยันอายุเท่านั้น จะไม่ถูกเผยแพร่ '
                  'ต้องมีอายุ 18 ปีขึ้นไป แอดมินจะตรวจสอบและอนุมัติ',
                  style: M3Text.sub(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ยืนยันอายุใน 3 ขั้นตอน',
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 21 : 27,
            fontWeight: FontWeight.w700,
            color: p.text,
            shadows: p.titleShadow,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'กรอกข้อมูล แนบรูปบัตร แล้วกดส่ง — รูปที่เลือกจะอยู่ในเครื่องจนกว่าจะกดส่ง',
          style: M3Text.sub(context).copyWith(fontSize: 13),
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: tracker,
        ),
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon3D(M3Icons.kyc,
                  size: narrow ? 76 : 112, glow: p.logoGlow),
              SizedBox(width: narrow ? 14 : 22),
              Expanded(child: text),
            ],
          ),
          const SizedBox(height: 16),
          privacy,
        ],
      ),
    );
  }
}

// ── Step scaffolding ────────────────────────────────────────────────────

class _StepBadge extends StatelessWidget {
  final int number;
  final _StepState state;
  final double size;

  const _StepBadge({
    required this.number,
    required this.state,
    this.size = 34,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final (LinearGradient fill, Color edge, Color fg) = switch (state) {
      _StepState.done => (M3Fx.greenGloss, M3Fx.greenEdge, M3Fx.greenText),
      _StepState.current => (M3Fx.aquaGloss, M3Fx.aquaEdge, M3Fx.aquaText),
      _StepState.todo => (
          p.glassBtn,
          p.isNight ? p.line : p.inputLine,
          p.glassBtnText
        ),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: fill,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: edge),
        boxShadow: state == _StepState.current ? M3Fx.aquaGlow : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                gradient: M3Fx.btnGloss,
                borderRadius: BorderRadius.circular(size * 0.28 - 1),
              ),
            ),
          ),
          if (state == _StepState.done)
            Icon(Icons.check_rounded, size: size * 0.55, color: fg)
          else
            Text(
              '$number',
              style: TextStyle(
                fontFamily: M3Fonts.head,
                fontSize: size * 0.48,
                fontWeight: FontWeight.w700,
                color: fg,
                height: 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int number;
  final _StepState state;
  final String title;
  final String subtitle;
  final Widget child;

  const _StepCard({
    required this.number,
    required this.state,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return GlassPanel(
      accent: state == _StepState.done
          ? p.green.withValues(alpha: 0.8)
          : state == _StepState.current
              ? p.cyan.withValues(alpha: 0.8)
              : null,
      padding: EdgeInsets.all(narrow ? 14 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StepBadge(number: number, state: state),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: M3Text.h2(context)),
                    Text(subtitle, style: M3Text.sub(context)),
                  ],
                ),
              ),
              if (state == _StepState.done)
                const M3Tag('ครบแล้ว', tone: M3Tone.green, dot: true),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// ── Step 1: info ────────────────────────────────────────────────────────

class _InfoStep extends StatelessWidget {
  final TextEditingController controller;
  final DateTime? birthDate;
  final int? age;
  final bool enabled;
  final VoidCallback onNameChanged;
  final VoidCallback onPickDate;
  final String Function(DateTime) formatDate;

  const _InfoStep({
    required this.controller,
    required this.birthDate,
    required this.age,
    required this.enabled,
    required this.onNameChanged,
    required this.onPickDate,
    required this.formatDate,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final under18 = age != null && age! < 18;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3Field(
          controller: controller,
          label: 'ชื่อ-นามสกุล *',
          hint: 'ชื่อจริง นามสกุล',
          prefixIcon: Icons.person_rounded,
          maxLength: 120,
          enabled: enabled,
          textInputAction: TextInputAction.done,
          onChanged: (_) => onNameChanged(),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Text('วันเกิด *', style: M3Text.label(context)),
        ),
        M3Row(
          onTap: enabled ? onPickDate : null,
          leading: Icon(Icons.calendar_month_rounded, color: p.text3, size: 22),
          title: birthDate != null ? formatDate(birthDate!) : 'เลือกวันเกิด',
          subtitleWidget: age == null
              ? Text('แตะเพื่อเลือกจากปฏิทิน', style: M3Text.sub(context))
              : Text(
                  under18
                      ? 'อายุ $age ปี · ต้องมีอายุ 18 ปีขึ้นไป'
                      : 'อายุ $age ปี',
                  style: M3Text.sub(context).copyWith(
                    color: under18 ? p.red : p.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
          trailing: Icon(Icons.arrow_drop_down_rounded, color: p.text3),
        ),
      ],
    );
  }
}

// ── Step 2: documents ───────────────────────────────────────────────────

class _DocsStep extends StatelessWidget {
  final Map<_Doc, _PickedImage> docs;
  final _Doc? picking;
  final bool busy;
  final void Function(_Doc) onPick;
  final void Function(_Doc) onRemove;

  const _DocsStep({
    required this.docs,
    required this.picking,
    required this.busy,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 600
          ? 3
          : c.maxWidth >= 400
              ? 2
              : 1;
      const gap = 12.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final d in _Doc.values)
            SizedBox(
              width: w,
              child: _DocTile(
                doc: d,
                image: docs[d],
                loading: picking == d,
                enabled: picking == null && !busy,
                onPick: () => onPick(d),
                onRemove: () => onRemove(d),
              ),
            ),
        ],
      );
    });
  }
}

class _DocTile extends StatefulWidget {
  final _Doc doc;
  final _PickedImage? image;
  final bool loading;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _DocTile({
    required this.doc,
    required this.image,
    required this.loading,
    required this.enabled,
    required this.onPick,
    required this.onRemove,
  });

  @override
  State<_DocTile> createState() => _DocTileState();
}

class _DocTileState extends State<_DocTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final img = widget.image;
    final has = img != null;

    final preview = AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: img != null
            ? Image.memory(
                img.bytes,
                fit: BoxFit.cover,
                cacheWidth: 720,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => _PreviewPlaceholder(
                  icon3d: widget.doc.icon3d,
                  text: 'แสดงตัวอย่างไม่ได้ แต่ยังส่งไฟล์นี้ได้',
                ),
              )
            : _PreviewPlaceholder(
                icon3d: widget.doc.icon3d,
                text: 'แตะเพื่อเลือกรูป',
                hover: _hover && widget.enabled,
              ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.inset,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: has ? p.greenSoftLine : p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.enabled ? widget.onPick : null,
              child: Semantics(
                button: true,
                label: 'เลือกรูป ${widget.doc.label}',
                child: preview,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.doc.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: M3Text.h3(context)),
                    const SizedBox(height: 2),
                    img != null
                        ? Text(img.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: M3Text.sub(context)
                                .copyWith(fontSize: 11.5, color: p.green))
                        : M3Tag(widget.doc.required ? 'จำเป็น' : 'ไม่บังคับ',
                            tone: widget.doc.required
                                ? M3Tone.amber
                                : M3Tone.neutral),
                  ],
                ),
              ),
              if (has) ...[
                const SizedBox(width: 8),
                GlossIconButton(
                  icon: Icons.close_rounded,
                  size: 30,
                  tooltip: 'นำรูปออก',
                  onPressed: widget.enabled ? widget.onRemove : null,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          GlossButton(
            label: has ? 'เปลี่ยนรูป' : 'เลือกรูป',
            icon: has
                ? Icons.swap_horiz_rounded
                : Icons.add_photo_alternate_rounded,
            variant: has ? GlossVariant.glass : GlossVariant.aqua,
            size: GlossSize.small,
            expand: true,
            loading: widget.loading,
            onPressed: widget.enabled ? widget.onPick : null,
          ),
        ],
      ),
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  final String icon3d;
  final String text;
  final bool hover;

  const _PreviewPlaceholder({
    required this.icon3d,
    required this.text,
    this.hover = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: hover ? p.hover : p.row,
        border: Border.all(color: hover ? p.cyanSoftLine : p.line),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Icon3D(icon3d, size: 54, opacity: hover ? 1 : 0.8),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: M3Text.sub(context).copyWith(fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

// ── Step 3: review and submit ───────────────────────────────────────────

class _SubmitStep extends StatelessWidget {
  final bool nameOk;
  final bool ageOk;
  final Map<_Doc, _PickedImage> docs;
  final String? status;
  final bool submitting;
  final VoidCallback? onSubmit;

  const _SubmitStep({
    required this.nameOk,
    required this.ageOk,
    required this.docs,
    required this.status,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      'approved' => 'ยืนยันตัวตนแล้ว',
      'pending' => 'ส่งแล้ว รอการอนุมัติ',
      _ => 'ส่งข้อมูลยืนยันตัวตน',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3Inset(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            children: [
              _CheckLine(label: 'ชื่อ-นามสกุล', ok: nameOk),
              _CheckLine(label: 'วันเกิด (อายุ 18 ปีขึ้นไป)', ok: ageOk),
              for (final d in _Doc.values)
                _CheckLine(
                  label: d.label,
                  ok: docs.containsKey(d),
                  optional: !d.required,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GlossButton(
          label: label,
          icon: Icons.send_rounded,
          size: GlossSize.large,
          expand: true,
          loading: submitting,
          onPressed: onSubmit,
        ),
        if (submitting) ...[
          const SizedBox(height: 10),
          const M3ProgressBar(height: 6),
          const SizedBox(height: 6),
          Text(
            'กำลังส่งข้อมูล… อย่าเพิ่งปิดหน้านี้',
            textAlign: TextAlign.center,
            style: M3Text.sub(context),
          ),
        ],
      ],
    );
  }
}

class _CheckLine extends StatelessWidget {
  final String label;
  final bool ok;
  final bool optional;

  const _CheckLine({
    required this.label,
    required this.ok,
    this.optional = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            ok
                ? Icons.check_circle_rounded
                : (optional
                    ? Icons.remove_circle_outline_rounded
                    : Icons.radio_button_unchecked_rounded),
            size: 19,
            color: ok ? p.green : p.text3,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: M3Text.body(context).copyWith(
                fontSize: 13.5,
                color: ok ? p.text : p.text2,
              ),
            ),
          ),
          if (optional && !ok)
            Text('ไม่บังคับ',
                style: M3Text.sub(context).copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}
