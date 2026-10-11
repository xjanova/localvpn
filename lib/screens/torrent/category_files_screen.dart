import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';
import 'file_detail_screen.dart';
import 'kyc_verification_screen.dart';
import 'upload_file_screen.dart';

/// Files of one category: search, sort chips, a list (phone) or a grid
/// (desktop) of files, and an upload button.
class CategoryFilesScreen extends StatefulWidget {
  final TorrentService torrentService;
  final BtCategory category;

  const CategoryFilesScreen({
    super.key,
    required this.torrentService,
    required this.category,
  });

  @override
  State<CategoryFilesScreen> createState() => _CategoryFilesScreenState();
}

class _CategoryFilesScreenState extends State<CategoryFilesScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _currentSort = 'newest';

  /// The search that produced [_files] (the field may hold unsent text).
  String _query = '';

  // The service keeps one shared file list (the Torrent tab also reads it),
  // so this page keeps its own copy of what it fetched.
  List<BtFile> _files = const [];
  BtPagination _pagination = const BtPagination();
  String? _error;

  bool _loading = true; // nothing on screen yet
  bool _refreshing = false; // new sort/search/refresh, old list stays
  bool _loadingMore = false;
  int _gen = 0;

  TorrentService get t => widget.torrentService;
  BtCategory get cat => widget.category;

  bool get _kycBlocked => cat.isAdult && t.kycStatus != 'approved';

  @override
  void initState() {
    super.initState();
    t.addListener(_onChanged);
    _scrollController.addListener(_onScroll);
    _loadFiles();
  }

  @override
  void dispose() {
    _gen++;
    t.removeListener(_onChanged);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFiles({bool append = false}) async {
    if (append &&
        (_loadingMore || _loading || _refreshing || !_pagination.hasMore)) {
      return;
    }
    final gen = append ? _gen : ++_gen;
    final page = append ? _pagination.currentPage + 1 : 1;

    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loadingMore = false;
        if (_files.isEmpty) {
          _loading = true;
        } else {
          _refreshing = true;
        }
      }
    });

    // Always a plain page fetch; pages are joined here so another screen
    // using the service in between can't mix its files into this list.
    await t.fetchFiles(
      cat.slug,
      sort: _currentSort,
      search: _query.isEmpty ? null : _query,
      page: page,
    );
    if (!mounted || gen != _gen) return;

    final err = t.error;
    final got = [
      for (final f in t.files)
        if (f.category == null || f.category!.slug == cat.slug) f,
    ];

    setState(() {
      _loading = false;
      _refreshing = false;
      _loadingMore = false;
      if (err == null) {
        _error = null;
        _pagination = t.pagination;
        if (append) {
          final seen = {for (final f in _files) f.id};
          _files = [..._files, ...got.where((f) => seen.add(f.id))];
        } else {
          _files = got;
        }
      } else if (!append && _files.isEmpty) {
        _error = err;
      }
    });

    if (err != null && (append || _files.isNotEmpty) && !_kycBlocked) {
      m3Toast(context, err, tone: M3Tone.red);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _loadFiles(append: true);
    }
  }

  void _setSort(String sort) {
    if (_currentSort == sort) return;
    setState(() => _currentSort = sort);
    _loadFiles();
  }

  void _submitSearch() {
    FocusScope.of(context).unfocus();
    final q = _searchController.text.trim();
    if (q == _query && _error == null) return;
    setState(() => _query = q);
    _loadFiles();
  }

  void _clearSearch() {
    _searchController.clear();
    if (_query.isEmpty) {
      setState(() {});
      return;
    }
    setState(() => _query = '');
    _loadFiles();
  }

  Future<void> _openUpload() async {
    final uploaded = await Navigator.of(context).push<BtFile>(
      M3PageRoute<BtFile>(
        builder: (_) => UploadFileScreen(
          torrentService: t,
          categories: t.categories,
          initialCategory: cat,
        ),
      ),
    );
    if (!mounted) return;
    if (uploaded != null) _loadFiles();
  }

  void _openFile(BtFile file) {
    Navigator.of(context).push(
      M3PageRoute(
        builder: (_) => FileDetailScreen(
          torrentService: t,
          fileId: file.id,
          initialFile: file,
        ),
      ),
    );
  }

  Future<void> _openKyc() async {
    await Navigator.of(context).push(
      M3PageRoute(builder: (_) => KycVerificationScreen(torrentService: t)),
    );
    if (!mounted) return;
    await t.fetchKycStatus();
    if (!mounted) return;
    _loadFiles();
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final kycPending = t.kycStatus == 'pending';
    final showKyc = _kycBlocked && _files.isEmpty && !_loading;

    return M3PageBody(
      controller: _scrollController,
      onRefresh: () => _loadFiles(),
      children: [
        M3PageHeader(
          icon3d: torrentCategoryIcon3d(cat.icon),
          title: cat.name,
          subtitle: _loading && _files.isEmpty
              ? 'กำลังโหลด…'
              : '${_pagination.total} ไฟล์ในหมวดนี้',
          onBack: () => Navigator.of(context).pop(),
          trailing: GlossButton(
            label: narrow ? 'อัพโหลด' : 'อัพโหลดไฟล์',
            icon3d: M3Icons.upload,
            size: narrow ? GlossSize.small : GlossSize.medium,
            onPressed: _openUpload,
          ),
        ),
        const SizedBox(height: 16),
        if (showKyc) ...[
          M3Banner(
            tone: M3Tone.red,
            icon3d: M3Icons.kyc,
            title: 'หมวด 18+ สำหรับผู้ที่ยืนยันตัวตนแล้ว',
            message: kycPending
                ? 'เอกสารยืนยันตัวตนของคุณกำลังรอตรวจสอบ'
                : 'ยืนยันตัวตน (KYC) และอายุ 18 ปีขึ้นไป จึงจะดูและดาวน์โหลดไฟล์ในหมวดนี้ได้',
            action: kycPending
                ? null
                : GlossButton(
                    label: 'ยืนยันตัวตน',
                    size: GlossSize.small,
                    variant: GlossVariant.gold,
                    onPressed: _openKyc,
                  ),
          ),
          const SizedBox(height: 14),
        ],
        _FilterHero(
          category: cat,
          total: _pagination.total,
          query: _query,
          loading: _loading && _files.isEmpty,
          refreshing: _refreshing,
          sort: _currentSort,
          searchController: _searchController,
          onSort: _setSort,
          onSearch: _submitSearch,
          onClear: _clearSearch,
          onTyping: () => setState(() {}),
        ).animate().fadeIn(duration: 320.ms).slideY(begin: 0.04, end: 0),
        const SizedBox(height: 18),
        M3SectionTitle(
          _query.isEmpty ? 'ไฟล์ทั้งหมด' : 'ผลการค้นหา "$_query"',
          trailing: _files.isEmpty
              ? null
              : M3Count(
                  _pagination.total > 0 ? _pagination.total : _files.length),
        ),
        _buildBody(kycPending),
        if (_files.isNotEmpty && _pagination.hasMore) ...[
          const SizedBox(height: 14),
          Center(
            child: GlossButton(
              label: 'โหลดเพิ่ม',
              icon: Icons.expand_more_rounded,
              variant: GlossVariant.glass,
              loading: _loadingMore,
              onPressed: _loadingMore ? null : () => _loadFiles(append: true),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBody(bool kycPending) {
    if (_loading && _files.isEmpty) {
      return const GlassPanel(
        child: M3EmptyState(
          icon3d: M3Icons.folder,
          title: 'กำลังโหลดไฟล์…',
        ),
      );
    }
    if (_files.isEmpty && _kycBlocked) {
      return GlassPanel(
        child: M3EmptyState(
          icon3d: M3Icons.kyc,
          title: kycPending ? 'รอตรวจสอบตัวตน' : 'ต้องยืนยันตัวตนก่อน',
          message: kycPending
              ? 'เมื่อเอกสารผ่านการตรวจสอบ ไฟล์ในหมวดนี้จะแสดงที่นี่'
              : 'หมวดนี้มีเนื้อหาสำหรับผู้ใหญ่ ต้องยืนยันตัวตนก่อนจึงจะเข้าดูได้',
          action: kycPending
              ? GlossButton(
                  label: 'ตรวจสอบอีกครั้ง',
                  icon: Icons.refresh_rounded,
                  variant: GlossVariant.glass,
                  loading: _refreshing,
                  onPressed: _refreshing ? null : _openKycRecheck,
                )
              : GlossButton(
                  label: 'ยืนยันตัวตน',
                  icon3d: M3Icons.kyc,
                  variant: GlossVariant.gold,
                  onPressed: _openKyc,
                ),
        ),
      );
    }
    if (_files.isEmpty && _error != null) {
      return GlassPanel(
        accent: context.m3.red.withValues(alpha: 0.6),
        child: M3EmptyState(
          icon3d: M3Icons.folder,
          title: 'โหลดไฟล์ไม่สำเร็จ',
          message: _error,
          action: GlossButton(
            label: 'ลองอีกครั้ง',
            icon: Icons.refresh_rounded,
            loading: _refreshing,
            onPressed: _refreshing ? null : () => _loadFiles(),
          ),
        ),
      );
    }
    if (_files.isEmpty) {
      return GlassPanel(
        child: M3EmptyState(
          icon3d: M3Icons.folder,
          title: _query.isEmpty
              ? 'ยังไม่มีไฟล์ในหมวดนี้'
              : 'ไม่พบไฟล์ที่ตรงกับ "$_query"',
          message: _query.isEmpty
              ? 'เป็นคนแรกที่แชร์ไฟล์ในหมวดนี้ให้ชุมชน'
              : 'ลองใช้คำค้นอื่น หรือล้างคำค้นเพื่อดูไฟล์ทั้งหมด',
          action: _query.isEmpty
              ? GlossButton(
                  label: 'อัพโหลดไฟล์',
                  icon3d: M3Icons.upload,
                  onPressed: _openUpload,
                )
              : GlossButton(
                  label: 'ล้างคำค้น',
                  icon: Icons.close_rounded,
                  variant: GlossVariant.glass,
                  onPressed: _clearSearch,
                ),
        ),
      );
    }

    final seeding = t.seedingFileHashes;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 1000
          ? 3
          : c.maxWidth >= 640
              ? 2
              : 1;
      if (cols == 1) {
        return GlassPanel(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _files.length; i++)
                Padding(
                  key: ValueKey(_files[i].id),
                  padding: EdgeInsets.only(
                      bottom: i == _files.length - 1 ? 0 : 8),
                  child: TorrentFileRow(
                    file: _files[i],
                    seeding: seeding.contains(_files[i].fileHash),
                    onTap: () => _openFile(_files[i]),
                  )
                      .animate()
                      .fadeIn(
                          delay: ((i % 20).clamp(0, 10) * 35).ms,
                          duration: 280.ms)
                      .slideX(begin: 0.03, end: 0),
                ),
            ],
          ),
        );
      }
      const gap = 14.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (var i = 0; i < _files.length; i++)
            SizedBox(
              key: ValueKey(_files[i].id),
              width: w,
              child: TorrentFileTile(
                file: _files[i],
                seeding: seeding.contains(_files[i].fileHash),
                onTap: () => _openFile(_files[i]),
              )
                  .animate()
                  .fadeIn(
                      delay: ((i % 20).clamp(0, 10) * 35).ms,
                      duration: 280.ms)
                  .slideY(begin: 0.05, end: 0),
            ),
        ],
      );
    });
  }

  Future<void> _openKycRecheck() async {
    await t.fetchKycStatus();
    if (!mounted) return;
    _loadFiles();
  }
}

// ── Filter hero ─────────────────────────────────────────────────────────

class _FilterHero extends StatelessWidget {
  final BtCategory category;
  final int total;
  final String query;
  final bool loading;
  final bool refreshing;
  final String sort;
  final TextEditingController searchController;
  final ValueChanged<String> onSort;
  final VoidCallback onSearch;
  final VoidCallback onClear;
  final VoidCallback onTyping;

  const _FilterHero({
    required this.category,
    required this.total,
    required this.query,
    required this.loading,
    required this.refreshing,
    required this.sort,
    required this.searchController,
    required this.onSort,
    required this.onSearch,
    required this.onClear,
    required this.onTyping,
  });

  static const _sorts = <(String, String, IconData)>[
    ('newest', 'ล่าสุด', Icons.schedule_rounded),
    ('popular', 'ยอดนิยม', Icons.trending_up_rounded),
    ('size', 'ขนาด', Icons.storage_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final desc = category.description?.trim() ?? '';
    final hasText = searchController.text.isNotEmpty || query.isNotEmpty;

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: category.isAdult ? p.red.withValues(alpha: 0.8) : null,
      padding: EdgeInsets.all(narrow ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TorrentCategoryIcon(
                  icon: category.icon, size: narrow ? 60 : 80),
              SizedBox(width: narrow ? 12 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            category.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: M3Fonts.head,
                              fontSize: narrow ? 21 : 26,
                              fontWeight: FontWeight.w700,
                              color: p.text,
                              shadows: p.titleShadow,
                            ),
                          ),
                        ),
                        if (category.isAdult) ...[
                          const SizedBox(width: 8),
                          const M3Tag('18+', tone: M3Tone.red),
                        ],
                      ],
                    ),
                    if (desc.isNotEmpty)
                      Text(desc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: M3Text.sub(context)),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(loading ? '—' : '$total',
                            style: M3Text.num(context, size: narrow ? 22 : 28)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            query.isEmpty
                                ? 'ไฟล์ในหมวดนี้'
                                : 'ไฟล์ที่ตรงกับ "$query"',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: M3Text.sub(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: M3Field(
                  controller: searchController,
                  hint: 'ค้นหาไฟล์ในหมวดนี้...',
                  prefixIcon: Icons.search_rounded,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => onTyping(),
                  onSubmitted: (_) => onSearch(),
                  suffix: hasText
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
                onPressed: onSearch,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (key, label, icon) in _sorts)
                      M3Chip(
                        label: label,
                        icon: icon,
                        selected: sort == key,
                        onTap: () => onSort(key),
                      ),
                  ],
                ),
              ),
              if (refreshing) ...[
                const SizedBox(width: 10),
                const TorrentMiniSpinner(),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ── Shared by the torrent screens ───────────────────────────────────────

/// Material glyph telling category types apart (chips, small badges).
IconData torrentCategoryGlyph(String iconName) => switch (iconName) {
      'movie' => Icons.movie_rounded,
      'music_note' => Icons.music_note_rounded,
      'sports_esports' => Icons.sports_esports_rounded,
      'apps' => Icons.apps_rounded,
      'menu_book' => Icons.menu_book_rounded,
      'image' => Icons.image_rounded,
      'computer' => Icons.computer_rounded,
      'school' => Icons.school_rounded,
      '18_up_rating' => Icons.eighteen_up_rating,
      _ => Icons.folder_rounded,
    };

/// 3D icon for a category: a feature icon when one fits, else the folder.
String torrentCategoryIcon3d(String iconName) => switch (iconName) {
      'sports_esports' => M3Icons.gameBoost,
      'computer' => M3Icons.devicePc,
      '18_up_rating' => M3Icons.lock,
      _ => M3Icons.folder,
    };

/// Category icon: the 3D icon, plus a small glass badge with the type glyph
/// when the 3D icon is the generic folder.
class TorrentCategoryIcon extends StatelessWidget {
  final String icon;
  final double size;

  const TorrentCategoryIcon({super.key, required this.icon, this.size = 46});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final asset = torrentCategoryIcon3d(icon);
    if (asset != M3Icons.folder) return Icon3D(asset, size: size);
    final badge = size * 0.44;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon3D(asset, size: size),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                gradient: p.glassBtn,
                borderRadius: BorderRadius.circular(badge * 0.3),
                border: Border.all(color: p.isNight ? p.line : p.inputLine),
              ),
              child: Icon(torrentCategoryGlyph(icon),
                  size: badge * 0.6, color: p.cyan),
            ),
          ),
        ],
      ),
    );
  }
}

/// The file's thumbnail (http/https only) or the 3D file icon.
class TorrentFileThumb extends StatelessWidget {
  final BtFile file;
  final double size;

  const TorrentFileThumb({super.key, required this.file, this.size = 44});

  static bool hasImage(BtFile file) {
    final url = file.thumbnailUrl;
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Icon3D(M3Icons.file, size: size);
    if (!hasImage(file)) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.network(
        file.thumbnailUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// Size / seeders / downloads tags for a file.
List<Widget> torrentFileTags(
  BtFile f, {
  bool showCategory = false,
  bool seeding = false,
}) =>
    [
      M3Tag(f.fileSizeFormatted,
          tone: M3Tone.neutral, icon: Icons.storage_rounded),
      M3Tag(
        'Seeder ${f.onlineSeedersCount}',
        tone: f.onlineSeedersCount > 0 ? M3Tone.green : M3Tone.neutral,
        icon: Icons.cloud_upload_rounded,
      ),
      M3Tag('${f.downloadCount} ดาวน์โหลด',
          tone: M3Tone.cyan, icon: Icons.download_rounded),
      if (showCategory && f.category != null)
        M3Tag(f.category!.name, tone: M3Tone.gold),
      if (seeding) const M3Tag('กำลัง Seed', tone: M3Tone.green, dot: true),
    ];

/// A file as a list row (inside a card).
class TorrentFileRow extends StatelessWidget {
  final BtFile file;
  final VoidCallback onTap;
  final bool showCategory;
  final bool seeding;

  const TorrentFileRow({
    super.key,
    required this.file,
    required this.onTap,
    this.showCategory = false,
    this.seeding = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final uploader = file.uploaderDisplayName;
    return M3Row(
      leading: TorrentFileThumb(file: file, size: 44),
      title: file.displayTitle,
      subtitleWidget: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: torrentFileTags(file,
                  showCategory: showCategory, seeding: seeding),
            ),
            if (uploader != null && uploader.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                'โดย $uploader',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: M3Text.sub(context).copyWith(fontSize: 11.5),
              ),
            ],
          ],
        ),
      ),
      trailing: Icon(Icons.chevron_right_rounded, size: 20, color: p.text3),
      onTap: onTap,
    );
  }
}

/// A file as a glass card (grid on wide screens).
class TorrentFileTile extends StatelessWidget {
  final BtFile file;
  final VoidCallback onTap;
  final bool showCategory;
  final bool seeding;

  const TorrentFileTile({
    super.key,
    required this.file,
    required this.onTap,
    this.showCategory = false,
    this.seeding = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final uploader = file.uploaderDisplayName;
    return GlassPanel(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      accent: seeding ? p.green.withValues(alpha: 0.8) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TorrentFileThumb(file: file, size: 54),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: M3Text.h3(context),
                ),
                if (uploader != null && uploader.isNotEmpty)
                  Text(
                    'โดย $uploader',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: M3Text.sub(context).copyWith(fontSize: 11.5),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: torrentFileTags(file,
                      showCategory: showCategory, seeding: seeding),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small inline spinner for refreshes that keep the content on screen.
class TorrentMiniSpinner extends StatelessWidget {
  final double size;
  const TorrentMiniSpinner({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: 2, color: context.m3.cyan),
    );
  }
}
