import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/sound_service.dart';
import '../widgets/m3/m3.dart';
import 'license_gate_screen.dart';
import 'network_detail_screen.dart';
import 'shell/app_services.dart';

/// "สร้างวงใหม่" — name, description, public/private (+ password) and the
/// member limit (free 5 / PRO 50), with a live preview of the lobby card.
class CreateNetworkScreen extends StatefulWidget {
  final AppServices services;

  const CreateNetworkScreen({super.key, required this.services});

  @override
  State<CreateNetworkScreen> createState() => _CreateNetworkScreenState();
}

class _CreateNetworkScreenState extends State<CreateNetworkScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isPublic = true;
  double _maxMembers = 10;
  bool _isCreating = false;
  bool _submitted = false;
  bool _obscure = true;

  // Shake animation for validation errors
  late final AnimationController _shakeController;

  AppServices get s => widget.services;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    // Limits follow the licence (e.g. after upgrading on the licence page).
    s.license.addListener(_refresh);
    s.network.addListener(_refresh);
    s.vpn.addListener(_refresh);
  }

  @override
  void dispose() {
    s.license.removeListener(_refresh);
    s.network.removeListener(_refresh);
    s.vpn.removeListener(_refresh);
    _nameController.dispose();
    _descController.dispose();
    _passwordController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  int get _maxAllowed => s.license.state.maxNetworkMembers;

  /// Slider value kept inside 2..[_maxAllowed] (the licence can change).
  double get _members => _maxMembers.clamp(2.0, _maxAllowed.toDouble());

  void _openLicense() {
    SoundService().play(SfxType.tap);
    Navigator.of(context).push(M3PageRoute(
      builder: (_) => LicenseGateScreen(licenseService: s.license),
    ));
  }

  Future<void> _createNetwork() async {
    if (_isCreating) return;
    setState(() => _submitted = true);
    if (!(_formKey.currentState?.validate() ?? false)) {
      SoundService().play(SfxType.error);
      _shakeController.forward(from: 0);
      return;
    }
    FocusScope.of(context).unfocus();

    final hadLan = s.vpn.isConnected;
    final desc = _descController.text.trim();
    setState(() => _isCreating = true);

    final success = await s.network.createNetwork(
      name: _nameController.text.trim(),
      description: desc.isNotEmpty ? desc : null,
      isPublic: _isPublic,
      password: !_isPublic ? _passwordController.text.trim() : null,
      maxMembers: _members.round(),
    );

    if (!mounted) return;
    setState(() => _isCreating = false);

    if (success) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();

      if (hadLan && s.vpn.isConnected) {
        // The tunnel still carries the old network's IP — close it.
        await s.vpn.stopVpn();
        if (!mounted) return;
        m3Toast(context, 'ตัด LAN ของวงเดิมแล้ว กด "เชื่อมต่อ LAN" ในวงใหม่ได้เลย',
            tone: M3Tone.amber);
      }

      final network = s.network.currentNetwork;
      if (network != null) {
        Navigator.of(context).pushReplacement(
          M3PageRoute(
            builder: (_) => NetworkDetailScreen(services: s, network: network),
          ),
        );
      } else {
        Navigator.of(context).pop();
      }
    } else {
      SoundService().play(SfxType.error);
      m3Toast(
        context,
        _friendlyError(s.network.error, 'ไม่สามารถสร้างเครือข่ายได้'),
        tone: M3Tone.red,
        duration: const Duration(seconds: 4),
      );
      s.network.clearError();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final current = s.network.currentNetwork;

    final preview = ListenableBuilder(
      listenable: Listenable.merge([_nameController, _descController]),
      builder: (context, _) => _PreviewHero(
        name: _nameController.text.trim(),
        description: _descController.text.trim(),
        isPublic: _isPublic,
        maxMembers: _members.round(),
        isPaid: s.license.state.isPaid,
      ),
    );

    final form = AnimatedBuilder(
      animation: _shakeController,
      builder: (context, child) {
        final t = _shakeController.value;
        final dx = sin(t * 3 * pi) * 8 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildIdentityCard(),
          const SizedBox(height: 16),
          _buildAccessCard(),
          const SizedBox(height: 16),
          _buildMembersCard(),
          const SizedBox(height: 20),
          GlossButton(
            label: 'สร้างเครือข่าย',
            icon3d: M3Icons.createNetwork,
            size: GlossSize.large,
            expand: true,
            loading: _isCreating,
            onPressed: _isCreating ? null : _createNetwork,
          ),
        ],
      ),
    );

    return Form(
      key: _formKey,
      autovalidateMode: _submitted
          ? AutovalidateMode.onUserInteraction
          : AutovalidateMode.disabled,
      child: M3PageBody(
        children: [
          M3PageHeader(
            icon3d: M3Icons.createNetwork,
            title: 'สร้างเครือข่ายใหม่',
            subtitle: 'ตั้งชื่อ เลือกสาธารณะหรือส่วนตัว แล้วชวนเพื่อนเข้ามาเล่น',
            onBack: () => Navigator.of(context).pop(),
          ),
          const SizedBox(height: 16),
          if (current != null) ...[
            M3Banner(
              tone: M3Tone.amber,
              icon3d: M3Icons.networks,
              title: 'ตอนนี้คุณอยู่ในวง "${current.name}"',
              message: 'เมื่อสร้างวงใหม่ คุณจะย้ายไปอยู่วงใหม่ทันที'
                  '${s.vpn.isConnected ? ' และ LAN ของวงเดิมจะถูกตัด' : ''}'
                  ' — ยังเป็นสมาชิกวงเดิมและกลับเข้าได้ภายหลัง',
            ),
            const SizedBox(height: 14),
          ],
          LayoutBuilder(builder: (context, c) {
            if (c.maxWidth >= 900) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: form),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        preview,
                        const SizedBox(height: 16),
                        const _NextSteps(),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                preview,
                const SizedBox(height: 16),
                form,
                const SizedBox(height: 16),
                const _NextSteps(),
              ],
            );
          }).animate().fadeIn(duration: 350.ms).slideY(begin: 0.03, end: 0),
        ],
      ),
    );
  }

  Widget _buildIdentityCard() {
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.networks,
            title: 'ข้อมูลเครือข่าย',
            subtitle: 'ชื่อที่เพื่อนจะเห็นในล็อบบี้',
          ),
          const SizedBox(height: 14),
          M3Field(
            controller: _nameController,
            label: 'ชื่อเครือข่าย',
            hint: 'เช่น My Gaming LAN',
            prefixIcon: Icons.lan_rounded,
            maxLength: 50,
            textInputAction: TextInputAction.next,
            validator: (v) {
              final name = (v ?? '').trim();
              if (name.isEmpty) return 'กรุณากรอกชื่อเครือข่าย';
              if (name.length < 3) {
                return 'ชื่อเครือข่ายต้องมีอย่างน้อย 3 ตัวอักษร';
              }
              return null;
            },
          ),
          _Counter(controller: _nameController, max: 50),
          const SizedBox(height: 6),
          M3Field(
            controller: _descController,
            label: 'คำอธิบาย (ไม่จำเป็น)',
            hint: 'อธิบายเกี่ยวกับเครือข่ายนี้...',
            maxLines: 3,
            maxLength: 200,
          ),
          _Counter(controller: _descController, max: 200),
        ],
      ),
    );
  }

  Widget _buildAccessCard() {
    void choose(bool public) {
      if (_isPublic == public) return;
      SoundService().play(SfxType.toggle);
      HapticFeedback.selectionClick();
      setState(() => _isPublic = public);
    }

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.lock,
            title: 'การเข้าร่วม',
            subtitle: 'ใครเข้าวงนี้ได้บ้าง',
          ),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, c) {
            final pub = _AccessOption(
              icon3d: M3Icons.networks,
              title: 'สาธารณะ',
              subtitle: 'ทุกคนสามารถค้นหาและเข้าร่วมได้',
              selected: _isPublic,
              onTap: () => choose(true),
            );
            final priv = _AccessOption(
              icon3d: M3Icons.lock,
              title: 'ส่วนตัว',
              subtitle: 'ต้องมีรหัสผ่านจึงจะเข้าร่วมได้',
              selected: !_isPublic,
              onTap: () => choose(false),
            );
            if (c.maxWidth < 440) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [pub, const SizedBox(height: 10), priv],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: pub),
                const SizedBox(width: 10),
                Expanded(child: priv),
              ],
            );
          }),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _isPublic
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: M3Field(
                      controller: _passwordController,
                      label: 'รหัสผ่าน',
                      hint: 'กรอกรหัสผ่านเครือข่าย',
                      obscure: _obscure,
                      prefixIcon: Icons.key_rounded,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _createNetwork(),
                      validator: (v) => !_isPublic && (v ?? '').trim().isEmpty
                          ? 'กรุณากรอกรหัสผ่านสำหรับเครือข่ายส่วนตัว'
                          : null,
                      suffix: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          size: 18,
                        ),
                        tooltip: _obscure ? 'แสดงรหัสผ่าน' : 'ซ่อนรหัสผ่าน',
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersCard() {
    final p = context.m3;
    final lic = s.license.state;
    final isFree = !lic.isPaid;
    final maxAllowed = _maxAllowed;
    final value = _members;

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.members,
            title: 'จำนวนสมาชิกสูงสุด',
            subtitle: isFree
                ? 'แบบฟรีรองรับสูงสุด $maxAllowed คน/วง'
                : 'PRO รองรับสูงสุด $maxAllowed คน/วง',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('${value.round()}', style: M3Text.num(context, size: 30)),
                const SizedBox(width: 4),
                Text('คน', style: M3Text.label(context)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Slider(
            value: value,
            min: 2,
            max: maxAllowed.toDouble(),
            divisions: maxAllowed > 2 ? maxAllowed - 2 : null,
            label: '${value.round()} คน',
            onChanged: _isCreating
                ? null
                : (v) {
                    if (v.round() != _maxMembers.round()) {
                      HapticFeedback.selectionClick();
                    }
                    setState(() => _maxMembers = v);
                  },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('2', style: M3Text.sub(context).copyWith(fontSize: 11.5)),
                Text('$maxAllowed',
                    style: M3Text.sub(context).copyWith(fontSize: 11.5)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (isFree)
            M3Banner(
              tone: M3Tone.gold,
              icon3d: M3Icons.crown,
              title: 'อัปเกรด PRO เพื่อรองรับสูงสุด 50 คน/วง',
              message: 'แบบฟรีจำกัด 5 คนต่อวง — เพื่อนคนที่ 6 จะเข้าวงไม่ได้',
              action: GlossButton(
                label: 'อัปเกรด',
                size: GlossSize.small,
                variant: GlossVariant.gold,
                onPressed: _openLicense,
              ),
            )
          else
            Row(
              children: [
                const M3Tag('PRO',
                    tone: M3Tone.gold, icon: Icons.workspace_premium_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ไลเซนส์ของคุณสร้างวงได้สูงสุด $maxAllowed คน',
                    style: M3Text.sub(context).copyWith(color: p.text2),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Server errors arrive in English; show them in friendly Thai.
String _friendlyError(String? raw, String fallback) {
  if (raw == null || raw.trim().isEmpty) return fallback;
  final e = raw.toLowerCase();
  if (e.contains('maximum number of networks')) {
    return 'คุณสร้างเครือข่ายครบจำนวนสูงสุดแล้ว — ลบวงเก่าก่อนสร้างใหม่';
  }
  if (e.contains('license') || e.contains('device')) {
    return 'ตรวจสอบไลเซนส์หรืออุปกรณ์ไม่ผ่าน ลองเปิดแอปใหม่อีกครั้ง';
  }
  if (e.contains('name')) return 'ชื่อเครือข่ายไม่ถูกต้อง ลองตั้งชื่อใหม่';
  if (e.contains('password')) return 'รหัสผ่านไม่ถูกต้อง ลองตั้งรหัสผ่านใหม่';
  // Messages written by the service are already Thai.
  if (RegExp(r'[฀-๿]').hasMatch(raw)) return raw;
  return fallback;
}

// ── Pieces ──────────────────────────────────────────────────────────────

class _Counter extends StatelessWidget {
  final TextEditingController controller;
  final int max;

  const _Counter({required this.controller, required this.max});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, v, _) => Padding(
        padding: const EdgeInsets.only(top: 4, right: 4),
        child: Text(
          '${v.text.characters.length}/$max',
          textAlign: TextAlign.right,
          style: M3Text.sub(context).copyWith(fontSize: 11),
        ),
      ),
    );
  }
}

class _AccessOption extends StatefulWidget {
  final String icon3d;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _AccessOption({
    required this.icon3d,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_AccessOption> createState() => _AccessOptionState();
}

class _AccessOptionState extends State<_AccessOption> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final sel = widget.selected;
    return Semantics(
      button: true,
      selected: sel,
      label: widget.title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            decoration: BoxDecoration(
              color: sel ? p.select : (_hover ? p.hover : p.inset),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: sel ? p.cyanSoftLine : p.line,
                width: sel ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                AnimatedScale(
                  scale: sel || _hover ? 1.06 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: Icon3D(widget.icon3d,
                      size: 44, opacity: sel ? 1 : 0.75),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, style: M3Text.h3(context)),
                      const SizedBox(height: 2),
                      Text(widget.subtitle,
                          style: M3Text.sub(context).copyWith(fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  sel
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 20,
                  color: sel ? p.cyan : p.text3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Live preview of the lobby card the network will get.
class _PreviewHero extends StatelessWidget {
  final String name;
  final String description;
  final bool isPublic;
  final int maxMembers;
  final bool isPaid;

  const _PreviewHero({
    required this.name,
    required this.description,
    required this.isPublic,
    required this.maxMembers,
    required this.isPaid,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('PREVIEW', style: M3Text.eyebrow(context)),
              const Spacer(),
              M3Tag(
                isPaid ? 'PRO' : 'FREE',
                tone: isPaid ? M3Tone.gold : M3Tone.neutral,
                icon: Icons.workspace_premium_rounded,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('หน้าตาวงของคุณในล็อบบี้', style: M3Text.sub(context)),
          const SizedBox(height: 12),
          M3Inset(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon3D(isPublic ? M3Icons.networks : M3Icons.lock,
                        size: 58),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isEmpty ? 'ชื่อเครือข่ายของคุณ' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: M3Text.h2(context).copyWith(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w600,
                              color: name.isEmpty ? p.text3 : p.text,
                            ),
                          ),
                          const SizedBox(height: 5),
                          M3Tag(
                            isPublic ? 'สาธารณะ' : 'ส่วนตัว',
                            tone: isPublic ? M3Tone.cyan : M3Tone.gold,
                            icon: isPublic
                                ? Icons.public_rounded
                                : Icons.lock_rounded,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  description.isEmpty ? 'ไม่มีคำอธิบาย' : description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: M3Text.sub(context).copyWith(
                      color: description.isEmpty ? p.text3 : p.text2),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _PreviewMetric(value: '1', label: 'สมาชิก', orb: p.green),
                    _PreviewMetric(
                        value: '$maxMembers', label: 'รับได้สูงสุด'),
                  ],
                ),
              ],
            ),
          ),
          if (!isPublic) ...[
            const SizedBox(height: 10),
            Text(
              'วงส่วนตัวจะไม่แสดงในล็อบบี้ — เพื่อนเข้าร่วมด้วยรหัสวงและรหัสผ่าน',
              style: M3Text.sub(context).copyWith(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color? orb;

  const _PreviewMetric({required this.value, required this.label, this.orb});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (orb != null) ...[
          StatusOrb(color: orb!, size: 8, pulse: false),
          const SizedBox(width: 6),
        ],
        Text(value, style: M3Text.num(context, size: 19)),
        const SizedBox(width: 5),
        Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
      ],
    );
  }
}

class _NextSteps extends StatelessWidget {
  const _NextSteps();

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    const steps = [
      'คุณจะเข้าวงทันทีและได้ Virtual IP ของตัวเอง',
      'กด "เชื่อมต่อ LAN" ในหน้าวง เพื่อเปิดการ์ดเครือข่ายเสมือน',
      'กด "ชวนเพื่อน" เพื่อคัดลอกรหัสวงส่งให้เพื่อน',
    ];
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(icon3d: M3Icons.smartRoute, title: 'หลังสร้างวง'),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  M3Count(i + 1),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: M3Text.body(context)
                          .copyWith(fontSize: 13, color: p.text2),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
