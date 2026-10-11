import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/license_state.dart';
import '../platform/platform_info.dart';
import '../services/license_service.dart';
import '../services/sound_service.dart';
import '../widgets/m3/m3.dart';

/// "ปลดล็อก PRO" — pushed page: hero with the crown and the current badge,
/// the three PRO plans (gold buy buttons), licence-key entry (QR scan on
/// phones, paste on Windows), the free plan and a trial button.
/// Pops `true` once PRO is active, `false` when the user stays on free.
class LicenseGateScreen extends StatefulWidget {
  final LicenseService licenseService;

  const LicenseGateScreen({
    super.key,
    required this.licenseService,
  });

  @override
  State<LicenseGateScreen> createState() => _LicenseGateScreenState();
}

class _Plan {
  final String id;
  final String title;
  final String price;
  final String period;
  final String? badge;
  final List<String> features;
  final String icon;
  final bool best;

  const _Plan({
    required this.id,
    required this.title,
    required this.price,
    required this.period,
    required this.features,
    required this.icon,
    this.badge,
    this.best = false,
  });
}

const _plans = <_Plan>[
  _Plan(
    id: 'monthly',
    title: 'รายเดือน',
    price: '399',
    period: 'บาท/เดือน',
    features: ['VPN ทุกประเทศ', 'สมาชิก 50 คน/ห้อง', 'Cloud Sync'],
    icon: M3Icons.update,
  ),
  _Plan(
    id: 'yearly',
    title: 'รายปี',
    price: '2,500',
    period: 'บาท/ปี',
    badge: 'ประหยัด 48%',
    features: ['VPN ทุกประเทศ', 'สมาชิก 50 คน/ห้อง', 'ซัพพอร์ตพรีเมียม'],
    icon: M3Icons.trophy,
  ),
  _Plan(
    id: 'lifetime',
    title: 'ตลอดชีพ',
    price: '5,000',
    period: 'บาท (จ่ายครั้งเดียว)',
    badge: 'คุ้มที่สุด',
    features: ['ทุกฟีเจอร์', 'ไม่จำกัดอุปกรณ์', 'อัปเดตตลอดชีพ'],
    icon: M3Icons.crown,
    best: true,
  ),
];

class _LicenseGateScreenState extends State<LicenseGateScreen> {
  final TextEditingController _keyController = TextEditingController();
  final FocusNode _keyFocus = FocusNode();
  bool _activating = false;
  bool _demoBusy = false;
  bool _enteringFree = false;
  bool _closing = false;

  LicenseService get _lic => widget.licenseService;
  bool get _busy => _activating || _demoBusy || _closing;

  @override
  void initState() {
    super.initState();
    _lic.addListener(_refresh);
  }

  @override
  void dispose() {
    _lic.removeListener(_refresh);
    _keyController.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _close(bool result) {
    if (_closing) return;
    _closing = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(result);
    } else {
      setState(() {
        _closing = false;
        _enteringFree = false;
      });
    }
  }

  Future<void> _activateLicense() async {
    if (_activating || _demoBusy || _closing) return;
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      SoundService().play(SfxType.error);
      m3Toast(context, 'กรุณากรอก License Key', tone: M3Tone.amber);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _activating = true);
    final success = await _lic.activate(key);
    final err = _lic.state.errorMessage;
    if (!success) _lic.clearError();
    if (!mounted) return;
    setState(() => _activating = false);

    if (success) {
      SoundService().play(SfxType.success);
      HapticFeedback.heavyImpact();
      m3Toast(context, 'เปิดใช้งาน PRO สำเร็จ ขอบคุณที่สนับสนุน',
          tone: M3Tone.green);
      _close(true);
    } else {
      SoundService().play(SfxType.error);
      m3Toast(context, err ?? 'ไม่สามารถเปิดใช้งาน License ได้',
          tone: M3Tone.red);
    }
  }

  Future<void> _startDemo() async {
    if (_busy) return;
    final go = await m3Confirm(
      context,
      icon3d: M3Icons.crown,
      title: 'เริ่มทดลองใช้ PRO?',
      message: 'ระยะทดลองจะเริ่มนับทันทีหลังกดยืนยัน',
      confirmLabel: 'เริ่มทดลองใช้',
    );
    if (!go || !mounted) return;
    setState(() => _demoBusy = true);
    final ok = await _lic.startDemo();
    final st = _lic.state;
    final err = st.errorMessage;
    if (!ok) _lic.clearError();
    if (!mounted) return;
    setState(() => _demoBusy = false);
    if (ok) {
      SoundService().play(SfxType.success);
      m3Toast(
        context,
        st.demoMinutesLeft == null
            ? 'เริ่มทดลองใช้ PRO แล้ว'
            : 'เริ่มทดลองใช้ PRO แล้ว — เหลือ ${st.demoMinutesLeft} นาที',
        tone: M3Tone.green,
      );
      _close(true);
    } else {
      SoundService().play(SfxType.error);
      m3Toast(context, err ?? 'ไม่สามารถเริ่มทดลองใช้งานได้',
          tone: M3Tone.red);
    }
  }

  void _enterFreeMode() {
    if (_enteringFree || _busy) return;
    _enteringFree = true;
    // Same rule as the splash screen: no valid licence → free mode.
    if (!_lic.state.isValid) _lic.setFreeMode();
    SoundService().play(SfxType.coin);
    HapticFeedback.mediumImpact();
    _close(false);
  }

  Future<void> _openPurchaseUrl(String plan) async {
    final uri = Uri.tryParse(_lic.getPurchaseUrl(plan));
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) {
      m3Toast(context, 'ไม่สามารถเปิดเว็บเบราว์เซอร์ได้', tone: M3Tone.red);
    }
  }

  /// Phones only (mobile_scanner has no Windows implementation).
  Future<void> _scanQrCode() async {
    if (_busy || !canScanQr) return;
    final result = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScannerScreen()),
    );
    if (!mounted || result == null || result.trim().isEmpty) return;
    SoundService().play(SfxType.coin);
    _keyController.text = result.trim();
    // Auto-activate after scan
    _activateLicense();
  }

  /// Windows: paste the key instead of scanning it.
  Future<void> _pasteKey() async {
    if (_busy) return;
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      data = null;
    }
    if (!mounted) return;
    final text = (data?.text ?? '')
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (text.isEmpty) {
      m3Toast(context, 'ไม่พบข้อความในคลิปบอร์ด — คัดลอก License Key ก่อนแล้วลองอีกครั้ง',
          tone: M3Tone.amber);
      return;
    }
    _keyController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    SoundService().play(SfxType.coin);
    _keyFocus.requestFocus();
    m3Toast(context, 'วาง License Key แล้ว — กด "เปิดใช้งาน" เพื่อยืนยัน');
  }

  void _copyDeviceId() {
    final deviceId = _lic.deviceId;
    if (deviceId == null) return;
    Clipboard.setData(ClipboardData(text: deviceId));
    SoundService().play(SfxType.coin);
    HapticFeedback.lightImpact();
    m3Toast(context, 'คัดลอก Device ID แล้ว', tone: M3Tone.green);
  }

  // ── Layout ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final lic = _lic.state;
    return M3PageBody(
      children: [
        M3PageHeader(
          icon3d: M3Icons.crown,
          title: 'ปลดล็อก PRO',
          subtitle: 'เลือกแพ็กเกจ หรือกรอก License Key ที่มีอยู่',
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: 16),
        if (lic.isPaid) ...[
          M3Banner(
            tone: M3Tone.green,
            icon3d: M3Icons.crown,
            title: 'ไลเซนส์ PRO ใช้งานอยู่แล้ว',
            message: '${lic.typeDisplayName} — ต่ออายุหรือเปลี่ยนแพ็กเกจได้ด้านล่าง',
          ),
          const SizedBox(height: 14),
        ] else if (lic.errorMessage != null && !_busy) ...[
          M3Banner(
            tone: M3Tone.amber,
            icon3d: M3Icons.lock,
            title: 'แจ้งเตือนไลเซนส์',
            message: lic.errorMessage,
          ),
          const SizedBox(height: 14),
        ],
        _GateHero(lic: lic)
            .animate()
            .fadeIn(duration: 350.ms)
            .slideY(begin: 0.04, end: 0),
        const SizedBox(height: 20),
        const M3SectionTitle('เลือกแพ็กเกจ'),
        _planGrid(),
        const SizedBox(height: 20),
        LayoutBuilder(builder: (context, c) {
          final keyCard = _keyCard();
          final freeCard = _freeCard(lic);
          if (c.maxWidth < 860) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [keyCard, const SizedBox(height: 16), freeCard],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: keyCard),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: freeCard),
            ],
          );
        }).animate().fadeIn(delay: 160.ms, duration: 350.ms),
      ],
    );
  }

  Widget _planGrid() {
    return LayoutBuilder(builder: (context, c) {
      final three = c.maxWidth >= 760;
      final cards = [
        for (var i = 0; i < _plans.length; i++)
          _PlanCard(
            plan: _plans[i],
            fill: three,
            onBuy: () => _openPurchaseUrl(_plans[i].id),
          )
              .animate()
              .fadeIn(delay: (80 + i * 60).ms, duration: 300.ms)
              .slideY(begin: 0.05, end: 0),
      ];
      if (!three) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              cards[i],
            ],
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              Expanded(child: cards[i]),
            ],
          ],
        ),
      );
    });
  }

  Widget _keyCard() {
    final p = context.m3;
    final deviceId = _lic.deviceId;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.lock,
            title: 'มี License Key แล้ว',
            subtitle: 'กรอกคีย์เพื่อเปิดใช้งาน PRO บนเครื่องนี้',
          ),
          const SizedBox(height: 14),
          M3Field(
            controller: _keyController,
            focusNode: _keyFocus,
            hint: 'XXXX-XXXX-XXXX-XXXX',
            mono: true,
            prefixIcon: Icons.key_rounded,
            maxLength: 30,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _activateLicense(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlossButton(
                  label: 'เปิดใช้งาน',
                  icon: Icons.lock_open_rounded,
                  expand: true,
                  loading: _activating,
                  onPressed: _busy ? null : _activateLicense,
                ),
              ),
              const SizedBox(width: 10),
              if (canScanQr)
                GlossButton(
                  label: 'สแกน QR',
                  icon3d: M3Icons.qr,
                  variant: GlossVariant.glass,
                  tooltip: 'สแกน QR Code ของ License Key',
                  onPressed: _busy ? null : _scanQrCode,
                )
              else
                GlossButton(
                  label: 'วางคีย์',
                  icon: Icons.content_paste_rounded,
                  variant: GlossVariant.glass,
                  tooltip: 'วาง License Key จากคลิปบอร์ด',
                  onPressed: _busy ? null : _pasteKey,
                ),
            ],
          ),
          if (deviceId != null) ...[
            const SizedBox(height: 14),
            M3Inset(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.fingerprint_rounded, size: 20, color: p.text3),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Device ID',
                            style:
                                M3Text.sub(context).copyWith(fontSize: 11.5)),
                        Text(
                          deviceId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: M3Text.mono(context, size: 12.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlossIconButton(
                    icon: Icons.copy_rounded,
                    size: 30,
                    tooltip: 'คัดลอก Device ID',
                    onPressed: _copyDeviceId,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _freeCard(LicenseState lic) {
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.networks,
            title: 'แพ็กเกจฟรี',
            subtitle: '0 บาท ตลอดไป',
            trailing: lic.status == LicenseStatus.free
                ? const M3Tag('ใช้อยู่', tone: M3Tone.green, dot: true)
                : null,
          ),
          const SizedBox(height: 12),
          const _Feature('Global Torrent ใช้ได้เต็มรูปแบบ'),
          const _Feature('สร้าง/เข้าร่วมเครือข่าย VPN'),
          const _Feature('แชร์ไฟล์ในเครือข่าย'),
          const _Feature('จำกัดสมาชิกสูงสุด 5 คน/ห้อง', included: false),
          if (!lic.isPaid) ...[
            const SizedBox(height: 16),
            if (lic.isFree) ...[
              GlossButton(
                label: 'ทดลองใช้ PRO ฟรี',
                icon: Icons.timer_outlined,
                variant: GlossVariant.green,
                expand: true,
                loading: _demoBusy,
                onPressed: _busy ? null : _startDemo,
              ),
              const SizedBox(height: 10),
            ],
            GlossButton(
              label: 'ใช้แบบฟรีต่อไป',
              icon: Icons.play_arrow_rounded,
              variant: GlossVariant.glass,
              expand: true,
              onPressed: _busy ? null : _enterFreeMode,
            ),
          ],
        ],
      ),
    );
  }
}

(ProBadgeKind, String, String) _badgeFor(LicenseState lic) =>
    switch (lic.status) {
      LicenseStatus.active => (
          ProBadgeKind.pro,
          'PRO',
          lic.licenseType == 'lifetime' ? 'ตลอดชีพ' : _daysLeft(lic),
        ),
      LicenseStatus.trial => (ProBadgeKind.pro, 'PRO', 'ทดลองใช้'),
      LicenseStatus.expired => (ProBadgeKind.none, 'PRO', 'หมดอายุ'),
      LicenseStatus.checking => (ProBadgeKind.free, 'FREE', 'กำลังตรวจสอบ'),
      _ => (ProBadgeKind.free, 'FREE', 'อัปเกรดเป็น PRO'),
    };

String _daysLeft(LicenseState lic) {
  final e = lic.expiresAt;
  if (e == null) return lic.typeDisplayName;
  final days = e.difference(DateTime.now()).inDays;
  return days >= 0 ? 'เหลือ $days วัน' : 'หมดอายุ';
}

// ── Hero ────────────────────────────────────────────────────────────────

class _GateHero extends StatelessWidget {
  final LicenseState lic;

  const _GateHero({required this.lic});

  static const _perks = <(String, String, String)>[
    (M3Icons.members, 'สมาชิกสูงสุด 50 คน/ห้อง', 'แพ็กเกจฟรีจำกัด 5 คน/ห้อง'),
    (M3Icons.vpnProxy, 'VPN ทุกประเทศ', 'ปลดล็อกเกม/เว็บต่างประเทศ'),
    (M3Icons.upload, 'Cloud Sync', 'ซิงก์ข้อมูลผ่านคลาวด์'),
    (M3Icons.profile, 'ซัพพอร์ตพรีเมียม', 'ดูแลโดยทีม Xman Studio'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final (kind, main, sub) = _badgeFor(lic);

    final crown = Icon3D(
      M3Icons.crown,
      size: narrow ? 92 : 148,
      glow: p.gold.withValues(alpha: 0.4),
    )
        .animate()
        .scale(
          begin: const Offset(0.75, 0.75),
          end: const Offset(1, 1),
          duration: 350.ms,
          curve: Curves.easeOutBack,
        )
        .fadeIn(duration: 300.ms);

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: ProBadge(
            kind: kind,
            main: main,
            sub: sub,
            height: narrow ? 36 : 44,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'LocalVPN PRO',
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 26 : 34,
            fontWeight: FontWeight.w700,
            fontStyle: FontStyle.italic,
            height: 1.15,
            color: p.gold,
            shadows: p.titleShadow,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'สร้าง Virtual LAN ระหว่างอุปกรณ์ผ่านอินเทอร์เน็ต — อัปเกรดเพื่อเล่นกับเพื่อน'
          'ได้มากขึ้นและใช้ VPN ได้ทุกประเทศ',
          style: M3Text.sub(context).copyWith(fontSize: 13.5),
        ),
      ],
    );

    final perks = LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 520 ? 2 : 1;
      const gap = 10.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final (icon, head, note) in _perks)
            SizedBox(
              width: w,
              child: M3Inset(
                padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                child: Row(
                  children: [
                    Icon3D(icon, size: 38),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(head,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: M3Text.h3(context)),
                          Text(note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: M3Text.sub(context)
                                  .copyWith(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    });

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: p.gold,
      padding: EdgeInsets.all(narrow ? 16 : 24),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    crown,
                    const SizedBox(width: 12),
                    Expanded(child: title),
                  ],
                ),
                const SizedBox(height: 16),
                perks,
              ],
            )
          : Row(
              children: [
                crown,
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [title, const SizedBox(height: 18), perks],
                  ),
                ),
              ],
            ),
    );
  }
}

// ── Plans ───────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final _Plan plan;

  /// True inside the equal-height row: push the buy button to the bottom.
  final bool fill;
  final VoidCallback onBuy;

  const _PlanCard({
    required this.plan,
    required this.fill,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return GlassPanel(
      highlight: plan.best,
      accent: plan.best ? p.gold : null,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon3D(plan.icon, size: 46),
              const SizedBox(width: 10),
              Expanded(
                child: Text(plan.title,
                    style: M3Text.h2(context).copyWith(
                        fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              if (plan.badge != null) M3Tag(plan.badge!, tone: M3Tone.gold),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                plan.price,
                style: M3Text.num(context,
                    size: 36, color: plan.best ? p.gold : null),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(plan.period, style: M3Text.sub(context)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final f in plan.features) _Feature(f),
          const SizedBox(height: 16),
          if (fill) const Spacer(),
          GlossButton(
            label: 'ซื้อแพ็กเกจนี้',
            icon: Icons.shopping_cart_rounded,
            variant: GlossVariant.gold,
            expand: true,
            onPressed: onBuy,
          ),
        ],
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  final String text;
  final bool included;

  const _Feature(this.text, {this.included = true});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            included ? Icons.check_circle_rounded : Icons.remove_circle_rounded,
            size: 16,
            color: included ? p.green : p.amber,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: M3Text.body(context).copyWith(
                fontSize: 13,
                color: included ? p.text2 : p.amber,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── QR scanner (phones only) ────────────────────────────────────────────

/// Full-screen QR code scanner overlay
class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    // The camera feed is always dark, so the overlay is white on black in
    // both palettes.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_scanned) return;
              final barcode = capture.barcodes.firstOrNull;
              if (barcode?.rawValue == null) return;

              final value = barcode!.rawValue!.trim();
              if (value.isEmpty) return;

              _scanned = true;
              HapticFeedback.heavyImpact();
              Navigator.pop(context, value);
            },
          ),
          // Viewfinder overlay
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: p.cyan, width: 2.5),
                borderRadius: BorderRadius.circular(18),
                boxShadow: M3Fx.aquaGlow,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  GlossIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'ปิด',
                    size: 40,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'สแกน QR Code License',
                      style: TextStyle(
                        fontFamily: M3Fonts.head,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Instruction text
          const Positioned(
            bottom: 80,
            left: 24,
            right: 24,
            child: Text(
              'วาง QR Code ของ License Key ในกรอบ',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: M3Fonts.ui,
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
