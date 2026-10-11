import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';

/// "อันดับผู้ใช้" — the top 50 sharers: a 3D podium for the top three
/// (gold / silver / bronze), then the rest of the table. The current user's
/// row is highlighted.
class LeaderboardScreen extends StatefulWidget {
  final TorrentService torrentService;

  const LeaderboardScreen({
    super.key,
    required this.torrentService,
  });

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  TorrentService get t => widget.torrentService;

  /// True until the first fetch finishes (full-page spinner only then).
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

  Future<void> _firstLoad() async {
    await Future.wait([
      t.fetchLeaderboard(),
      // Needed to find "you" in the table.
      if (t.userStats == null) t.fetchUserProfile(),
    ]);
    if (!mounted) return;
    setState(() => _initialLoad = false);
  }

  Future<void> _refresh() async {
    if (_refreshing || _initialLoad) return;
    setState(() => _refreshing = true);
    await t.fetchLeaderboard();
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (t.error != null && t.leaderboard.isNotEmpty) {
      m3Toast(context, t.error!, tone: M3Tone.red);
    }
  }

  /// Index of the current user in [board], matched by display name (and
  /// rank when several people share a name).
  static int? _myIndex(List<BtLeaderboardEntry> board, BtUserStats? s) {
    if (s == null) return null;
    final name = s.displayName;
    if (name != null && name.isNotEmpty) {
      final byName = [
        for (var i = 0; i < board.length; i++)
          if (board[i].displayName == name) i,
      ];
      if (byName.length == 1) return byName.first;
      for (final i in byName) {
        if (board[i].rank == s.rankPosition) return i;
      }
      return null;
    }
    if (s.rankPosition > 0) {
      final i = board.indexWhere((e) => e.rank == s.rankPosition);
      return i < 0 ? null : i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final board = t.leaderboard;
    final stats = t.userStats;
    final busy = _initialLoad || _refreshing;
    final me = _myIndex(board, stats);

    return M3PageBody(
      onRefresh: _refresh,
      children: [
        M3PageHeader(
          icon3d: M3Icons.leaderboard,
          title: 'อันดับผู้ใช้',
          subtitle: 'Top 50 สกอร์สูงสุด',
          onBack: () => Navigator.of(context).pop(),
          trailing: _RefreshButton(busy: busy, onPressed: _refresh),
        ),
        const SizedBox(height: 16),
        if (board.isEmpty)
          busy
              ? const _LoadingPanel(message: 'กำลังโหลดอันดับ…')
              : GlassPanel(
                  child: M3EmptyState(
                    icon3d: M3Icons.leaderboard,
                    title: t.error != null
                        ? 'โหลดอันดับไม่สำเร็จ'
                        : 'ยังไม่มีข้อมูลอันดับ',
                    message: t.error ??
                        'เริ่มแชร์และ Seed ไฟล์เพื่อเป็นคนแรกในตาราง',
                    action: GlossButton(
                      label: 'ลองใหม่',
                      icon: Icons.refresh_rounded,
                      variant: GlossVariant.glass,
                      loading: _refreshing,
                      onPressed: _refreshing ? null : _refresh,
                    ),
                  ),
                )
        else
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 1000;
            final podium = _PodiumCard(
              top: board.take(3).toList(),
              myIndex: me,
            ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0);
            final you = (me == null && stats != null && stats.rankPosition > 0)
                ? _YouStrip(stats: stats)
                : null;
            final table = board.length > 3
                ? _TableCard(board: board, myIndex: me)
                    .animate()
                    .fadeIn(delay: 80.ms, duration: 350.ms)
                : null;

            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        podium,
                        if (you != null) ...[
                          const SizedBox(height: 14),
                          you,
                        ],
                      ],
                    ),
                  ),
                  if (table != null) ...[
                    const SizedBox(width: 16),
                    Expanded(flex: 6, child: table),
                  ],
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                podium,
                if (you != null) ...[const SizedBox(height: 14), you],
                if (table != null) ...[const SizedBox(height: 16), table],
              ],
            );
          }),
      ],
    );
  }
}

// ── Medal look ──────────────────────────────────────────────────────────

/// Bronze frame — same construction as [M3Fx.goldFrame]/[M3Fx.silverFrame]
/// (identical in both palettes, like the PRO badge).
const LinearGradient _bronzeFrame = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color(0xFF7A3E12),
    Color(0xFFF6C08A),
    Color(0xFFB8651F),
    Color(0xFFFFDDB8),
    Color(0xFF8A4A16),
  ],
  stops: [0, 0.22, 0.48, 0.74, 1],
);

const LinearGradient _bronzePlate = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Color(0xFF40281A),
    Color(0xFF24160C),
    Color(0xFF0D0804),
    Color(0xFF1F130A),
  ],
  stops: [0, 0.48, 0.52, 1],
);

const List<BoxShadow> _silverGlow = [
  BoxShadow(color: Color(0x59E9F1F7), blurRadius: 16),
];
const List<BoxShadow> _bronzeGlow = [
  BoxShadow(color: Color(0x73E08A3C), blurRadius: 16),
];
const List<Shadow> _silverTextGlow = [
  Shadow(color: Color(0x99E9F1F7), blurRadius: 12),
];
const List<Shadow> _bronzeTextGlow = [
  Shadow(color: Color(0xB3F0A25A), blurRadius: 12),
];

class _Medal {
  final LinearGradient frame;
  final LinearGradient plate;
  final List<BoxShadow> glow;
  final List<Shadow> textGlow;

  const _Medal(this.frame, this.plate, this.glow, this.textGlow);

  static _Medal of(int place) => switch (place) {
        1 => const _Medal(
            M3Fx.goldFrame, M3Fx.proPlate, M3Fx.goldGlow, M3Fx.proGlow),
        2 => const _Medal(
            M3Fx.silverFrame, M3Fx.freePlate, _silverGlow, _silverTextGlow),
        _ => const _Medal(
            _bronzeFrame, _bronzePlate, _bronzeGlow, _bronzeTextGlow),
      };
}

/// Score colour per podium place, from the active palette.
Color _placeColor(M3Palette p, int place) => switch (place) {
      1 => p.gold,
      2 => p.text2,
      _ => p.orange,
    };

/// One or two letters for an avatar. Thai names starting with a leading
/// vowel (เ แ โ ใ ไ) keep the consonant that follows it.
String _initials(String name) {
  final chars = name.trim().characters;
  if (chars.isEmpty) return '?';
  final first = chars.first;
  if ('เแโใไ'.contains(first) && chars.length > 1) {
    return chars.take(2).toString();
  }
  return first.toUpperCase();
}

// ── Podium ──────────────────────────────────────────────────────────────

class _PodiumCard extends StatelessWidget {
  final List<BtLeaderboardEntry> top;
  final int? myIndex;

  const _PodiumCard({required this.top, required this.myIndex});

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      padding: EdgeInsets.fromLTRB(
          narrow ? 12 : 22, narrow ? 16 : 22, narrow ? 12 : 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('TOP 3', style: M3Text.eyebrow(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text('ผู้แชร์ไฟล์อันดับต้น',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: M3Text.h2(context)),
              ),
            ],
          ),
          const M3GoldLine(margin: EdgeInsets.only(top: 10, bottom: 6)),
          LayoutBuilder(builder: (context, c) {
            // Each spot carries gap/2 padding on both sides.
            const gap = 8.0;
            final usable = c.maxWidth.clamp(0.0, 720.0);
            final colW = (usable / 3 - gap).clamp(0.0, 230.0);
            final compact = colW < 130;
            final order = <int>[
              if (top.length > 1) 1,
              0,
              if (top.length > 2) 2,
            ];
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final i in order)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: gap / 2),
                    child: SizedBox(
                      width: colW,
                      child: _PodiumSpot(
                        entry: top[i],
                        place: i + 1,
                        me: myIndex == i,
                        compact: compact,
                      ),
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _PodiumSpot extends StatelessWidget {
  final BtLeaderboardEntry entry;
  final int place;
  final bool me;
  final bool compact;

  const _PodiumSpot({
    required this.entry,
    required this.place,
    required this.me,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final medal = _Medal.of(place);
    final first = place == 1;
    final avatar = first ? (compact ? 70.0 : 96.0) : (compact ? 56.0 : 76.0);
    final plinth = switch (place) {
      1 => compact ? 82.0 : 112.0,
      2 => compact ? 60.0 : 82.0,
      _ => compact ? 46.0 : 62.0,
    };
    final crown = avatar * 0.62;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: avatar + (first ? crown * 0.55 : 0),
          width: avatar + 8,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              _MedalAvatar(
                name: entry.displayName,
                medal: medal,
                size: avatar,
              ),
              if (first)
                Positioned(
                  top: 0,
                  child: Icon3D(M3Icons.crown, size: crown),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: entry.displayName,
          child: Text(
            entry.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: M3Text.h3(context).copyWith(fontSize: compact ? 13 : 14.5),
          ),
        ),
        if (me) ...[
          const SizedBox(height: 3),
          const M3Tag('คุณ', tone: M3Tone.cyan),
        ] else if (entry.trophies.isNotEmpty)
          Text(
            entry.trophies.take(compact ? 3 : 5).join(''),
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 12),
          ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${entry.score}',
            style: M3Text.num(
              context,
              size: first ? (compact ? 24 : 32) : (compact ? 19 : 25),
              color: _placeColor(p, place),
            ),
          ),
        ),
        Text(
          'คะแนน · อัปโหลด ${entry.uploadFormatted}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: M3Text.sub(context).copyWith(fontSize: compact ? 10.5 : 11.5),
        ),
        const SizedBox(height: 10),
        _Plinth(rank: entry.rank, medal: medal, height: plinth, first: first),
      ],
    );
  }
}

/// Initials on a dark medal plate inside a medal-coloured ring, inside a
/// chrome ring.
class _MedalAvatar extends StatelessWidget {
  final String name;
  final _Medal medal;
  final double size;

  const _MedalAvatar({
    required this.name,
    required this.medal,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.045),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: M3Fx.chrome,
        boxShadow: medal.glow,
      ),
      child: Container(
        padding: EdgeInsets.all(size * 0.05),
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: medal.frame),
        child: ClipOval(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: medal.plate),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.4,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(gradient: M3Fx.btnGloss),
                    ),
                  ),
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: M3Fx.proShine),
                  ),
                ),
                ShaderMask(
                  shaderCallback: (r) => medal.frame.createShader(r),
                  blendMode: BlendMode.srcIn,
                  child: Text(
                    _initials(name),
                    style: TextStyle(
                      fontFamily: M3Fonts.head,
                      fontSize: size * 0.34,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.1,
                      shadows: medal.textGlow,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The podium step: medal frame → dark plate → gloss → diagonal shine, with
/// the rank number in metal.
class _Plinth extends StatelessWidget {
  final int rank;
  final _Medal medal;
  final double height;
  final bool first;

  const _Plinth({
    required this.rank,
    required this.medal,
    required this.height,
    required this.first,
  });

  @override
  Widget build(BuildContext context) {
    const top = Radius.circular(12);
    const bottom = Radius.circular(4);
    return Container(
      height: height,
      padding: const EdgeInsets.fromLTRB(1.8, 1.8, 1.8, 0),
      decoration: BoxDecoration(
        gradient: medal.frame,
        borderRadius: const BorderRadius.vertical(top: top, bottom: bottom),
        boxShadow: first ? medal.glow : null,
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: medal.plate,
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(10.5), bottom: bottom),
        ),
        child: Stack(
          children: [
            // Lit top face of the block.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 7,
              child: Opacity(
                opacity: 0.55,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: medal.frame,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(10.5)),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0.4,
                child: Container(
                  margin: const EdgeInsets.all(0.6),
                  decoration: const BoxDecoration(
                    gradient: M3Fx.btnGloss,
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(10), bottom: bottom),
                  ),
                ),
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: M3Fx.proShine),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ShaderMask(
                    shaderCallback: (r) => medal.frame.createShader(r),
                    blendMode: BlendMode.srcIn,
                    child: Text(
                      '$rank',
                      style: TextStyle(
                        fontFamily: M3Fonts.head,
                        fontSize: (height * 0.55).clamp(22.0, 54.0),
                        fontWeight: FontWeight.w800,
                        fontStyle: FontStyle.italic,
                        color: Colors.white,
                        height: 1,
                        shadows: medal.textGlow,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── You (when outside the top 50) ───────────────────────────────────────

class _YouStrip extends StatelessWidget {
  final BtUserStats stats;
  const _YouStrip({required this.stats});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return GlassPanel(
      accent: p.cyan,
      padding: const EdgeInsets.all(10),
      child: M3Row(
        selected: true,
        leading: _RankNumber(rank: stats.rankPosition),
        title: 'อันดับของคุณ',
        subtitle: 'ยังไม่ติด Top 50 — แชร์และ Seed ไฟล์เพิ่มเพื่อไต่อันดับ',
        trailing: _ScoreBlock(score: stats.score),
      ),
    );
  }
}

// ── Table (rank 4+) ─────────────────────────────────────────────────────

class _TableCard extends StatelessWidget {
  final List<BtLeaderboardEntry> board;
  final int? myIndex;

  const _TableCard({required this.board, required this.myIndex});

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return GlassPanel(
      padding: EdgeInsets.all(narrow ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.members,
            title: 'ตารางอันดับ',
            subtitle: 'อันดับ ${board[3].rank}–${board.last.rank}',
            trailing: M3Count(board.length),
          ),
          const SizedBox(height: 12),
          for (var i = 3; i < board.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RankRow(entry: board[i], me: myIndex == i)
                  .animate()
                  .fadeIn(
                    delay: ((i - 3).clamp(0, 12) * 40).ms,
                    duration: 300.ms,
                  )
                  .slideX(begin: 0.03, end: 0),
            ),
        ],
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  final BtLeaderboardEntry entry;
  final bool me;

  const _RankRow({required this.entry, required this.me});

  @override
  Widget build(BuildContext context) {
    final sub = M3Text.sub(context).copyWith(fontSize: 11.5);
    return M3Row(
      selected: me,
      leading: _RankNumber(rank: entry.rank, highlight: me),
      title: entry.displayName,
      subtitleWidget: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Wrap(
          spacing: 10,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (me) const M3Tag('คุณ', tone: M3Tone.cyan),
            Text('อัปโหลด ${entry.uploadFormatted}', style: sub),
            Text('${entry.totalFilesShared} ไฟล์', style: sub),
            Text('Seed ${entry.seedTimeFormatted}', style: sub),
            if (entry.trophies.isNotEmpty)
              Text(entry.trophies.take(5).join(''),
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
      trailing: _ScoreBlock(score: entry.score),
    );
  }
}

class _RankNumber extends StatelessWidget {
  final int rank;
  final bool highlight;

  const _RankNumber({required this.rank, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final text = rank > 0 ? '$rank' : '—';
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlight ? p.cyanSoft : p.inset,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: highlight ? p.cyanSoftLine : p.line),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            text,
            style: TextStyle(
              fontFamily: M3Fonts.head,
              fontSize: text.length >= 3 ? 16 : 20,
              fontWeight: FontWeight.w700,
              color: highlight ? p.cyanText : p.text2,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreBlock extends StatelessWidget {
  final int score;
  const _ScoreBlock({required this.score});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$score', style: M3Text.num(context, size: 20)),
        Text('คะแนน', style: M3Text.sub(context).copyWith(fontSize: 11)),
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
