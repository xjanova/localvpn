import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';
import 'kyc_verification_screen.dart';
import 'trophy_screen.dart';

/// "โปรไฟล์" — the Torrent profile: name, rank and score in a chrome-ringed
/// hero, sharing stats, earned trophies and the KYC (18+) status.
class UserProfileScreen extends StatefulWidget {
  final TorrentService torrentService;

  const UserProfileScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  TorrentService get t => widget.torrentService;

  bool _initialLoad = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    t.addListener(_onChanged);
    _firstLoad();
  }

  @override
  void dispose() {
    t.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadData() async {
    await Future.wait([
      t.fetchUserProfile(),
      t.fetchKycStatus(),
    ]);
  }

  Future<void> _firstLoad() async {
    await _loadData();
    if (!mounted) return;
    setState(() => _initialLoad = false);
  }

  Future<void> _refresh() async {
    if (_refreshing || _initialLoad) return;
    setState(() => _refreshing = true);
    await _loadData();
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  void _openTrophies() {
    Navigator.of(context).push(M3PageRoute(
      builder: (_) => TrophyScreen(torrentService: t),
    ));
  }

  void _openKyc() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(M3PageRoute(
      builder: (_) => KycVerificationScreen(torrentService: t),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final stats = t.userStats;
    final busy = _initialLoad || _refreshing;

    return M3PageBody(
      onRefresh: _refresh,
      children: [
        M3PageHeader(
          icon3d: M3Icons.profile,
          title: 'โปรไฟล์',
          subtitle: 'สถิติการแชร์ไฟล์ ถ้วยรางวัล และการยืนยันตัวตน',
          onBack: () => Navigator.of(context).pop(),
          trailing: _RefreshButton(busy: busy, onPressed: _refresh),
        ),
        const SizedBox(height: 16),
        if (stats == null && _initialLoad)
          const _LoadingPanel(message: 'กำลังโหลดโปรไฟล์…')
        else ...[
          if (stats == null) ...[
            M3Banner(
              tone: M3Tone.amber,
              icon3d: M3Icons.profile,
              title: 'ยังโหลดสถิติไม่ได้',
              message: 'ตรวจสอบการเชื่อมต่ออินเทอร์เน็ตแล้วลองใหม่ '
                  '(ยังดูถ้วยรางวัลและยืนยันตัวตนได้ตามปกติ)',
              action: GlossButton(
                label: 'ลองใหม่',
                size: GlossSize.small,
                variant: GlossVariant.glass,
                loading: _refreshing,
                onPressed: _refreshing ? null : _refresh,
              ),
            ),
            const SizedBox(height: 14),
          ],
          _Hero(
            stats: stats,
            trophies: t.userTrophies,
            kycStatus: t.kycStatus,
          ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 980;
            final statsBlock = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const M3SectionTitle('สถิติ'),
                _StatGrid(stats: stats, wide: wide),
              ],
            ).animate().fadeIn(delay: 80.ms, duration: 350.ms);
            final side = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TrophyCard(trophies: t.userTrophies, onOpen: _openTrophies),
                const SizedBox(height: 16),
                _KycCard(status: t.kycStatus, onVerify: _openKyc),
              ],
            ).animate().fadeIn(delay: 140.ms, duration: 350.ms);

            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: statsBlock),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 4,
                    child: Padding(
                      // Line up with the cards under the section title.
                      padding: const EdgeInsets.only(top: 38),
                      child: side,
                    ),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                statsBlock,
                const SizedBox(height: 16),
                side,
              ],
            );
          }),
        ],
      ],
    );
  }
}

// ── KYC wording ─────────────────────────────────────────────────────────

(M3Tone, String) _kycInfo(String? status) => switch (status) {
      'approved' => (M3Tone.green, 'ยืนยันตัวตนแล้ว'),
      'pending' => (M3Tone.amber, 'รอการอนุมัติ'),
      'rejected' => (M3Tone.red, 'ถูกปฏิเสธ'),
      _ => (M3Tone.neutral, 'ยังไม่ได้ยืนยัน'),
    };

// ── Hero ────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final BtUserStats? stats;
  final List<BtTrophy> trophies;
  final String? kycStatus;

  const _Hero({
    required this.stats,
    required this.trophies,
    required this.kycStatus,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => _build(context, narrow: c.maxWidth < 760),
    );
  }

  Widget _build(BuildContext context, {required bool narrow}) {
    final p = context.m3;
    final s = stats;
    final rank = s?.rankPosition ?? 0;
    final (kycTone, kycText) = _kycInfo(kycStatus);
    final name = (s?.displayName?.trim().isNotEmpty ?? false)
        ? s!.displayName!.trim()
        : 'ไม่ระบุชื่อ';

    final metrics = <(String, String, Color?)>[
      ('อันดับ', rank > 0 ? '#$rank' : '—', rank > 0 ? p.gold : null),
      ('สกอร์', s == null ? '—' : '${s.score}', null),
      ('ถ้วยรางวัล', '${trophies.length}', null),
    ];

    final avatar = _ChromeAvatar(size: narrow ? 84 : 124);

    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 22 : 30,
            fontWeight: FontWeight.w700,
            color: p.text,
            height: 1.2,
            shadows: p.titleShadow,
          ),
        ),
        if (trophies.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            trophies.map((x) => x.badgeText).take(5).join(''),
            style: const TextStyle(fontSize: 16),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            M3Tag(rank > 0 ? 'อันดับ #$rank' : 'ยังไม่มีอันดับ',
                tone: M3Tone.gold),
            M3Tag('สกอร์ ${s?.score ?? 0}', tone: M3Tone.cyan),
            M3Tag('KYC: $kycText', tone: kycTone, dot: true),
          ],
        ),
      ],
    );

    final metricRow = Wrap(
      spacing: narrow ? 22 : 34,
      runSpacing: 10,
      children: [
        for (final (label, value, color) in metrics)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: M3Text.num(context,
                      size: narrow ? 22 : 28, color: color)),
              Text(label,
                  style: M3Text.sub(context).copyWith(fontSize: 11.5)),
            ],
          ),
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: kycStatus == 'approved' ? p.green : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    avatar,
                    const SizedBox(width: 14),
                    Expanded(child: nameBlock),
                  ],
                ),
                const M3GoldLine(margin: EdgeInsets.symmetric(vertical: 14)),
                metricRow,
              ],
            )
          : Row(
              children: [
                avatar,
                const SizedBox(width: 22),
                Expanded(child: nameBlock),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 22),
                  child: SizedBox(
                    height: 84,
                    child: RotatedBox(
                      quarterTurns: 1,
                      child: M3GoldLine(margin: EdgeInsets.zero),
                    ),
                  ),
                ),
                metricRow,
              ],
            ),
    );
  }
}

/// The 3D profile icon on a glass plate inside a chrome ring.
class _ChromeAvatar extends StatelessWidget {
  final double size;
  const _ChromeAvatar({required this.size});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.045),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: M3Fx.chrome,
        boxShadow: [BoxShadow(color: p.logoGlow, blurRadius: size * 0.3)],
      ),
      child: Container(
        padding: EdgeInsets.all(size * 0.025),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: M3Fx.goldRing,
        ),
        child: ClipOval(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: p.glassFillHi),
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(
                  child: Opacity(
                    opacity: 0.45,
                    child: DecoratedBox(
                      decoration: BoxDecoration(gradient: M3Fx.btnGloss),
                    ),
                  ),
                ),
                Icon3D(M3Icons.profile, size: size * 0.66),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Stats ───────────────────────────────────────────────────────────────

class _StatGrid extends StatelessWidget {
  final BtUserStats? stats;
  final bool wide;

  const _StatGrid({required this.stats, required this.wide});

  static String _ratio(BtUserStats? s) {
    if (s == null) return '—';
    if (s.totalDownloadedBytes == 0) {
      return s.totalUploadedBytes > 0 ? '∞' : '0.00';
    }
    return s.ratio.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final ratioTone = s == null
        ? null
        : (s.totalDownloadedBytes == 0 && s.totalUploadedBytes == 0)
            ? null
            : (s.ratio >= 1 ? M3Tone.green : M3Tone.amber);

    final tiles = [
      M3StatTile(
        label: 'อัพโหลด',
        value: s?.uploadFormatted ?? '—',
        sub: 'ข้อมูลที่ส่งให้คนอื่น',
        icon3d: M3Icons.upload,
        tone: M3Tone.green,
      ),
      M3StatTile(
        label: 'ดาวน์โหลด',
        value: s?.downloadFormatted ?? '—',
        sub: 'ข้อมูลที่รับมา',
        icon3d: M3Icons.download,
        tone: M3Tone.cyan,
      ),
      M3StatTile(
        label: 'ไฟล์แชร์',
        value: s == null ? '—' : '${s.totalFilesShared}',
        sub: 'ไฟล์ที่อัปโหลดเข้าคลัง',
        icon3d: M3Icons.folder,
      ),
      M3StatTile(
        label: 'ไฟล์ดาวน์โหลด',
        value: s == null ? '—' : '${s.totalFilesDownloaded}',
        sub: 'ไฟล์ที่โหลดจากคลัง',
        icon3d: M3Icons.file,
      ),
      M3StatTile(
        label: 'เวลา Seed',
        value: s?.seedTimeFormatted ?? '—',
        sub: 'เวลาที่เปิดแชร์ให้คนอื่น',
        icon3d: M3Icons.torrent,
        tone: M3Tone.amber,
      ),
      M3StatTile(
        label: 'Ratio',
        value: _ratio(s),
        sub: 'อัปโหลด ÷ ดาวน์โหลด',
        icon3d: M3Icons.p2pDirect,
        tone: ratioTone,
      ),
    ];

    return LayoutBuilder(builder: (context, c) {
      final cols = wide
          ? 2
          : c.maxWidth >= 860
              ? 3
              : c.maxWidth >= 400
                  ? 2
                  : 1;
      const gap = 14.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final x in tiles) SizedBox(width: w, child: x)],
      );
    });
  }
}

// ── Trophies preview ────────────────────────────────────────────────────

class _TrophyCard extends StatelessWidget {
  final List<BtTrophy> trophies;
  final VoidCallback onOpen;

  const _TrophyCard({required this.trophies, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.trophy,
            title: 'ถ้วยรางวัล',
            subtitle: '${trophies.length} รางวัล',
          ),
          const SizedBox(height: 12),
          if (trophies.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon3D(M3Icons.trophy, size: 44, opacity: 0.45),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('ยังไม่มีรางวัล เริ่มแชร์ไฟล์เลย!',
                        style: M3Text.sub(context).copyWith(fontSize: 13)),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final x in trophies)
                  Tooltip(
                    message: '${x.name} - ${x.description}',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: p.inset,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.toneSoftLine(M3Tone.gold)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(x.badgeText,
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              x.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: M3Text.body(context)
                                  .copyWith(fontSize: 12, color: p.text2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 14),
          GlossButton(
            label: 'ดูทั้งหมด',
            icon3d: M3Icons.trophy,
            variant: GlossVariant.glass,
            expand: true,
            onPressed: onOpen,
          ),
        ],
      ),
    );
  }
}

// ── KYC ─────────────────────────────────────────────────────────────────

class _KycCard extends StatelessWidget {
  final String? status;
  final VoidCallback onVerify;

  const _KycCard({required this.status, required this.onVerify});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final (tone, text) = _kycInfo(status);
    final canVerify = status != 'approved' && status != 'pending';
    return GlassPanel(
      accent: tone == M3Tone.neutral ? null : p.toneColor(tone),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.kyc,
            title: 'ยืนยันตัวตน (KYC)',
            subtitle: 'สำหรับหมวดเนื้อหา 18+',
            trailing: M3Tag(text, tone: tone, dot: true),
          ),
          const SizedBox(height: 12),
          Text(
            status == 'rejected'
                ? 'ข้อมูลที่ส่งไปไม่ผ่านการตรวจสอบ ส่งข้อมูลใหม่ได้อีกครั้ง '
                    '— ต้องมีอายุ 18 ปีขึ้นไป'
                : status == 'pending'
                    ? 'ส่งข้อมูลแล้ว รอแอดมินตรวจสอบและอนุมัติ'
                    : status == 'approved'
                        ? 'ยืนยันอายุเรียบร้อย เข้าถึงเนื้อหา 18+ ได้แล้ว'
                        : 'ยืนยันตัวตนเพื่อเข้าถึงเนื้อหา 18+ ต้องมีอายุ 18 ปีขึ้นไป',
            style: M3Text.sub(context).copyWith(fontSize: 13),
          ),
          if (canVerify) ...[
            const SizedBox(height: 14),
            GlossButton(
              label: status == 'rejected' ? 'ยืนยันตัวตนอีกครั้ง' : 'ยืนยันตัวตน',
              icon3d: M3Icons.kyc,
              expand: true,
              onPressed: onVerify,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────

class _RefreshButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onPressed;

  const _RefreshButton({required this.busy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 34,
        height: 34,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return GlossIconButton(
      icon: Icons.refresh_rounded,
      tooltip: 'รีเฟรช',
      onPressed: onPressed,
    );
  }
}

class _LoadingPanel extends StatelessWidget {
  final String message;
  const _LoadingPanel({required this.message});

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 44),
        child: Column(
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 14),
            Text(message, style: M3Text.sub(context)),
          ],
        ),
      ),
    );
  }
}
