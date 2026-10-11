import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/database_helper.dart';
import '../models/license_state.dart';
import '../platform/platform_info.dart';
import '../platform/windows_native.dart';
import '../services/sound_service.dart';
import '../services/update_service.dart';
import '../widgets/m3/m3.dart';
import 'license_gate_screen.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "ตั้งค่า" — licence (PRO badge, key, buy, trial, deactivate), program
/// updates, the night/sky theme picker, Windows admin + tray notes,
/// preferences and about. Tab root.
class SettingsScreen extends StatefulWidget {
  final AppServices services;

  const SettingsScreen({super.key, required this.services});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  final SoundService _sound = SoundService();

  bool _autoConnect = true;
  bool _activating = false;
  bool _demoBusy = false;
  bool _deactivating = false;
  bool _checking = false;
  bool _downloadBusy = false;
  bool _relaunching = false;

  /// Elevation read straight from Windows (the shell's own value starts at
  /// `true` until its check returns).
  bool? _elevated;

  AppServices get s => widget.services;
  UpdateService get u => s.update;
  bool get _licenseBusy => _activating || _demoBusy || _deactivating;

  @override
  void initState() {
    super.initState();
    s.license.addListener(_refresh);
    u.addListener(_refresh);
    // Throttled inside the service (6 h), so this is cheap.
    u.checkForUpdate();
    _loadAutoConnect();
    if (isWindows) _loadElevation();
  }

  @override
  void dispose() {
    s.license.removeListener(_refresh);
    u.removeListener(_refresh);
    _keyController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAutoConnect() async {
    try {
      final value = await DatabaseHelper().getSetting('auto_connect');
      if (!mounted) return;
      setState(() => _autoConnect = value != 'false');
    } catch (_) {
      // Keep the default (on — the shell rejoins unless switched off).
    }
  }

  Future<void> _loadElevation() async {
    try {
      final e = await WindowsNative.isElevated();
      if (!mounted) return;
      setState(() => _elevated = e);
    } catch (_) {
      // Fall back to the shell's value.
    }
  }

  // ── Licence ───────────────────────────────────────────────────────────

  Future<void> _activate() async {
    if (_licenseBusy) return;
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      _sound.play(SfxType.error);
      m3Toast(context, 'กรุณากรอก License Key', tone: M3Tone.amber);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _activating = true);
    final ok = await s.license.activate(key);
    final err = s.license.state.errorMessage;
    if (!ok) s.license.clearError();
    if (!mounted) return;
    setState(() => _activating = false);
    if (ok) {
      _sound.play(SfxType.success);
      HapticFeedback.heavyImpact();
      _keyController.clear();
      m3Toast(context, 'เปิดใช้งาน PRO สำเร็จ ขอบคุณที่สนับสนุน',
          tone: M3Tone.green);
    } else {
      _sound.play(SfxType.error);
      m3Toast(context, err ?? 'ไม่สามารถเปิดใช้งาน License ได้',
          tone: M3Tone.red);
    }
  }

  Future<void> _startDemo() async {
    if (_licenseBusy) return;
    final go = await m3Confirm(
      context,
      icon3d: M3Icons.crown,
      title: 'เริ่มทดลองใช้ PRO?',
      message: 'ระยะทดลองจะเริ่มนับทันทีหลังกดยืนยัน',
      confirmLabel: 'เริ่มทดลองใช้',
    );
    if (!go || !mounted) return;
    setState(() => _demoBusy = true);
    final ok = await s.license.startDemo();
    final st = s.license.state;
    final err = st.errorMessage;
    if (!ok) s.license.clearError();
    if (!mounted) return;
    setState(() => _demoBusy = false);
    if (ok) {
      _sound.play(SfxType.success);
      m3Toast(
        context,
        st.demoMinutesLeft == null
            ? 'เริ่มทดลองใช้ PRO แล้ว'
            : 'เริ่มทดลองใช้ PRO แล้ว — เหลือ ${st.demoMinutesLeft} นาที',
        tone: M3Tone.green,
      );
    } else {
      _sound.play(SfxType.error);
      m3Toast(context, err ?? 'ไม่สามารถเริ่มทดลองใช้งานได้',
          tone: M3Tone.red);
    }
  }

  Future<void> _deactivate() async {
    if (_licenseBusy) return;
    _sound.play(SfxType.notification);
    final ok = await m3Confirm(
      context,
      icon3d: M3Icons.lock,
      title: 'ยกเลิก License?',
      message: 'ต้องการยกเลิก License บนเครื่องนี้ใช่หรือไม่? '
          'คุณจะกลับไปใช้แพ็กเกจฟรี (จำกัด 5 คน/ห้อง)',
      confirmLabel: 'ยกเลิก License',
      cancelLabel: 'เก็บไว้',
      destructive: true,
    );
    if (!ok || !mounted) return;
    _sound.play(SfxType.disconnect);
    setState(() => _deactivating = true);
    try {
      await s.license.deactivate();
    } catch (_) {
      // May fail on a storage error; still switch to free locally.
    }
    s.license.setFreeMode();
    if (!mounted) return;
    setState(() => _deactivating = false);
    m3Toast(context, 'ยกเลิก License แล้ว — กลับมาใช้แพ็กเกจฟรี',
        tone: M3Tone.amber);
  }

  Future<void> _openPurchase(String plan) async {
    await _openUrl(s.license.getPurchaseUrl(plan));
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
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

  void _openGate() {
    Navigator.of(context).push(M3PageRoute(
      builder: (_) => LicenseGateScreen(licenseService: s.license),
    ));
  }

  void _copyDeviceId() {
    final id = s.license.deviceId;
    if (id == null) return;
    Clipboard.setData(ClipboardData(text: id));
    _sound.play(SfxType.coin);
    HapticFeedback.lightImpact();
    m3Toast(context, 'คัดลอก Device ID แล้ว', tone: M3Tone.green);
  }

  // ── Updates ───────────────────────────────────────────────────────────

  Future<void> _checkNow() async {
    if (_checking || u.isChecking || u.isDownloading) return;
    setState(() => _checking = true);
    await u.checkForUpdate(force: true);
    if (!mounted) return;
    setState(() => _checking = false);
    if (u.updateAvailable) {
      _sound.play(SfxType.notification);
      m3Toast(context, 'พบเวอร์ชันใหม่ ${u.latestVersion ?? ''}',
          tone: M3Tone.gold);
    } else if (u.latestVersion == null) {
      m3Toast(context, 'ตรวจสอบอัปเดตไม่สำเร็จ — ตรวจสอบอินเทอร์เน็ตแล้วลองใหม่',
          tone: M3Tone.amber);
    } else {
      m3Toast(context, 'คุณใช้เวอร์ชันล่าสุดแล้ว', tone: M3Tone.green);
    }
  }

  Future<void> _download() async {
    if (_downloadBusy || u.isDownloading) return;
    // The Windows installer closes the app (the shell quits via
    // onInstallerStarted), which drops every live connection.
    if (isWindows && u.canInstallInApp && s.hasActiveConnection) {
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.update,
        title: 'ติดตั้งอัปเดตตอนนี้?',
        message: 'หลังดาวน์โหลดเสร็จ LocalVPN จะปิดตัวเพื่อให้ตัวติดตั้งทำงาน '
            'การเชื่อมต่อ LAN, VPN และการลดปิงที่เปิดอยู่จะถูกตัด '
            'แล้วโปรแกรมจะเปิดขึ้นใหม่เอง',
        confirmLabel: 'ดาวน์โหลดและติดตั้ง',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _downloadBusy = true);
    try {
      await u.downloadUpdate();
    } catch (_) {
      if (mounted) {
        m3Toast(context, 'เปิดหน้าดาวน์โหลดไม่สำเร็จ ลองใหม่อีกครั้ง',
            tone: M3Tone.red);
      }
    }
    if (!mounted) return;
    setState(() => _downloadBusy = false);
  }

  void _retryDownload() {
    u.clearError();
    _download();
  }

  // ── Theme / Windows / preferences ─────────────────────────────────────

  void _pickTheme(bool night) {
    final ctrl = M3ThemeController.instance;
    if (ctrl.isNight == night) return;
    HapticFeedback.selectionClick();
    ctrl.setNight(night);
  }

  Future<void> _relaunchAsAdmin() async {
    final shell = AppShellScope.maybeOf(context);
    if (shell == null || _relaunching) return;
    if (s.hasActiveConnection) {
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.adapter,
        title: 'เปิดใหม่แบบผู้ดูแลระบบ?',
        message: 'LocalVPN จะปิดแล้วเปิดใหม่ การเชื่อมต่อที่เปิดอยู่จะถูกตัด '
            '(Windows จะถามยืนยันสิทธิ์อีกครั้ง)',
        confirmLabel: 'เปิดใหม่',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _relaunching = true);
    await shell.relaunchAsAdmin();
    if (!mounted) return;
    setState(() => _relaunching = false);
  }

  Future<void> _setAutoConnect(bool value) async {
    HapticFeedback.selectionClick();
    setState(() => _autoConnect = value);
    try {
      await DatabaseHelper().setSetting('auto_connect', value.toString());
    } catch (_) {
      if (!mounted) return;
      setState(() => _autoConnect = !value);
      m3Toast(context, 'บันทึกการตั้งค่าไม่สำเร็จ ลองใหม่อีกครั้ง',
          tone: M3Tone.red);
    }
  }

  void _setSound(bool value) {
    HapticFeedback.selectionClick();
    _sound.setEnabled(value);
    setState(() {});
    if (value) {
      Future.delayed(const Duration(milliseconds: 100),
          () => _sound.play(SfxType.coin));
    }
  }

  String get _version {
    final shellVersion = AppShellScope.maybeOf(context)?.version ?? '';
    return shellVersion.isNotEmpty ? shellVersion : u.currentVersion;
  }

  // ── Layout ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return M3PageBody(
      onRefresh: () => u.checkForUpdate(force: true),
      children: [
        M3PageHeader(
          icon3d: M3Icons.settings,
          title: 'ตั้งค่า',
          subtitle: 'ไลเซนส์ · อัปเดต · รูปลักษณ์ · ระบบ',
          trailing: const ShellBadges(),
        ),
        const SizedBox(height: 16),
        _licenseCard()
            .animate()
            .fadeIn(duration: 350.ms)
            .slideY(begin: 0.04, end: 0),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          const gap = SizedBox(height: 16, width: 16);
          final update = _updateCard();
          final look = _appearanceCard();
          final windows = isWindows ? _windowsCard() : null;
          final prefs = _prefsCard();
          final about = _aboutCard();

          if (c.maxWidth < 860) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                update,
                gap,
                look,
                gap,
                if (windows != null) ...[windows, gap],
                prefs,
                gap,
                about,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: update),
                  gap,
                  Expanded(child: look),
                ],
              ),
              gap,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: windows != null
                    ? [
                        Expanded(child: windows),
                        gap,
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [prefs, gap, about],
                          ),
                        ),
                      ]
                    : [
                        Expanded(child: prefs),
                        gap,
                        Expanded(child: about),
                      ],
              ),
            ],
          );
        }).animate().fadeIn(delay: 80.ms, duration: 350.ms),
      ],
    );
  }

  // ── Licence hero ──────────────────────────────────────────────────────

  Widget _licenseCard() {
    final p = context.m3;
    final lic = s.license.state;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final (kind, main, sub) = _badgeFor(lic);
    final paid = lic.isPaid;
    final expired = lic.status == LicenseStatus.expired;
    final canDeactivate =
        !lic.isFree && lic.status != LicenseStatus.checking;
    final hasActions = !paid || lic.isFree || canDeactivate;

    final headline = switch (lic.status) {
      LicenseStatus.active => 'LocalVPN PRO ใช้งานอยู่',
      LicenseStatus.trial => 'กำลังทดลองใช้ PRO',
      LicenseStatus.expired => 'ไลเซนส์ PRO หมดอายุแล้ว',
      LicenseStatus.checking => 'กำลังตรวจสอบไลเซนส์…',
      _ => 'คุณใช้แพ็กเกจฟรีอยู่',
    };
    final detail = paid
        ? 'สมาชิกสูงสุด 50 คน/ห้อง · VPN ทุกประเทศ · Cloud Sync'
        : expired
            ? 'ต่ออายุ หรือกรอก License Key ใหม่เพื่อใช้ฟีเจอร์ PRO ต่อ'
            : 'สมาชิกสูงสุด ${lic.maxNetworkMembers} คน/ห้อง — อัปเกรดเป็น PRO '
                'เพื่อรองรับ 50 คน/ห้องและ VPN ทุกประเทศ';

    final intro = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const M3CardHeader(
          icon3d: M3Icons.crown,
          title: 'ไลเซนส์',
          subtitle: 'แพ็กเกจและการเปิดใช้งาน PRO บนเครื่องนี้',
        ),
        const SizedBox(height: 24),
        ProBadge(
          kind: kind,
          main: main,
          sub: sub,
          height: narrow ? 42 : 48,
          onTap: paid ? null : _openGate,
        ),
        const SizedBox(height: 14),
        Text(
          headline,
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 19 : 22,
            fontWeight: FontWeight.w700,
            height: 1.25,
            color: paid ? p.gold : (expired ? p.red : p.text),
            shadows: p.titleShadow,
          ),
        ),
        const SizedBox(height: 2),
        Text(detail, style: M3Text.sub(context).copyWith(fontSize: 13)),
      ],
    );

    final key = lic.licenseKey;
    final details = M3Inset(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3KeyValue('แพ็กเกจ', lic.typeDisplayName),
          M3KeyValue('สถานะ', lic.statusDisplayName),
          M3KeyValue('สมาชิกสูงสุด', '${lic.maxNetworkMembers} คน/ห้อง'),
          if (lic.expiresAt != null)
            M3KeyValue('หมดอายุ', _date(lic.expiresAt!)),
          if (lic.status == LicenseStatus.trial && lic.demoMinutesLeft != null)
            M3KeyValue('เวลาที่เหลือ', '${lic.demoMinutesLeft} นาที'),
          if (paid && key != null && key.isNotEmpty)
            M3KeyValue('License Key', _maskKey(key), mono: true),
          const SizedBox(height: 6),
          _DeviceIdRow(
            id: s.license.deviceId ?? lic.deviceId,
            onCopy: _copyDeviceId,
          ),
        ],
      ),
    );

    Widget? keyEntry;
    if (!paid) {
      keyEntry = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('มี License Key แล้ว? กรอกเพื่อเปิดใช้งาน PRO',
              style: M3Text.label(context)),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, c) {
            final stacked = c.maxWidth < 480;
            final field = M3Field(
              controller: _keyController,
              hint: 'XXXX-XXXX-XXXX-XXXX',
              mono: true,
              prefixIcon: Icons.key_rounded,
              maxLength: 30,
              enabled: !_licenseBusy,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _activate(),
            );
            final button = GlossButton(
              label: 'เปิดใช้งาน',
              icon: Icons.lock_open_rounded,
              expand: stacked,
              loading: _activating,
              onPressed: _licenseBusy ? null : _activate,
            );
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [field, const SizedBox(height: 10), button],
              );
            }
            return Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 10),
                button,
              ],
            );
          }),
        ],
      );
    }

    final actions = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (!paid)
          GlossButton(
            label: expired ? 'ต่ออายุ PRO' : 'ซื้อ PRO',
            icon: Icons.shopping_cart_rounded,
            variant: GlossVariant.gold,
            onPressed: _licenseBusy ? null : () => _openPurchase('monthly'),
          ),
        if (!paid)
          GlossButton(
            label: 'ดูแพ็กเกจและราคา',
            icon3d: M3Icons.crown,
            variant: GlossVariant.glass,
            onPressed: _licenseBusy ? null : _openGate,
          ),
        if (lic.isFree)
          GlossButton(
            label: 'ทดลองใช้ PRO ฟรี',
            icon: Icons.timer_outlined,
            variant: GlossVariant.glass,
            loading: _demoBusy,
            onPressed: _licenseBusy ? null : _startDemo,
          ),
        if (canDeactivate)
          GlossButton(
            label: 'ยกเลิก License',
            icon: Icons.logout_rounded,
            variant: GlossVariant.red,
            loading: _deactivating,
            onPressed: _licenseBusy ? null : _deactivate,
          ),
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: paid ? p.gold : (expired ? p.red : null),
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 720;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (lic.errorMessage != null && !_licenseBusy) ...[
              M3Banner(
                tone: M3Tone.amber,
                icon3d: M3Icons.lock,
                title: 'แจ้งเตือนไลเซนส์',
                message: lic.errorMessage,
              ),
              const SizedBox(height: 14),
            ],
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: intro),
                  const SizedBox(width: 20),
                  Expanded(flex: 4, child: details),
                ],
              )
            else ...[
              intro,
              const SizedBox(height: 14),
              details,
            ],
            if (keyEntry != null || hasActions)
              const M3GoldLine(margin: EdgeInsets.symmetric(vertical: 16)),
            if (keyEntry != null) ...[
              keyEntry,
              if (hasActions) const SizedBox(height: 14),
            ],
            if (hasActions) actions,
          ],
        );
      }),
    );
  }

  // ── Update card ───────────────────────────────────────────────────────

  Widget _updateCard() {
    final p = context.m3;
    final checking = u.isChecking || _checking;
    final downloading = u.isDownloading;
    final busy = checking || downloading || _downloadBusy;
    final toPage = isWindows && !u.canInstallInApp;
    final progress = u.downloadProgress;
    final changelog = u.changelog?.trim() ?? '';

    final (String status, M3Tone tone) = checking
        ? ('กำลังตรวจสอบ…', M3Tone.cyan)
        : u.updateAvailable
            ? ('มีเวอร์ชันใหม่', M3Tone.gold)
            : u.latestVersion != null
                ? ('เวอร์ชันล่าสุดแล้ว', M3Tone.green)
                : ('ยังไม่ได้ตรวจสอบ', M3Tone.neutral);

    final subtitle = u.updateAvailable
        ? 'มีเวอร์ชันใหม่ ${u.latestVersion ?? ''} พร้อมให้ติดตั้ง'
        : 'ตรวจสอบและติดตั้งเวอร์ชันใหม่ของ LocalVPN';

    return GlassPanel(
      accent: u.updateAvailable ? p.gold : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.update,
            title: 'อัปเดตโปรแกรม',
            subtitle: subtitle,
            trailing: M3Tag(status, tone: tone, dot: true),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _VersionReadout(
                  label: 'เวอร์ชันปัจจุบัน',
                  value: 'v$_version',
                  color: p.gold,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _VersionReadout(
                  label: 'เวอร์ชันล่าสุด',
                  value:
                      u.latestVersion == null ? '—' : 'v${u.latestVersion}',
                  color: u.updateAvailable ? p.green : null,
                ),
              ),
            ],
          ),
          if (u.updateAvailable && changelog.isNotEmpty) ...[
            const SizedBox(height: 12),
            M3Inset(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('มีอะไรใหม่', style: M3Text.label(context)),
                  const SizedBox(height: 4),
                  Text(
                    changelog,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: M3Text.body(context)
                        .copyWith(fontSize: 13, color: p.text2),
                  ),
                ],
              ),
            ),
          ],
          if (downloading) ...[
            const SizedBox(height: 14),
            M3ProgressBar(
              value: progress < 0 ? null : progress,
              tone: progress >= 0.99 ? M3Tone.green : M3Tone.cyan,
            ),
            const SizedBox(height: 6),
            Text(
              progress < 0
                  ? 'กำลังดาวน์โหลด…'
                  : 'กำลังดาวน์โหลด ${(progress * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontFamily: M3Fonts.head,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: progress >= 0.99 ? p.green : p.cyan,
              ),
            ),
          ],
          if (u.downloadError != null) ...[
            const SizedBox(height: 12),
            M3Banner(
              tone: M3Tone.red,
              icon: Icons.error_outline_rounded,
              title: 'อัปเดตไม่สำเร็จ',
              message: _friendlyUpdateError(u.downloadError!),
              action: GlossButton(
                label: 'ลองใหม่',
                size: GlossSize.small,
                variant: GlossVariant.glass,
                onPressed: busy ? null : _retryDownload,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (u.updateAvailable)
                GlossButton(
                  label: toPage ? 'ไปหน้าดาวน์โหลด' : 'ดาวน์โหลดและติดตั้ง',
                  icon: toPage
                      ? Icons.open_in_new_rounded
                      : Icons.download_rounded,
                  loading: downloading || _downloadBusy,
                  onPressed: busy ? null : _download,
                ),
              GlossButton(
                label: 'ตรวจสอบอัปเดต',
                icon: Icons.refresh_rounded,
                variant: GlossVariant.glass,
                loading: checking,
                onPressed: busy ? null : _checkNow,
              ),
            ],
          ),
          if (u.updateAvailable && isWindows) ...[
            const SizedBox(height: 8),
            Text(
              toPage
                  ? 'เวอร์ชัน Windows ดาวน์โหลดได้จากหน้าเว็บของ LocalVPN'
                  : 'ตัวติดตั้งจะปิด LocalVPN ระหว่างอัปเดต แล้วเปิดโปรแกรมให้ใหม่เอง',
              style: M3Text.sub(context).copyWith(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  // ── Appearance ────────────────────────────────────────────────────────

  Widget _appearanceCard() {
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.devicePc,
            title: 'รูปลักษณ์โปรแกรม',
            subtitle: 'เปลี่ยนทันทีและจำไว้ใช้ครั้งต่อไป',
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: M3ThemeController.instance,
            builder: (context, _) {
              final night = M3ThemeController.instance.isNight;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _ThemeTile(
                      night: true,
                      selected: night,
                      title: 'กลางคืน',
                      caption: 'น้ำเงินเข้ม เรืองแสงฟ้า',
                      onTap: () => _pickTheme(true),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _ThemeTile(
                      night: false,
                      selected: !night,
                      title: 'ท้องฟ้า',
                      caption: 'ขาวฟ้า กระจกใส (Aero)',
                      onTap: () => _pickTheme(false),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Windows ───────────────────────────────────────────────────────────

  Widget _windowsCard() {
    final p = context.m3;
    final shell = AppShellScope.maybeOf(context);
    final elevated = _elevated ?? shell?.isElevated ?? true;
    return GlassPanel(
      accent: elevated ? null : p.amber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.adapter,
            title: 'Windows',
            subtitle: 'สิทธิ์ผู้ดูแลระบบและการทำงานเบื้องหลัง',
            trailing: M3Tag(
              elevated ? 'ผู้ดูแลระบบ' : 'โหมดผู้ใช้ทั่วไป',
              tone: elevated ? M3Tone.green : M3Tone.amber,
              dot: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            elevated
                ? 'LocalVPN ทำงานด้วยสิทธิ์ผู้ดูแลระบบ — สร้างการ์ดเครือข่ายเสมือน, '
                    'เปิด VPN และปรับแต่งเพื่อลดปิงได้ครบ'
                : 'การ์ดเครือข่ายเสมือน, VPN และการปรับแต่งเพื่อลดปิง '
                    'ต้องใช้สิทธิ์ผู้ดูแลระบบของ Windows — '
                    'เปิดโปรแกรมใหม่แบบผู้ดูแลเพื่อใช้งานได้ครบ',
            style:
                M3Text.body(context).copyWith(fontSize: 13, color: p.text2),
          ),
          if (!elevated && shell != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: GlossButton(
                label: 'เปิดใหม่แบบผู้ดูแล',
                icon: Icons.admin_panel_settings_rounded,
                loading: _relaunching,
                onPressed: _relaunching ? null : _relaunchAsAdmin,
              ),
            ),
          ],
          const SizedBox(height: 14),
          M3Inset(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon3D(M3Icons.logo, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ปิดหน้าต่างขณะยังเชื่อมต่อ',
                          style: M3Text.h3(context)),
                      const SizedBox(height: 2),
                      Text(
                        'LocalVPN จะย่อไปอยู่ที่ system tray (มุมขวาล่างของแถบงาน) '
                        'และเชื่อมต่อต่อไป — คลิกไอคอนเพื่อเปิดหน้าต่าง '
                        'หรือคลิกขวาเพื่อตัดการเชื่อมต่อ/ออกจากโปรแกรม',
                        style: M3Text.sub(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Preferences + sound ───────────────────────────────────────────────

  Widget _prefsCard() {
    final p = context.m3;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.settings,
            title: 'การใช้งานและเสียง',
          ),
          const SizedBox(height: 8),
          M3SwitchRow(
            title: 'เชื่อมต่ออัตโนมัติ',
            subtitle: 'เชื่อมต่อเครือข่ายล่าสุดเมื่อเปิดแอป',
            value: _autoConnect,
            onChanged: _setAutoConnect,
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: p.line,
          ),
          M3SwitchRow(
            title: 'เอฟเฟกต์เสียง 16-bit',
            subtitle: 'เสียงตอบรับเมื่อกดปุ่มและเปลี่ยนสถานะ',
            value: _sound.enabled,
            onChanged: _setSound,
          ),
        ],
      ),
    );
  }

  // ── About ─────────────────────────────────────────────────────────────

  Widget _aboutCard() {
    final p = context.m3;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon3D(M3Icons.logo, size: 64, glow: p.logoGlow),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LocalVPN',
                      style: M3Text.h2(context).copyWith(
                          fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    Text('by Xman Studio', style: M3Text.sub(context)),
                    const SizedBox(height: 2),
                    Text(
                      'เวอร์ชัน $_version',
                      style: TextStyle(
                        fontFamily: M3Fonts.head,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: p.gold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const M3GoldLine(),
          const M3KeyValue('แอป', 'LocalVPN — LAN เสมือนผ่านอินเทอร์เน็ต'),
          const M3KeyValue('ผู้พัฒนา', 'Xman Studio'),
          M3KeyValue(
            'เว็บไซต์',
            'xman4289.com',
            trailing: GlossIconButton(
              icon: Icons.open_in_new_rounded,
              size: 28,
              tooltip: 'เปิดเว็บไซต์',
              onPressed: () => _openUrl('https://xman4289.com'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────

(ProBadgeKind, String, String) _badgeFor(LicenseState lic) =>
    switch (lic.status) {
      LicenseStatus.active => (
          ProBadgeKind.pro,
          'PRO',
          lic.licenseType == 'lifetime' ? 'ตลอดชีพ' : _daysLeft(lic),
        ),
      LicenseStatus.trial => (
          ProBadgeKind.pro,
          'PRO',
          lic.demoMinutesLeft == null
              ? 'ทดลองใช้'
              : 'ทดลอง · เหลือ ${lic.demoMinutesLeft} นาที',
        ),
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

String _date(DateTime d) {
  final l = d.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}

/// Show only the ends of a licence key (screenshots, shoulder surfing).
String _maskKey(String key) {
  if (key.length <= 8) return '••••••••';
  return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
}

/// The update service stores `e.toString()`; keep the Thai sentence and
/// drop exception class names, URIs and the like.
String _friendlyUpdateError(String raw) {
  final start = raw.indexOf(RegExp(r'[฀-๿]'));
  if (start < 0) {
    return 'ดาวน์โหลดไม่สำเร็จ — ตรวจสอบอินเทอร์เน็ตแล้วลองใหม่อีกครั้ง';
  }
  var msg = raw.substring(start);
  final cut = msg.indexOf(RegExp(r', uri ?=|\w*Exception|\w*Error'));
  if (cut > 0) msg = msg.substring(0, cut);
  return msg.trim().replaceAll(RegExp(r'[:,\s]+$'), '');
}

// ── Private widgets ─────────────────────────────────────────────────────

class _DeviceIdRow extends StatelessWidget {
  final String? id;
  final VoidCallback onCopy;

  const _DeviceIdRow({required this.id, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      padding: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
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
                    style: M3Text.sub(context).copyWith(fontSize: 11.5)),
                Text(
                  id ?? 'ไม่ทราบ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: M3Text.mono(context, size: 12.5),
                ),
              ],
            ),
          ),
          if (id != null) ...[
            const SizedBox(width: 8),
            GlossIconButton(
              icon: Icons.copy_rounded,
              size: 30,
              tooltip: 'คัดลอก Device ID',
              onPressed: onCopy,
            ),
          ],
        ],
      ),
    );
  }
}

class _VersionReadout extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _VersionReadout({
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return M3Inset(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: M3Text.num(context, size: 24, color: color)),
          ),
        ],
      ),
    );
  }
}

/// Large theme preview: the palette's wallpaper with two mini glass bars;
/// gold frame and an aqua check when selected.
class _ThemeTile extends StatefulWidget {
  final bool night;
  final bool selected;
  final String title;
  final String caption;
  final VoidCallback onTap;

  const _ThemeTile({
    required this.night,
    required this.selected,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  @override
  State<_ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends State<_ThemeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final pal = widget.night ? M3Palette.night : M3Palette.sky;
    final sel = widget.selected;

    final preview = AspectRatio(
      aspectRatio: 16 / 10,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: pal.bg),
            Image.asset(
              pal.wallpaper,
              fit: BoxFit.cover,
              alignment: Alignment.topLeft,
              cacheWidth: 640,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
            ColoredBox(color: pal.winShade),
            Positioned(
              left: w * 0.08,
              right: w * 0.08,
              top: h * 0.14,
              height: h * 0.2,
              child: _MiniGlassBar(palette: pal, aqua: true),
            ),
            Positioned(
              left: w * 0.08,
              width: w * 0.58,
              top: h * 0.42,
              height: h * 0.2,
              child: _MiniGlassBar(palette: pal, aqua: false),
            ),
            if (sel)
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    gradient: M3Fx.aquaGloss,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: M3Fx.aquaEdge),
                    boxShadow: M3Fx.aquaGlow,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 18, color: M3Fx.aquaText),
                ),
              ),
          ],
        );
      }),
    );

    final frame = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: EdgeInsets.all(sel ? 2.5 : 1.2),
      decoration: BoxDecoration(
        gradient: sel ? M3Fx.goldFrame : null,
        color: sel ? null : (_hover ? p.cyanSoftLine : p.line),
        borderRadius: BorderRadius.circular(16),
        boxShadow: sel ? M3Fx.goldGlow : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(sel ? 13.5 : 14.8),
        child: preview,
      ),
    );

    return Semantics(
      button: true,
      selected: sel,
      label: '${widget.title} · ${widget.caption}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            SoundService().play(SfxType.tap);
            widget.onTap();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedScale(
                scale: _hover && !sel ? 1.015 : 1,
                duration: const Duration(milliseconds: 140),
                child: frame,
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: widget.title,
                    style: M3Text.h3(context)
                        .copyWith(color: sel ? p.cyan : p.text),
                  ),
                  TextSpan(
                    text: ' · ${widget.caption}',
                    style: M3Text.sub(context),
                  ),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny glass card drawn with the previewed palette's own tokens.
class _MiniGlassBar extends StatelessWidget {
  final M3Palette palette;
  final bool aqua;

  const _MiniGlassBar({required this.palette, required this.aqua});

  @override
  Widget build(BuildContext context) {
    final pal = palette;
    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      final r = BorderRadius.circular(h * 0.32);
      return Container(
        padding: const EdgeInsets.all(0.8),
        decoration: BoxDecoration(
          gradient: pal.glassLine,
          borderRadius: r,
          boxShadow: pal.cardShadow,
        ),
        child: ClipRRect(
          borderRadius: r,
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: pal.glassFill),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: h * 0.45,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white
                              .withValues(alpha: pal.isNight ? 0.12 : 0.5),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: h * 0.28),
                  child: Row(
                    children: [
                      Container(
                        width: h * 0.46,
                        height: h * 0.46,
                        decoration: BoxDecoration(
                          gradient: aqua ? M3Fx.aquaGloss : M3Fx.goldGloss,
                          borderRadius: BorderRadius.circular(h * 0.12),
                        ),
                      ),
                      SizedBox(width: h * 0.25),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FractionallySizedBox(
                              widthFactor: 0.7,
                              child: Container(
                                height: (h * 0.12).clamp(2.0, 6.0),
                                decoration: BoxDecoration(
                                  color: pal.text.withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            SizedBox(height: h * 0.1),
                            FractionallySizedBox(
                              widthFactor: 0.45,
                              child: Container(
                                height: (h * 0.09).clamp(2.0, 5.0),
                                decoration: BoxDecoration(
                                  color: pal.text3.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
