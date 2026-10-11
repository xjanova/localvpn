import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';

/// "ถ้วยรางวัล" — every trophy as a glass tile, grouped by difficulty.
/// Unlocked tiles are full colour with a gold edge; locked tiles are dimmed
/// with a lock and a progress bar toward unlocking (computed from the
/// user's stats with the same rules the server uses).
class TrophyScreen extends StatefulWidget {
  final TorrentService torrentService;

  const TrophyScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<TrophyScreen> createState() => _TrophyScreenState();
}

class _TrophyScreenState extends State<TrophyScreen> {
  TorrentService get t => widget.torrentService;

  /// The service has no loading flag for trophies, so track the first
  /// load here (otherwise the error state flashes before data arrives).
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
      t.fetchAllTrophies(),
      t.fetchUserProfile(),
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

  void _openTrophy(BtTrophy trophy, BtTrophy? awarded) {
    if (awarded != null) {
      SoundService().play(SfxType.coin);
      HapticFeedback.lightImpact();
    } else {
      SoundService().play(SfxType.tap);
    }
    final progress = _TrophyProgress.of(trophy, t.userStats);
    showM3Dialog(
      context,
      icon3d: awarded != null ? M3Icons.trophy : M3Icons.lock,
      title: trophy.name,
      content: _TrophyDetail(
        trophy: trophy,
        awarded: awarded,
        progress: progress,
      ),
      actions: (ctx) => [
        GlossButton(
          label: 'ปิด',
          variant: GlossVariant.glass,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = t.allTrophies;
    final awarded = {for (final a in t.userTrophies) a.id: a};
    final list = [for (final l in all.values) ...l];
    final total = list.length;
    final got = list.where((x) => awarded.containsKey(x.id)).length;
    final busy = _initialLoad || _refreshing;

    final keys = [
      for (final d in _order)
        if (all[d] != null && all[d]!.isNotEmpty) d,
      for (final d in all.keys.toList()..sort())
        if (!_order.contains(d) && all[d]!.isNotEmpty) d,
    ];

    return M3PageBody(
      onRefresh: _refresh,
      children: [
        M3PageHeader(
          icon3d: M3Icons.trophy,
          title: 'ถ้วยรางวัล',
          subtitle: total == 0 ? 'สะสมรางวัลจากการแชร์ไฟล์' : 'ได้รับ $got / $total รางวัล',
          onBack: () => Navigator.of(context).pop(),
          trailing: _RefreshButton(busy: busy, onPressed: _refresh),
        ),
        const SizedBox(height: 16),
        if (all.isEmpty)
          busy
              ? const _LoadingPanel(message: 'กำลังโหลดถ้วยรางวัล…')
              : GlassPanel(
                  child: M3EmptyState(
                    icon3d: M3Icons.trophy,
                    title: 'ไม่สามารถโหลดข้อมูลได้',
                    message: 'ตรวจสอบการเชื่อมต่ออินเทอร์เน็ตแล้วลองใหม่',
                    action: GlossButton(
                      label: 'ลองใหม่',
                      icon: Icons.refresh_rounded,
                      loading: _refreshing,
                      onPressed: _refreshing ? null : _refresh,
                    ),
                  ),
                )
        else ...[
          _Hero(
            got: got,
            total: total,
            earned: [
              for (final x in list)
                if (awarded.containsKey(x.id)) x,
            ],
            breakdown: [
              for (final d in keys)
                (
                  d,
                  all[d]!.where((x) => awarded.containsKey(x.id)).length,
                  all[d]!.length,
                ),
            ],
          ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
          const SizedBox(height: 18),
          for (final d in keys) ...[
            M3SectionTitle(
              _diffLabel(d),
              trailing: M3Tag(
                'ได้ ${all[d]!.where((x) => awarded.containsKey(x.id)).length}/${all[d]!.length}',
                tone: _diffTone(d),
              ),
            ),
            _TrophyGrid(
              trophies: all[d]!,
              awarded: awarded,
              stats: t.userStats,
              onOpen: _openTrophy,
            ).animate().fadeIn(delay: 80.ms, duration: 350.ms),
            const SizedBox(height: 18),
          ],
        ],
      ],
    );
  }
}

const _order = ['easy', 'medium', 'hard'];

String _diffLabel(String d) => switch (d) {
      'easy' => 'ง่าย',
      'medium' => 'ปานกลาง',
      'hard' => 'ยาก',
      _ => d,
    };

M3Tone _diffTone(String d) => switch (d) {
      'easy' => M3Tone.green,
      'medium' => M3Tone.amber,
      'hard' => M3Tone.red,
      _ => M3Tone.neutral,
    };

String _formatDate(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final d = DateTime.tryParse(raw);
  if (d == null) return raw;
  final l = d.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}

/// Progress toward a trophy, using the same requirement types the server
/// checks (GlobalTorrentController::checkTrophies). Types that depend on
/// data the app does not have return a label only.
class _TrophyProgress {
  final double? value;
  final String label;

  const _TrophyProgress(this.value, this.label);

  static _TrophyProgress of(BtTrophy x, BtUserStats? s) {
    final need = x.requirementValue;
    double ratio(num cur) =>
        need <= 0 ? 1.0 : (cur / need).clamp(0.0, 1.0).toDouble();
    String n(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

    switch (x.requirementType) {
      case 'files_shared':
        final cur = s?.totalFilesShared ?? 0;
        return _TrophyProgress(ratio(cur), 'แชร์ไฟล์ $cur / $need ไฟล์');
      case 'files_downloaded':
        final cur = s?.totalFilesDownloaded ?? 0;
        return _TrophyProgress(ratio(cur), 'ดาวน์โหลด $cur / $need ไฟล์');
      case 'uploaded_gb':
        final cur = (s?.totalUploadedBytes ?? 0) / (1024 * 1024 * 1024);
        return _TrophyProgress(
            ratio(cur), 'อัปโหลด ${n(cur)} / $need GB');
      case 'seed_hours':
        final cur = (s?.seedTimeSeconds ?? 0) / 3600;
        return _TrophyProgress(ratio(cur), 'Seed ${n(cur)} / $need ชม.');
      case 'rank_position':
        final rank = s?.rankPosition ?? 0;
        if (rank <= 0) {
          return _TrophyProgress(0, 'ยังไม่มีอันดับ · เป้าหมาย Top $need');
        }
        return _TrophyProgress(
          rank <= need ? 1.0 : (need / rank).clamp(0.0, 1.0).toDouble(),
          'อันดับปัจจุบัน #$rank · เป้าหมาย Top $need',
        );
      case 'account_created':
        return const _TrophyProgress(1, 'ได้รับเมื่อเริ่มใช้งาน');
      case 'total_downloads_received':
        return _TrophyProgress(
            null, 'มีคนดาวน์โหลดไฟล์ของคุณรวม $need ครั้ง');
      case 'seed_count':
        return _TrophyProgress(null, 'Seed ไฟล์ให้คนอื่น $need ไฟล์');
      case 'categories_shared':
        return _TrophyProgress(null, 'แชร์ไฟล์ใน $need หมวด');
      default:
        return _TrophyProgress(null, 'เป้าหมาย $need');
    }
  }
}

// ── Hero ────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final int got;
  final int total;
  final List<BtTrophy> earned;
  final List<(String, int, int)> breakdown;

  const _Hero({
    required this.got,
    required this.total,
    required this.earned,
    required this.breakdown,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final progress = total > 0 ? got / total : 0.0;
    final complete = total > 0 && got >= total;

    final icon = Icon3D(
      M3Icons.trophy,
      size: narrow ? 86 : 124,
      glow: p.gold.withValues(alpha: complete ? 0.6 : 0.35),
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          complete ? 'สะสมครบทุกรางวัลแล้ว!' : 'ความคืบหน้า',
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 20 : 24,
            fontWeight: FontWeight.w700,
            color: complete ? p.gold : p.text,
            shadows: p.titleShadow,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('$got',
                style: M3Text.num(context,
                    size: narrow ? 34 : 44, color: p.gold)),
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4),
              child: Text('/ $total รางวัล',
                  style: M3Text.sub(context).copyWith(fontSize: 14)),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${(progress * 100).round()}%',
                  style: M3Text.num(context, size: narrow ? 18 : 22)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        M3ProgressBar(value: progress, tone: M3Tone.gold, height: 12),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (d, a, b) in breakdown)
              M3Tag('${_diffLabel(d)} $a/$b', tone: _diffTone(d)),
          ],
        ),
        if (earned.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final x in earned)
                Tooltip(
                  message: x.name,
                  child: Text(x.badgeText,
                      style: const TextStyle(fontSize: 20)),
                ),
            ],
          ),
        ],
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: complete ? p.gold : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: Row(
        crossAxisAlignment: narrow
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          icon,
          SizedBox(width: narrow ? 14 : 22),
          Expanded(child: text),
        ],
      ),
    );
  }
}

// ── Grid ────────────────────────────────────────────────────────────────

class _TrophyGrid extends StatelessWidget {
  final List<BtTrophy> trophies;
  final Map<int, BtTrophy> awarded;
  final BtUserStats? stats;
  final void Function(BtTrophy trophy, BtTrophy? awarded) onOpen;

  const _TrophyGrid({
    required this.trophies,
    required this.awarded,
    required this.stats,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 1000
          ? 4
          : c.maxWidth >= 680
              ? 3
              : 2;
      const gap = 12.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final x in trophies)
            SizedBox(
              width: w,
              child: _TrophyTile(
                trophy: x,
                awarded: awarded[x.id],
                progress: _TrophyProgress.of(x, stats),
                onTap: () => onOpen(x, awarded[x.id]),
              ),
            ),
        ],
      );
    });
  }
}

/// Greyscale filter for locked trophy emoji.
const ColorFilter _greyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

class _TrophyTile extends StatefulWidget {
  final BtTrophy trophy;
  final BtTrophy? awarded;
  final _TrophyProgress progress;
  final VoidCallback onTap;

  const _TrophyTile({
    required this.trophy,
    required this.awarded,
    required this.progress,
    required this.onTap,
  });

  @override
  State<_TrophyTile> createState() => _TrophyTileState();
}

class _TrophyTileState extends State<_TrophyTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final x = widget.trophy;
    final unlocked = widget.awarded != null;
    final narrow = MediaQuery.sizeOf(context).width < 600;

    final badge = Container(
      width: narrow ? 46 : 54,
      height: narrow ? 46 : 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: unlocked ? M3Fx.goldFrame : null,
        color: unlocked ? null : p.inset,
        borderRadius: BorderRadius.circular(14),
        border: unlocked ? null : Border.all(color: p.line),
        boxShadow: unlocked ? M3Fx.goldGlow : null,
      ),
      padding: unlocked ? const EdgeInsets.all(1.8) : EdgeInsets.zero,
      child: Container(
        alignment: Alignment.center,
        decoration: unlocked
            ? BoxDecoration(
                gradient: M3Fx.proPlate,
                borderRadius: BorderRadius.circular(12.5),
              )
            : null,
        child: Text(
          x.icon.isNotEmpty ? x.icon : x.badgeText,
          style: TextStyle(fontSize: narrow ? 22 : 26, height: 1.1),
        ),
      ),
    );

    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            unlocked ? badge : ColorFiltered(colorFilter: _greyscale, child: badge),
            const Spacer(),
            if (unlocked)
              Icon(Icons.check_circle_rounded, color: p.green, size: 20)
            else
              const Icon3D(M3Icons.lock, size: 28),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: Text(
            x.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: M3Text.h3(context).copyWith(
              height: 1.35,
              color: unlocked ? p.text : p.text2,
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: 52,
          child: Text(
            x.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: M3Text.sub(context).copyWith(fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );

    final foot = unlocked
        ? Row(
            children: [
              if (x.badgeText.isNotEmpty) ...[
                Text(x.badgeText, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _formatDate(widget.awarded?.awardedAt).isEmpty
                      ? 'ได้รับแล้ว'
                      : 'ได้รับ ${_formatDate(widget.awarded?.awardedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: M3Text.sub(context)
                      .copyWith(fontSize: 11.5, color: p.gold),
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.progress.value != null) ...[
                M3ProgressBar(value: widget.progress.value, height: 8),
                const SizedBox(height: 6),
              ],
              Text(
                widget.progress.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: M3Text.sub(context).copyWith(fontSize: 11.5),
              ),
            ],
          );

    final tile = GlassPanel(
      highlight: unlocked || _hover,
      accent: unlocked ? p.gold : null,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          unlocked ? head : Opacity(opacity: 0.55, child: head),
          const SizedBox(height: 10),
          foot,
        ],
      ),
    );

    return Semantics(
      button: true,
      label: x.name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hover ? 1.02 : 1,
            duration: const Duration(milliseconds: 140),
            child: tile,
          ),
        ),
      ),
    );
  }
}

// ── Detail dialog ───────────────────────────────────────────────────────

class _TrophyDetail extends StatelessWidget {
  final BtTrophy trophy;
  final BtTrophy? awarded;
  final _TrophyProgress progress;

  const _TrophyDetail({
    required this.trophy,
    required this.awarded,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final unlocked = awarded != null;
    final date = _formatDate(awarded?.awardedAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        M3Inset(
          child: Row(
            children: [
              Text(
                trophy.icon.isNotEmpty ? trophy.icon : trophy.badgeText,
                style: const TextStyle(fontSize: 34),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(trophy.description,
                    style: M3Text.body(context).copyWith(color: p.text2)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        M3KeyValue('ระดับ', _diffLabel(trophy.difficulty)),
        M3KeyValue('สถานะ', unlocked ? 'ได้รับแล้ว' : 'ยังไม่ได้รับ'),
        if (trophy.badgeText.isNotEmpty) M3KeyValue('เหรียญ', trophy.badgeText),
        if (unlocked && date.isNotEmpty) M3KeyValue('ได้รับเมื่อ', date),
        if (!unlocked) ...[
          const SizedBox(height: 10),
          if (progress.value != null) ...[
            M3ProgressBar(value: progress.value),
            const SizedBox(height: 6),
          ],
          Text(progress.label, style: M3Text.sub(context)),
        ],
      ],
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
