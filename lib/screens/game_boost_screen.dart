import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../models/proxy_server.dart';
import '../platform/platform_info.dart';
import '../services/game_boost_service.dart';
import '../services/net/latency_probe.dart';
import '../services/vpn_proxy_service.dart';
import '../services/windows_tuneup.dart';
import '../widgets/m3/m3.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "ลดปิงเกม" — measure the real route to a game region, compare it with
/// relays, switch to the faster one only when it wins, and on Windows take
/// the Wi-Fi scan and power-saving spikes out of the picture.
class GameBoostScreen extends StatefulWidget {
  final AppServices services;

  const GameBoostScreen({super.key, required this.services});

  @override
  State<GameBoostScreen> createState() => _GameBoostScreenState();
}

class _GameBoostScreenState extends State<GameBoostScreen> {
  AppServices get s => widget.services;
  GameBoostService get b => widget.services.boost;
  final _hostCtrl = TextEditingController();
  bool _nagleOff = false;
  bool _nagleBusy = false;

  @override
  void initState() {
    super.initState();
    b.addListener(_refresh);
    s.proxy.addListener(_refresh);
    _hostCtrl.text = b.customHost ?? '';
    if (isWindows) {
      WindowsTuneup.isNagleDisabled().then((v) {
        if (mounted) setState(() => _nagleOff = v);
      });
    }
  }

  @override
  void dispose() {
    b.removeListener(_refresh);
    s.proxy.removeListener(_refresh);
    _hostCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  bool get _proxyInUse =>
      !b.usesTunnel &&
      (s.proxy.status == VpnProxyStatus.connected ||
          s.proxy.status == VpnProxyStatus.connecting);

  Future<void> _start([ServerCountry? relay]) async {
    final target = relay ?? b.recommendation?.relay;
    if (target == null) return;
    if (relay != null && b.directIsBest) {
      final ok = await m3Confirm(
        context,
        icon3d: M3Icons.ping,
        title: 'เส้นทางตรงเร็วกว่ารีเลย์นี้',
        message: 'ผลวัดล่าสุดบอกว่าเส้นทางตรงของคุณดีกว่า การผ่าน '
            '${relay.countryName} อาจทำให้ปิงสูงขึ้น ยังต้องการใช้อยู่ไหม?',
        confirmLabel: 'ใช้อยู่ดี',
      );
      if (!ok) return;
    }
    await b.start(relay: target);
    if (!mounted) return;
    if (b.isActive) {
      m3Toast(context, 'เปิดโหมดลดปิงผ่าน ${target.countryName} แล้ว',
          tone: M3Tone.green);
    }
  }

  Future<void> _stop() async {
    await b.stop();
    if (mounted) m3Toast(context, 'ปิดโหมดลดปิงแล้ว');
  }

  Future<void> _applyHost() async {
    final err = await b.setCustomHost(_hostCtrl.text);
    if (!mounted) return;
    if (err != null) {
      m3Toast(context, err, tone: M3Tone.red);
    } else {
      m3Toast(
        context,
        b.customHost == null
            ? 'กลับไปใช้ภูมิภาค ${b.region.name}'
            : 'ตั้งปลายทางเป็น ${b.customHost} แล้ว',
        tone: M3Tone.green,
      );
    }
  }

  Future<void> _toggleNagle(bool off) async {
    final guid = b.adapter?.guid;
    if (guid == null) return;
    setState(() => _nagleBusy = true);
    final r = off
        ? await WindowsTuneup.disableNagle(guid)
        : await WindowsTuneup.restoreNagle();
    if (!mounted) return;
    setState(() {
      _nagleBusy = false;
      if (r.ok) _nagleOff = off;
    });
    m3Toast(context, r.message.isEmpty ? 'เรียบร้อย' : r.message,
        tone: r.ok ? M3Tone.green : M3Tone.red);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final shell = AppShellScope.of(context);
    final wide = w >= 1150;

    final left = <Widget>[
      _TargetCard(
        boost: b,
        hostCtrl: _hostCtrl,
        onApplyHost: _applyHost,
      ),
      const SizedBox(height: 16),
      _ResultsCard(boost: b, onUse: _start),
    ];
    final right = <Widget>[
      if (isWindows) ...[
        _TuneupCard(
          boost: b,
          nagleOff: _nagleOff,
          nagleBusy: _nagleBusy,
          elevated: shell.isElevated,
          onNagle: _toggleNagle,
        ),
        const SizedBox(height: 16),
      ],
      _BufferbloatCard(boost: b),
      const SizedBox(height: 16),
      const _HowItWorks(),
    ];

    return M3PageBody(
      children: [
        M3PageHeader(
          icon3d: M3Icons.gameBoost,
          title: 'ลดปิงเกม',
          subtitle:
              'วัดเส้นทางจริงไปเซิร์ฟเวอร์ต่างประเทศ แล้วเลือกทางที่เร็วที่สุด',
          trailing: const ShellBadges(),
        ),
        const SizedBox(height: 16),
        if (isWindows && !shell.isElevated) ...[
          M3Banner(
            tone: M3Tone.amber,
            icon3d: M3Icons.adapter,
            title: 'ต้องเปิดแบบผู้ดูแลระบบ',
            message: 'การสลับเส้นทาง (WireGuard) และการปรับแต่ง Windows '
                'ต้องใช้สิทธิ์ผู้ดูแลระบบ — วัดปิงได้ตามปกติ',
            action: GlossButton(
              label: 'เปิดใหม่แบบผู้ดูแล',
              size: GlossSize.small,
              variant: GlossVariant.gold,
              onPressed: shell.relaunchAsAdmin,
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (_proxyInUse) ...[
          M3Banner(
            tone: M3Tone.cyan,
            icon3d: M3Icons.vpnProxy,
            title: 'VPN ประเทศเปิดอยู่',
            message: 'ปิด VPN ประเทศก่อน เพื่อวัดเส้นทางตรงของคุณและใช้โหมดลดปิง '
                '(ใช้อุโมงค์ได้ทีละอย่าง)',
            action: GlossButton(
              label: 'ไปหน้า VPN',
              size: GlossSize.small,
              variant: GlossVariant.glass,
              onPressed: () => shell.goTo(ShellTab.vpn),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (b.error != null) ...[
          M3Banner(
            tone: M3Tone.red,
            icon: Icons.error_rounded,
            title: b.error!,
            action: GlossIconButton(
              icon: Icons.close_rounded,
              tooltip: 'ปิด',
              onPressed: b.clearError,
            ),
          ),
          const SizedBox(height: 14),
        ],
        _BoostHero(
          boost: b,
          disabled: _proxyInUse,
          onStart: () => _start(),
          onStop: _stop,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: Column(children: left)),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: Column(children: right)),
            ],
          )
        else ...[
          ...left,
          const SizedBox(height: 16),
          ...right,
        ],
      ],
    );
  }
}

// ── Hero ────────────────────────────────────────────────────────────────

class _BoostHero extends StatelessWidget {
  final GameBoostService boost;
  final bool disabled;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _BoostHero({
    required this.boost,
    required this.disabled,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final b = boost;
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final live = b.live.where((v) => v >= 0).toList();
    final liveSample = LatencySample(b.live);
    final rec = b.recommendation;

    final String headline;
    final String detail;
    final Color headColor;
    if (b.isActive) {
      headline = 'กำลังลดปิง';
      detail = 'ผ่าน ${b.activeRelay?.countryName ?? '-'} → ${b.targetLabel}'
          '${b.tweakNotes.isEmpty ? '' : ' · ${b.tweakNotes.length} การปรับแต่ง Windows ทำงาน'}';
      headColor = p.green;
    } else if (b.isBusy) {
      headline = switch (b.phase) {
        BoostPhase.analyzing => 'กำลังวิเคราะห์เส้นทาง',
        BoostPhase.connecting => 'กำลังเปิดเส้นทาง',
        BoostPhase.stopping => 'กำลังปิด',
        _ => 'กำลังวัด',
      };
      detail = b.status ?? '';
      headColor = p.cyan;
    } else if (rec != null) {
      final gain = (b.direct?.sample.medianMs ?? 0) -
          (rec.sample.medianMs ?? 0);
      headline = 'เร็วขึ้นได้ ${gain > 0 ? '${gain.round()} ms' : ''}';
      detail = 'ผ่าน ${rec.relay!.countryName} ดีกว่าเส้นทางตรงไป ${b.targetLabel}';
      headColor = p.green;
    } else if (b.directIsBest) {
      headline = 'เส้นทางตรงดีที่สุดแล้ว';
      detail = 'ไม่มีรีเลย์ไหนเร็วกว่าเส้นทางของ ISP คุณไป ${b.targetLabel} '
          '— ไม่ต้องเปิดโหมดลดปิง';
      headColor = p.cyan;
    } else {
      headline = 'พร้อมวัดเส้นทาง';
      detail = 'ปลายทาง: ${b.targetLabel} — กดวิเคราะห์เพื่อเทียบเส้นทางตรงกับรีเลย์';
      headColor = p.text;
    }

    final numbers = Wrap(
      spacing: narrow ? 18 : 30,
      runSpacing: 10,
      children: [
        _HeroNum(
          label: b.isActive ? 'ปิงตอนนี้' : 'เส้นทางตรง',
          value: b.isActive
              ? (live.isEmpty ? '…' : '${live.last.round()}')
              : _ms(b.direct?.sample.medianMs),
          unit: 'ms',
          color: b.isActive ? p.green : null,
        ),
        if (b.isActive) ...[
          _HeroNum(label: 'กระชาก (jitter)', value: _ms(liveSample.jitterMs),
              unit: 'ms'),
          _HeroNum(label: 'แพ็กเก็ตหาย',
              value: liveSample.rtts.isEmpty
                  ? '—'
                  : liveSample.lossPercent.toStringAsFixed(0),
              unit: '%'),
        ] else if (rec != null) ...[
          _HeroNum(label: 'ผ่าน ${rec.relay!.countryCode}',
              value: _ms(rec.sample.medianMs), unit: 'ms', color: p.green),
          _HeroNum(label: 'กระชาก', value: _ms(rec.sample.jitterMs),
              unit: 'ms'),
        ] else
          _HeroNum(label: 'กระชาก', value: _ms(b.direct?.sample.jitterMs),
              unit: 'ms'),
      ],
    );

    final buttons = Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
      children: [
        if (b.isActive)
          GlossButton(
            label: 'ปิดโหมดลดปิง',
            icon: Icons.stop_rounded,
            variant: GlossVariant.red,
            size: GlossSize.large,
            onPressed: onStop,
          )
        else if (b.phase == BoostPhase.analyzing)
          GlossButton(
            label: 'หยุดวิเคราะห์',
            variant: GlossVariant.glass,
            size: GlossSize.large,
            onPressed: b.cancel,
          )
        else ...[
          if (rec != null)
            GlossButton(
              label: 'เปิดโหมดลดปิง',
              icon3d: M3Icons.gameBoost,
              size: GlossSize.large,
              loading: b.phase == BoostPhase.connecting,
              onPressed: disabled || b.isBusy ? null : onStart,
            ),
          GlossButton(
            label: b.direct == null ? 'วิเคราะห์เส้นทาง' : 'วิเคราะห์ใหม่',
            icon3d: M3Icons.smartRoute,
            variant: rec != null ? GlossVariant.glass : GlossVariant.aqua,
            size: GlossSize.large,
            onPressed: disabled || b.isBusy ? null : b.analyze,
          ),
          GlossButton(
            label: 'วัดเส้นทางตรง',
            variant: GlossVariant.glass,
            size: GlossSize.large,
            loading: b.phase == BoostPhase.measuring,
            onPressed: disabled || b.isBusy ? null : b.measureDirect,
          ),
        ],
      ],
    );

    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusOrb(
              color: b.isActive
                  ? p.green
                  : (b.isBusy ? p.cyan : p.text3),
              size: 11,
              pulse: b.isActive || b.isBusy,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                headline,
                style: TextStyle(
                  fontFamily: M3Fonts.head,
                  fontSize: narrow ? 24 : 31,
                  fontWeight: FontWeight.w700,
                  color: headColor,
                  shadows: p.titleShadow,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(detail, style: M3Text.sub(context).copyWith(fontSize: 13.5)),
        const SizedBox(height: 14),
        numbers,
        if (b.isBusy) ...[
          const SizedBox(height: 14),
          const M3ProgressBar(height: 8),
        ],
      ],
    );

    final icon = Icon3D(
      M3Icons.gameBoost,
      size: narrow ? 92 : 132,
      glow: b.isActive ? p.green.withValues(alpha: 0.45) : p.logoGlow,
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: b.isActive ? p.green : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (narrow) ...[
            Row(children: [
              icon,
              const SizedBox(width: 14),
              Expanded(child: textBlock),
            ]),
            const SizedBox(height: 16),
            buttons,
          ] else
            Row(
              children: [
                icon,
                const SizedBox(width: 22),
                Expanded(child: textBlock),
                const SizedBox(width: 18),
                SizedBox(width: 250, child: buttons),
              ],
            ),
          if (b.isActive) ...[
            const SizedBox(height: 18),
            SizedBox(
              height: 120,
              child: M3Inset(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: _LiveChart(values: b.live),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _ms(double? v) => v == null ? '—' : v.round().toString();

class _HeroNum extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color? color;

  const _HeroNum({
    required this.label,
    required this.value,
    required this.unit,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: M3Text.num(context, size: 30, color: color)),
            const SizedBox(width: 3),
            Text(unit, style: M3Text.sub(context)),
          ],
        ),
        Text(label, style: M3Text.sub(context).copyWith(fontSize: 11.5)),
      ],
    );
  }
}

/// Live ping chart: aqua glass line, spikes over 1.6× the median in red.
class _LiveChart extends StatelessWidget {
  final List<double> values;
  const _LiveChart({required this.values});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    if (values.where((v) => v >= 0).length < 2) {
      return Center(
        child: Text('กำลังเก็บค่าปิงสด…', style: M3Text.sub(context)),
      );
    }
    return CustomPaint(
      painter: _LiveChartPainter(
        values: values,
        line: p.cyan,
        spike: p.red,
        grid: p.line,
        label: p.text3,
      ),
      size: Size.infinite,
    );
  }
}

class _LiveChartPainter extends CustomPainter {
  final List<double> values;
  final Color line;
  final Color spike;
  final Color grid;
  final Color label;

  _LiveChartPainter({
    required this.values,
    required this.line,
    required this.spike,
    required this.grid,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ok = values.where((v) => v >= 0).toList()..sort();
    final median = ok[ok.length ~/ 2];
    final maxV = (ok.last * 1.15).clamp(median * 1.5, double.infinity);
    const left = 34.0;
    final w = size.width - left;
    final h = size.height - 14;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 2; i++) {
      final y = h * i / 2;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      tp.text = TextSpan(
        text: '${(maxV * (1 - i / 2)).round()}',
        style: TextStyle(fontSize: 10, color: label, fontFamily: M3Fonts.ui),
      );
      tp.layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    final n = values.length;
    Offset pt(int i) {
      final v = values[i] < 0 ? maxV : values[i];
      return Offset(left + w * (n == 1 ? 1 : i / (n - 1)),
          h - (v / maxV).clamp(0, 1) * h);
    }

    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final fill = Path.from(path)
      ..lineTo(pt(n - 1).dx, h)
      ..lineTo(pt(0).dx, h)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [line.withValues(alpha: 0.35), line.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, h)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    final dot = Paint()..color = spike;
    for (var i = 0; i < n; i++) {
      if (values[i] < 0 || values[i] > median * 1.6) {
        canvas.drawCircle(pt(i), 3.2, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_LiveChartPainter old) =>
      old.values != values || old.line != line;
}

// ── Target ──────────────────────────────────────────────────────────────

class _TargetCard extends StatelessWidget {
  final GameBoostService boost;
  final TextEditingController hostCtrl;
  final VoidCallback onApplyHost;

  const _TargetCard({
    required this.boost,
    required this.hostCtrl,
    required this.onApplyHost,
  });

  /// Emoji flag, or nothing on Windows (Segoe UI Emoji has no flag glyphs
  /// and would show two boxed letters).
  static String flag(String cc) {
    if (cc.length != 2 || isWindows) return '';
    final c = cc.toUpperCase();
    return String.fromCharCodes(
        [0x1F1E6 + c.codeUnitAt(0) - 65, 0x1F1E6 + c.codeUnitAt(1) - 65]);
  }

  @override
  Widget build(BuildContext context) {
    final b = boost;
    final locked = b.isBusy || b.isActive;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.smartRoute,
            title: 'ปลายทาง (เซิร์ฟเวอร์เกม)',
            subtitle: 'เลือกเกมหรือภูมิภาคที่เซิร์ฟเวอร์ตั้งอยู่',
            trailing: locked
                ? const M3Tag('ล็อกระหว่างใช้งาน', tone: M3Tone.neutral)
                : null,
          ),
          const SizedBox(height: 14),
          Text('เกมยอดนิยม', style: M3Text.label(context)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in GameBoostService.games)
                Tooltip(
                  message: g.note,
                  // Presets: tapping one just picks its region below.
                  child: M3Chip(
                    label: g.name,
                    icon: Icons.sports_esports_rounded,
                    onTap: locked
                        ? null
                        : () => b.setRegion(GameBoostService.regions
                            .firstWhere((r) => r.id == g.regionId)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text('ภูมิภาค', style: M3Text.label(context)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in GameBoostService.regions)
                M3Chip(
                  label: isWindows
                      ? r.name
                      : '${flag(r.countryCode)}  ${r.name}',
                  selected: b.customHost == null && b.region.id == r.id,
                  onTap: locked ? null : () => b.setRegion(r),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: M3Field(
                  controller: hostCtrl,
                  label: 'หรือใส่ IP / โดเมนของเซิร์ฟเกมเอง (ไม่บังคับ)',
                  hint: 'เช่น 103.28.54.1:443',
                  mono: true,
                  enabled: !locked,
                  onSubmitted: (_) => onApplyHost(),
                ),
              ),
              const SizedBox(width: 10),
              GlossButton(
                label: 'ใช้',
                variant: GlossVariant.glass,
                onPressed: locked ? null : onApplyHost,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'ค่าที่วัดคือเวลาไป-กลับถึงดาต้าเซ็นเตอร์ของภูมิภาคนั้น '
            '(พอร์ต TCP 443) — เซิร์ฟเวอร์เกมจริงอาจต่างไปเล็กน้อย '
            'ถ้ารู้ IP เซิร์ฟเกม ใส่ไว้ด้านบนจะแม่นที่สุด',
            style: M3Text.sub(context).copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ── Results ─────────────────────────────────────────────────────────────

class _ResultsCard extends StatelessWidget {
  final GameBoostService boost;
  final Future<void> Function(ServerCountry relay) onUse;

  const _ResultsCard({required this.boost, required this.onUse});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final b = boost;
    final rows = <RouteResult>[
      if (b.direct != null) b.direct!,
      ...b.relays,
    ];
    final best = b.recommendation;
    final scores = rows
        .where((r) => r.ok)
        .map((r) => r.sample.medianMs!)
        .toList();
    final worst = scores.isEmpty ? 1.0 : scores.reduce((a, c) => a > c ? a : c);

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.ping,
            title: 'ผลการวัดเส้นทาง',
            subtitle: rows.isEmpty
                ? null
                : 'ไป ${b.targetLabel} · ค่ากลาง (median) ของ 8–10 ครั้ง',
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const M3EmptyState(
              icon3d: M3Icons.ping,
              title: 'ยังไม่ได้วัด',
              message: 'กด "วิเคราะห์เส้นทาง" — จะวัดเส้นทางตรง แล้วลองผ่านรีเลย์ '
                  'ที่ใกล้ปลายทางทีละตัว (ใช้เวลาประมาณ 30–60 วินาที)',
            )
          else ...[
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RouteRow(
                  result: r,
                  recommended: identical(r, best),
                  fraction: r.ok ? r.sample.medianMs! / worst : 0,
                  canUse: !b.isBusy && !b.isActive && r.relay != null && r.ok,
                  onUse: r.relay == null ? null : () => onUse(r.relay!),
                ),
              ),
            if (best != null && b.direct != null && b.direct!.ok)
              _Verdict(
                tone: M3Tone.green,
                text: 'ผ่าน ${best.relay!.countryName} เร็วกว่าเส้นทางตรง '
                    '${((b.direct!.sample.medianMs! - best.sample.medianMs!)).round()} ms '
                    '(${(((b.direct!.sample.medianMs! - best.sample.medianMs!) / b.direct!.sample.medianMs!) * 100).round()}%) '
                    'และกระชากน้อยกว่า',
              )
            else if (b.directIsBest)
              const _Verdict(
                tone: M3Tone.cyan,
                text: 'เส้นทางตรงของคุณดีที่สุดแล้ว — การผ่านรีเลย์จะเพิ่มระยะทาง '
                    'แทนที่จะลด ไม่ต้องเปิดโหมดลดปิงสำหรับปลายทางนี้',
              ),
            if (b.relays.isNotEmpty && b.relays.every((r) => !r.ok))
              _Verdict(
                tone: M3Tone.amber,
                text: 'รีเลย์ทุกตัวเชื่อมต่อไม่สำเร็จ ${!isWindows ? '' : '(บน Windows ต้องเปิดแบบผู้ดูแลระบบ)'}',
              ),
          ],
          if (b.isBusy && b.status != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: p.cyan),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(b.status!, style: M3Text.sub(context))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Verdict extends StatelessWidget {
  final M3Tone tone;
  final String text;
  const _Verdict({required this.tone, required this.text});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.toneSoft(tone),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.toneSoftLine(tone)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: M3Fonts.ui,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.4,
          color: p.isNight ? p.toneText(tone) : p.toneColor(tone),
        ),
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  final RouteResult result;
  final bool recommended;
  final double fraction;
  final bool canUse;
  final VoidCallback? onUse;

  const _RouteRow({
    required this.result,
    required this.recommended,
    required this.fraction,
    required this.canUse,
    this.onUse,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final r = result;
    final s = r.sample;
    final med = s.medianMs;
    final tone = med == null
        ? M3Tone.red
        : med < 60
            ? M3Tone.green
            : med < 120
                ? M3Tone.amber
                : M3Tone.red;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: recommended ? p.greenSoft : p.row,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: recommended ? p.greenSoftLine : p.line.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon3D(r.isDirect ? M3Icons.p2pDirect : M3Icons.relay, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(r.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: M3Text.h3(context)),
                    ),
                    if (recommended) ...[
                      const SizedBox(width: 6),
                      const M3Tag('แนะนำ', tone: M3Tone.green),
                    ],
                    if (r.isDirect) ...[
                      const SizedBox(width: 6),
                      const M3Tag('ISP', tone: M3Tone.neutral),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (r.ok) ...[
                  M3ProgressBar(value: fraction, height: 7, tone: tone),
                  const SizedBox(height: 4),
                  Text(
                    'ต่ำสุด ${_ms(s.minMs)} · กระชาก ${_ms(s.jitterMs)} ms · '
                    'หาย ${s.lossPercent.toStringAsFixed(0)}%',
                    style: M3Text.sub(context).copyWith(fontSize: 11.5),
                  ),
                ] else
                  Text(r.failure ?? 'วัดไม่ได้',
                      style: M3Text.sub(context).copyWith(color: p.red)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    _ms(med),
                    style: M3Text.num(context,
                        size: 26,
                        color: p.toneColor(tone),
                        red: tone == M3Tone.red),
                  ),
                  const SizedBox(width: 2),
                  Text('ms', style: M3Text.sub(context)),
                ],
              ),
              if (onUse != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: GlossButton(
                    label: 'ใช้เส้นทางนี้',
                    size: GlossSize.small,
                    variant:
                        recommended ? GlossVariant.aqua : GlossVariant.glass,
                    onPressed: canUse ? onUse : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Windows tune-up ─────────────────────────────────────────────────────

class _TuneupCard extends StatelessWidget {
  final GameBoostService boost;
  final bool nagleOff;
  final bool nagleBusy;
  final bool elevated;
  final ValueChanged<bool> onNagle;

  const _TuneupCard({
    required this.boost,
    required this.nagleOff,
    required this.nagleBusy,
    required this.elevated,
    required this.onNagle,
  });

  @override
  Widget build(BuildContext context) {
    final b = boost;
    final a = b.adapter;
    final wifi = a?.isWifi ?? false;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.adapter,
            title: 'ปรับแต่ง Windows',
            subtitle: elevated ? null : 'ต้องเปิดแบบผู้ดูแลระบบ',
          ),
          const SizedBox(height: 12),
          if (a != null)
            M3Inset(
              child: Row(
                children: [
                  Icon3D(wifi ? M3Icons.scan : M3Icons.adapter, size: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${wifi ? 'Wi-Fi' : (a.type == 'ethernet' ? 'สายแลน' : 'เครือข่าย')} · ${a.name}',
                            style: M3Text.h3(context)),
                        Text(
                          '${a.description}${a.speedMbps > 0 ? ' · ${a.speedMbps} Mbps' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: M3Text.sub(context).copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  M3Tag(wifi ? 'Wi-Fi' : 'LAN',
                      tone: wifi ? M3Tone.amber : M3Tone.green),
                ],
              ),
            ),
          if (wifi) ...[
            const SizedBox(height: 10),
            Text(
              'สายแลนให้ปิงนิ่งกว่า Wi-Fi เสมอ — ถ้าเสียบได้ นี่คือการลดปิงที่ได้ผลที่สุด',
              style: M3Text.sub(context).copyWith(fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          M3SwitchRow(
            title: 'หยุดการสแกน Wi-Fi ระหว่างลดปิง',
            subtitle: 'Windows สแกนหา Wi-Fi อื่นทุก ~1 นาที ทำให้ปิงกระชาก '
                '100–300 ms · เปิดคืนอัตโนมัติเมื่อปิดโหมด',
            value: b.wifiTweak && wifi,
            onChanged: wifi && !b.isActive
                ? (v) => b.setTweaks(wifi: v)
                : null,
          ),
          M3SwitchRow(
            title: 'แผนพลังงานประสิทธิภาพสูงระหว่างลดปิง',
            subtitle: 'กันซีพียู/การ์ดแลนเข้าโหมดประหยัดไฟที่หน่วงแพ็กเก็ต '
                '· คืนแผนเดิมเมื่อปิดโหมด',
            value: b.powerTweak,
            onChanged: b.isActive ? null : (v) => b.setTweaks(power: v),
          ),
          M3SwitchRow(
            title: 'ปิด Nagle (เกมที่ใช้ TCP)',
            subtitle: 'ส่งแพ็กเก็ตเล็กทันทีไม่รอรวม ช่วยเกม MMO/TCP · '
                'เกมยิงส่วนใหญ่ใช้ UDP ไม่ได้ผล · คงอยู่จนกว่าจะปิดสวิตช์',
            value: nagleOff,
            onChanged: elevated && a != null && !nagleBusy ? onNagle : null,
          ),
          if (b.isActive && b.tweakNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final n in b.tweakNotes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_rounded,
                        size: 16, color: context.m3.green),
                    const SizedBox(width: 6),
                    Expanded(child: Text(n, style: M3Text.sub(context))),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Bufferbloat ─────────────────────────────────────────────────────────

class _BufferbloatCard extends StatelessWidget {
  final GameBoostService boost;
  const _BufferbloatCard({required this.boost});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final r = boost.bufferbloat;
    final (tone, advice) = switch (r?.grade) {
      'A' => (M3Tone.green, 'ยอดเยี่ยม — เน็ตบ้านไม่หน่วงแม้มีคนโหลดไฟล์'),
      'B' => (M3Tone.green, 'ดี — มีหน่วงเล็กน้อยตอนเน็ตถูกใช้หนัก'),
      'C' => (M3Tone.amber,
          'ปิงพุ่งเมื่อมีคนโหลด/ดูสตรีม — เปิด QoS/SQM ในเราเตอร์ หรือจำกัดความเร็วดาวน์โหลดตอนเล่นเกม'),
      'D' => (M3Tone.red,
          'หน่วงมากเมื่อเน็ตถูกใช้ — แนะนำเปิด SQM (fq_codel/CAKE) หรือเปลี่ยนเราเตอร์'),
      'F' => (M3Tone.red,
          'เราเตอร์คิวเต็มจนปิงพุ่งหลายร้อย ms — นี่คือสาเหตุแลคหลักเวลามีคนใช้เน็ต'),
      _ => (M3Tone.cyan, ''),
    };
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.download,
            title: 'ปิงตอนเน็ตถูกใช้หนัก',
            subtitle: 'ทดสอบ Bufferbloat — สาเหตุแลคที่พบบ่อยที่สุดในบ้าน',
            trailing: GlossButton(
              label: r == null ? 'ทดสอบ' : 'ทดสอบใหม่',
              size: GlossSize.small,
              variant: GlossVariant.glass,
              loading: boost.bufferbloatRunning,
              onPressed: boost.bufferbloatRunning || boost.isBusy
                  ? null
                  : boost.runBufferbloatTest,
            ),
          ),
          const SizedBox(height: 12),
          if (boost.bufferbloatRunning)
            Column(
              children: [
                const M3ProgressBar(height: 8),
                const SizedBox(height: 8),
                Text('กำลังดาวน์โหลดเต็มสปีดพร้อมวัดปิง (~10 วินาที)…',
                    style: M3Text.sub(context)),
              ],
            )
          else if (r == null)
            Text(
              'วัดปิงตอนว่าง เทียบกับตอนดาวน์โหลดเต็มสปีด ถ้าปิงพุ่งมาก '
              'แปลว่าเราเตอร์ปล่อยคิวยาว เกมจะแลคทุกครั้งที่มีคนในบ้านใช้เน็ต',
              style: M3Text.sub(context),
            )
          else
            Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: switch (tone) {
                      M3Tone.green => M3Fx.greenGloss,
                      M3Tone.amber => M3Fx.goldGloss,
                      M3Tone.red => M3Fx.redGloss,
                      _ => M3Fx.aquaGloss,
                    },
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white70),
                    boxShadow: [
                      BoxShadow(
                        color: p.toneColor(tone).withValues(alpha: 0.5),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  child: Text(
                    r.grade,
                    style: const TextStyle(
                      fontFamily: M3Fonts.head,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ว่าง ${r.idleMs.round()} ms → ตอนโหลด ${r.loadedMs.round()} ms '
                        '(+${r.increaseMs.round()})',
                        style: M3Text.h3(context),
                      ),
                      Text(
                        'ความเร็วดาวน์โหลด ~${r.downloadMbps.toStringAsFixed(0)} Mbps',
                        style: M3Text.sub(context).copyWith(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(advice, style: M3Text.sub(context)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ── How it works ────────────────────────────────────────────────────────

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final items = [
      (M3Icons.ping, 'วัดจริง ไม่เดา',
          'ส่งการเชื่อมต่อจริงไปยังปลายทางทีละหลายครั้ง ใช้ค่ากลาง ค่ากระชาก และแพ็กเก็ตหาย'),
      (M3Icons.smartRoute, 'เลือกเส้นทางที่ดีกว่า',
          'บางครั้ง ISP ไทยส่งข้อมูลอ้อมผ่านฮ่องกงหรือสหรัฐฯ — รีเลย์ที่อยู่ใกล้เซิร์ฟเกมช่วยตัดทางอ้อมได้'),
      (M3Icons.lock, 'ซื่อตรงกับตัวเลข',
          'ถ้าเส้นทางตรงดีกว่า แอปจะบอกตรง ๆ ว่าไม่ต้องใช้ ระยะทางจริงลดไม่ได้ (ไทย→ยุโรป ต่ำสุดราว 150 ms)'),
    ];
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(icon3d: M3Icons.gameBoost, title: 'ลดปิงได้อย่างไร'),
          const SizedBox(height: 10),
          for (final (icon, title, text) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon3D(icon, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: M3Text.h3(context)),
                        Text(text, style: M3Text.sub(context)),
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
}
