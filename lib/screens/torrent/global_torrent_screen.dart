import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';
import '../shell/app_services.dart';
import '../shell/app_shell.dart';
import 'category_files_screen.dart';
import 'file_detail_screen.dart';
import 'leaderboard_screen.dart';
import 'trophy_screen.dart';
import 'upload_file_screen.dart';
import 'user_profile_screen.dart';

/// "Torrent" — the community file library: your sharing stats, search
/// across every category, the category grid and the newest / most
/// downloaded files.
class GlobalTorrentScreen extends StatefulWidget {
  final AppServices services;

  const GlobalTorrentScreen({super.key, required this.services});

  @override
  State<GlobalTorrentScreen> createState() => _GlobalTorrentScreenState();
}

class _GlobalTorrentScreenState extends State<GlobalTorrentScreen> {
  final _searchController = TextEditingController();

  bool _firstLoad = true;
  bool _busy = false; // categories / profile / KYC request running
  bool _refreshing = false;

  /// Narrows the category grid while typing.
  String _filter = '';

  // The API lists files per category only, so the feed and the search walk
  // the categories one at a time. Bumping [_sweepGen] stops a walk at the
  // next category (e.g. when another page opens and needs the service).
  int _sweepGen = 0;
  bool _sweeping = false;

  String _feedSort = 'newest';
  final Map<String, List<BtFile>> _feed = {}; // finished feeds
  List<BtFile> _feedPartial = const [];

  String? _query; // submitted search, null = showing the feed
  List<BtFile> _results = const [];
  bool _resultsDone = false;

  TorrentService get t => widget.services.torrent;

  @override
  void initState() {
    super.initState();
    t.addListener(_onChanged);
    _loadData();
  }

  @override
  void dispose() {
    _sweepGen++;
    t.removeListener(_onChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadData() async {
    if (_busy) return;
    _busy = true;
    if (!_firstLoad) setState(() => _refreshing = true);
    try {
      await Future.wait([
        t.fetchCategories(),
        t.fetchUserProfile(),
        t.fetchKycStatus(),
      ]);
    } finally {
      _busy = false;
    }
    if (!mounted) return;
    setState(() {
      _firstLoad = false;
      _refreshing = false;
      _feed.clear();
    });
    // A page pushed on top is using the service; the walk starts when it
    // closes (see _open).
    if (!(ModalRoute.isCurrentOf(context) ?? true)) return;
    // The lists fill in on their own; the pull-to-refresh spinner stops now.
    if (_query != null) {
      unawaited(_runSearch(_query!));
    } else {
      unawaited(_loadFeed());
    }
  }

  // ── Feed / search ─────────────────────────────────────────────────────

  List<BtCategory> get _feedCategories {
    final cats = t.categories
        .where((c) => !c.isAdult && c.fileCount > 0)
        .toList()
      ..sort((a, b) => b.fileCount.compareTo(a.fileCount));
    return cats.take(8).toList();
  }

  List<BtCategory> get _searchCategories {
    final kyc = t.kycStatus == 'approved';
    return t.categories
        .where((c) => c.fileCount > 0 && (!c.isAdult || kyc))
        .toList();
  }

  /// Fetches [cats] one by one and hands each category's files to [onFiles].
  /// Returns false when it was stopped before the end.
  Future<bool> _sweep(
    int gen,
    List<BtCategory> cats, {
    required String sort,
    String? search,
    required void Function(List<BtFile> files) onFiles,
  }) async {
    for (final c in cats) {
      if (!mounted || gen != _sweepGen) return false;
      await t.fetchFiles(c.slug, sort: sort, search: search);
      // fetchFiles fills one shared list: read it right away.
      if (!mounted || gen != _sweepGen) return false;
      if (t.error != null) continue; // skip a category that failed
      onFiles([
        for (final f in t.files)
          if (f.category == null || f.category!.slug == c.slug) f,
      ]);
    }
    return true;
  }

  static List<BtFile> _rank(Iterable<BtFile> files, String sort,
      [int? limit]) {
    final list = files.toList();
    if (sort == 'popular') {
      list.sort((a, b) {
        final d = b.downloadCount.compareTo(a.downloadCount);
        return d != 0 ? d : b.onlineSeedersCount.compareTo(a.onlineSeedersCount);
      });
    } else {
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      list.sort((a, b) => (b.createdAt ?? epoch).compareTo(a.createdAt ?? epoch));
    }
    return limit == null ? list : list.take(limit).toList();
  }

  Future<void> _loadFeed() async {
    final sort = _feedSort;
    final gen = ++_sweepGen;
    final acc = <int, BtFile>{};
    setState(() {
      _sweeping = true;
      _feedPartial = const [];
    });
    final done = await _sweep(gen, _feedCategories, sort: sort,
        onFiles: (files) {
      for (final f in files) {
        acc[f.id] = f;
      }
      setState(() => _feedPartial = _rank(acc.values, sort, 8));
    });
    if (!mounted || gen != _sweepGen) return;
    setState(() {
      _sweeping = false;
      if (done) _feed[sort] = _rank(acc.values, sort, 8);
    });
  }

  void _setFeedSort(String sort) {
    if (_feedSort == sort) return;
    setState(() => _feedSort = sort);
    if (_query == null && _feed[sort] == null) _loadFeed();
  }

  void _submitSearch() {
    final q = _searchController.text.trim();
    if (q.isEmpty) {
      _clearSearch();
      return;
    }
    FocusScope.of(context).unfocus();
    _runSearch(q);
  }

  Future<void> _runSearch(String q) async {
    final gen = ++_sweepGen;
    final acc = <int, BtFile>{};
    setState(() {
      _query = q;
      _results = const [];
      _resultsDone = false;
      _sweeping = true;
    });
    final done = await _sweep(gen, _searchCategories,
        sort: 'newest', search: q, onFiles: (files) {
      for (final f in files) {
        acc[f.id] = f;
      }
      setState(() => _results = _rank(acc.values, 'newest'));
    });
    if (!mounted || gen != _sweepGen) return;
    setState(() {
      _sweeping = false;
      _resultsDone = done;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    final wasSearching = _query != null;
    if (wasSearching) _sweepGen++;
    setState(() {
      _filter = '';
      if (wasSearching) {
        _query = null;
        _results = const [];
        _resultsDone = false;
        _sweeping = false;
      }
    });
    if (wasSearching && _feed[_feedSort] == null && !_firstLoad) _loadFeed();
  }

  // ── Navigation ────────────────────────────────────────────────────────

  /// Pushes [page]. A running walk stops first (the next page uses the same
  /// service list) and picks up again on return if it didn't finish.
  Future<T?> _open<T>(Widget page) async {
    HapticFeedback.lightImpact();
    if (_sweeping) {
      _sweepGen++;
      setState(() => _sweeping = false);
    }
    final result =
        await Navigator.of(context).push<T>(M3PageRoute<T>(builder: (_) => page));
    if (!mounted) return result;
    if (_query != null) {
      if (!_resultsDone && !_sweeping) _runSearch(_query!);
    } else if (_feed[_feedSort] == null && !_sweeping && !_firstLoad) {
      _loadFeed();
    }
    return result;
  }

  Future<void> _openUpload() async {
    final uploaded = await _open<BtFile>(
      UploadFileScreen(torrentService: t, categories: t.categories),
    );
    if (uploaded != null && mounted) _loadData();
  }

  void _openCategory(BtCategory c) =>
      _open<void>(CategoryFilesScreen(torrentService: t, category: c));

  void _openFile(BtFile f) => _open<void>(
      FileDetailScreen(torrentService: t, fileId: f.id, initialFile: f));

  void _openLeaderboard() =>
      _open<void>(LeaderboardScreen(torrentService: t));

  void _openTrophies() => _open<void>(TrophyScreen(torrentService: t));

  void _openProfile() => _open<void>(UserProfileScreen(torrentService: t));

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final searching = _query != null;
    return M3PageBody(
      onRefresh: _loadData,
      children: [
        const M3PageHeader(
          icon3d: M3Icons.torrent,
          title: 'Torrent',
          subtitle: 'คลังไฟล์ของชุมชน · แชร์และดาวน์โหลดไฟล์ทั่วโลก',
          trailing: ShellBadges(),
        ),
        const SizedBox(height: 16),
        _ProfileHero(
          torrent: t,
          onUpload: _openUpload,
          onLeaderboard: _openLeaderboard,
          onTrophies: _openTrophies,
          onProfile: _openProfile,
        ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 16),
        _SearchBar(
          controller: _searchController,
          busy: searching && _sweeping,
          active: _searchController.text.isNotEmpty || searching,
          onChanged: (v) => setState(() => _filter = v.trim()),
          onSubmit: _submitSearch,
          onClear: _clearSearch,
        ).animate().fadeIn(delay: 60.ms, duration: 300.ms),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          final cats = _categoriesSection();
          final files = _filesCard().animate().fadeIn(delay: 120.ms, duration: 300.ms);
          if (c.maxWidth >= 1000) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: cats),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: files),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: searching
                ? [files, const SizedBox(height: 16), cats]
                : [cats, const SizedBox(height: 16), files],
          );
        }),
      ],
    );
  }

  Widget _categoriesSection() {
    final all = t.categories;
    final f = _filter.toLowerCase();
    final shown = f.isEmpty
        ? all
        : all.where((c) => c.name.toLowerCase().contains(f)).toList();

    Widget body;
    if (all.isEmpty && (_firstLoad || _busy)) {
      body = const GlassPanel(
        child: M3EmptyState(
          icon3d: M3Icons.torrent,
          title: 'กำลังโหลดคลังไฟล์…',
        ),
      );
    } else if (all.isEmpty) {
      body = GlassPanel(
        accent: context.m3.red.withValues(alpha: 0.6),
        child: M3EmptyState(
          icon3d: M3Icons.folder,
          title: 'ไม่สามารถโหลดหมวดหมู่ได้',
          message: t.error ?? 'ตรวจสอบการเชื่อมต่ออินเทอร์เน็ต แล้วลองใหม่อีกครั้ง',
          action: GlossButton(
            label: 'ลองอีกครั้ง',
            icon: Icons.refresh_rounded,
            loading: _busy,
            onPressed: _busy ? null : _loadData,
          ),
        ),
      );
    } else if (shown.isEmpty) {
      body = GlassPanel(
        child: M3EmptyState(
          icon3d: M3Icons.folder,
          title: 'ไม่พบหมวดหมู่ "$_filter"',
          message: 'กด "ค้นหา" เพื่อค้นหาชื่อไฟล์ในทุกหมวด',
        ),
      );
    } else {
      body = LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= 860
            ? 4
            : c.maxWidth >= 560
                ? 3
                : c.maxWidth >= 300
                    ? 2
                    : 1;
        const gap = 12.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < shown.length; i++)
              SizedBox(
                key: ValueKey(shown[i].slug),
                width: w,
                child: _CategoryTile(
                  category: shown[i],
                  onTap: () => _openCategory(shown[i]),
                )
                    .animate()
                    .fadeIn(delay: (i.clamp(0, 10) * 35).ms, duration: 280.ms)
                    .slideY(begin: 0.05, end: 0),
              ),
          ],
        );
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3SectionTitle(
          'หมวดหมู่',
          trailing: _refreshing
              ? const TorrentMiniSpinner()
              : GlossIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'รีเฟรช',
                  onPressed: _busy ? null : _loadData,
                ),
        ),
        body,
      ],
    );
  }

  Widget _filesCard() {
    final searching = _query != null;
    final list = searching ? _results : (_feed[_feedSort] ?? _feedPartial);
    final done = searching ? _resultsDone : _feed[_feedSort] != null;
    final popular = _feedSort == 'popular';
    final seeding = t.seedingFileHashes;

    Widget body;
    if (t.categories.isEmpty) {
      body = M3EmptyState(
        icon3d: M3Icons.file,
        title: _firstLoad || _busy ? 'กำลังโหลด…' : 'ยังไม่มีไฟล์ให้แสดง',
      );
    } else if (list.isEmpty && !done) {
      body = M3EmptyState(
        icon3d: searching ? M3Icons.scan : M3Icons.file,
        title: searching
            ? 'กำลังค้นหา "$_query"…'
            : (popular ? 'กำลังโหลดไฟล์ยอดนิยม…' : 'กำลังโหลดไฟล์ล่าสุด…'),
      );
    } else if (list.isEmpty) {
      body = M3EmptyState(
        icon3d: M3Icons.file,
        title: searching ? 'ไม่พบไฟล์ที่ตรงกับ "$_query"' : 'ยังไม่มีไฟล์ในคลัง',
        message: searching
            ? 'ลองใช้คำค้นอื่น หรือเลือกดูตามหมวดหมู่'
            : 'เป็นคนแรกที่แชร์ไฟล์ให้ชุมชน',
        action: searching
            ? null
            : GlossButton(
                label: 'อัพโหลดไฟล์',
                icon3d: M3Icons.upload,
                onPressed: _openUpload,
              ),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < list.length; i++)
            Padding(
              key: ValueKey(list[i].id),
              padding: EdgeInsets.only(bottom: i == list.length - 1 ? 0 : 8),
              child: TorrentFileRow(
                file: list[i],
                showCategory: true,
                seeding: seeding.contains(list[i].fileHash),
                onTap: () => _openFile(list[i]),
              ).animate().fadeIn(duration: 260.ms),
            ),
        ],
      );
    }

    final subtitle = searching
        ? (done || list.isNotEmpty
            ? '"$_query" · พบ ${list.length} ไฟล์'
            : '"$_query"')
        : (popular
            ? 'ดาวน์โหลดมากที่สุดจากทุกหมวด'
            : 'อัพโหลดล่าสุดจากทุกหมวด');

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: searching ? M3Icons.scan : M3Icons.file,
            title: searching ? 'ผลการค้นหา' : 'ไฟล์ในคลัง',
            subtitle: subtitle,
            trailing: _sweeping
                ? const TorrentMiniSpinner()
                : (searching
                    ? GlossButton(
                        label: 'ล้าง',
                        icon: Icons.close_rounded,
                        size: GlossSize.small,
                        variant: GlossVariant.glass,
                        onPressed: _clearSearch,
                      )
                    : null),
          ),
          if (!searching) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                M3Chip(
                  label: 'ล่าสุด',
                  icon: Icons.schedule_rounded,
                  selected: !popular,
                  onTap: () => _setFeedSort('newest'),
                ),
                M3Chip(
                  label: 'ยอดนิยม',
                  icon: Icons.trending_up_rounded,
                  selected: popular,
                  onTap: () => _setFeedSort('popular'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }
}

// ── Profile hero ────────────────────────────────────────────────────────

class _ProfileHero extends StatelessWidget {
  final TorrentService torrent;
  final VoidCallback onUpload;
  final VoidCallback onLeaderboard;
  final VoidCallback onTrophies;
  final VoidCallback onProfile;

  const _ProfileHero({
    required this.torrent,
    required this.onUpload,
    required this.onLeaderboard,
    required this.onTrophies,
    required this.onProfile,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final s = torrent.userStats;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final trophies = torrent.userTrophies;
    final seeding = torrent.seedingFileHashes.length;
    final rawName = s?.displayName?.trim() ?? '';
    final name = rawName.isEmpty ? 'นักแชร์ไฟล์ LocalVPN' : rawName;

    final (kycLabel, kycTone) = switch (torrent.kycStatus) {
      'approved' => ('ยืนยันตัวตนแล้ว', M3Tone.green),
      'pending' => ('KYC รอตรวจสอบ', M3Tone.amber),
      'rejected' => ('KYC ไม่ผ่าน', M3Tone.red),
      _ => ('ยังไม่ยืนยันตัวตน', M3Tone.neutral),
    };

    final metrics = <(String, String)>[
      ('อัพโหลด', s?.uploadFormatted ?? '0 B'),
      ('ดาวน์โหลด', s?.downloadFormatted ?? '0 B'),
      ('อันดับ', (s == null || s.rankPosition <= 0) ? '—' : '#${s.rankPosition}'),
      ('สกอร์', '${s?.score ?? 0}'),
    ];

    final avatar = Icon3D(
      M3Icons.profile,
      size: narrow ? 84 : 124,
      glow: seeding > 0 ? p.green.withValues(alpha: 0.4) : p.logoGlow,
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('โปรไฟล์นักแชร์', style: M3Text.sub(context)),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 22 : 29,
            fontWeight: FontWeight.w700,
            color: p.text,
            shadows: p.titleShadow,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            M3Tag(kycLabel, tone: kycTone, dot: true),
            M3Tag(
              seeding > 0 ? 'กำลัง Seed $seeding ไฟล์' : 'ยังไม่ได้ Seed',
              tone: seeding > 0 ? M3Tone.green : M3Tone.neutral,
              icon: Icons.cloud_upload_rounded,
            ),
            if (s != null)
              M3Tag('แชร์แล้ว ${s.totalFilesShared} ไฟล์',
                  tone: M3Tone.cyan, icon: Icons.folder_shared_rounded),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: narrow ? 18 : 30,
          runSpacing: 10,
          children: [
            for (final (label, value) in metrics)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: M3Text.num(context, size: narrow ? 20 : 24)),
                  Text(label,
                      style: M3Text.sub(context).copyWith(fontSize: 11.5)),
                ],
              ),
          ],
        ),
        if (trophies.isNotEmpty) ...[
          const SizedBox(height: 14),
          _TrophyStrip(trophies: trophies, onTap: onProfile),
        ],
      ],
    );

    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GlossButton(
          label: 'อัพโหลดไฟล์',
          icon3d: M3Icons.upload,
          size: GlossSize.large,
          expand: true,
          onPressed: onUpload,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                  label: 'อันดับ',
                  icon: M3Icons.leaderboard,
                  onTap: onLeaderboard),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionTile(
                  label: 'ถ้วยรางวัล',
                  icon: M3Icons.trophy,
                  onTap: onTrophies),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionTile(
                  label: 'โปรไฟล์', icon: M3Icons.profile, onTap: onProfile),
            ),
          ],
        ),
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: seeding > 0 ? p.green : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    avatar,
                    const SizedBox(width: 14),
                    Expanded(child: info),
                  ],
                ),
                const SizedBox(height: 16),
                actions,
              ],
            )
          : Row(
              children: [
                avatar,
                const SizedBox(width: 22),
                Expanded(child: info),
                const SizedBox(width: 18),
                SizedBox(width: 270, child: actions),
              ],
            ),
    );
  }
}

class _TrophyStrip extends StatelessWidget {
  final List<BtTrophy> trophies;
  final VoidCallback onTap;

  const _TrophyStrip({required this.trophies, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final badges = trophies
        .map((t) => t.badgeText.trim())
        .where((b) => b.isNotEmpty)
        .toList();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          SoundService().play(SfxType.tap);
          onTap();
        },
        child: M3Inset(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon3D(M3Icons.trophy, size: 26),
              const SizedBox(width: 8),
              if (badges.isNotEmpty) ...[
                Flexible(
                  child: Text(
                    badges.take(3).join(' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                if (badges.length > 3)
                  Text(' +${badges.length - 3}',
                      style: M3Text.label(context).copyWith(color: p.gold)),
                const SizedBox(width: 8),
              ],
              Text('ได้รับ ${trophies.length} ถ้วย',
                  style: M3Text.sub(context).copyWith(fontSize: 12)),
              Icon(Icons.chevron_right_rounded, size: 18, color: p.text3),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatefulWidget {
  final String label;
  final String icon;
  final VoidCallback onTap;

  const _ActionTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            SoundService().play(SfxType.tap);
            widget.onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
            decoration: BoxDecoration(
              color: _hover ? p.hover : p.inset,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _hover ? p.cyanSoftLine : p.line),
            ),
            child: Column(
              children: [
                AnimatedScale(
                  scale: _hover ? 1.08 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: Icon3D(widget.icon, size: 38),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: M3Text.label(context).copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Search bar & category tile ──────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final bool active;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.busy,
    required this.active,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Expanded(
            child: M3Field(
              controller: controller,
              hint: 'ค้นหาไฟล์จากทุกหมวด หรือพิมพ์ชื่อหมวด…',
              prefixIcon: Icons.search_rounded,
              textInputAction: TextInputAction.search,
              onChanged: onChanged,
              onSubmitted: (_) => onSubmit(),
              suffix: active
                  ? IconButton(
                      tooltip: 'ล้างคำค้น',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: onClear,
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          GlossButton(
            label: 'ค้นหา',
            icon: Icons.search_rounded,
            loading: busy,
            onPressed: busy ? null : onSubmit,
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final BtCategory category;
  final VoidCallback onTap;

  const _CategoryTile({required this.category, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return GlassPanel(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      accent: category.isAdult ? p.red.withValues(alpha: 0.7) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TorrentCategoryIcon(icon: category.icon, size: 46),
              const Spacer(),
              if (category.isAdult) const M3Tag('18+', tone: M3Tone.red),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            category.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: M3Text.h3(context),
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${category.fileCount}',
                  style: M3Text.num(context, size: 20)),
              const SizedBox(width: 5),
              Text('ไฟล์', style: M3Text.sub(context)),
            ],
          ),
        ],
      ),
    );
  }
}
