import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../models/bt_models.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cyber_page_route.dart';
import '../../widgets/glass_card.dart';
import 'file_detail_screen.dart';
import 'upload_file_screen.dart';

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
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    widget.torrentService.addListener(_onChanged);
    _loadFiles();
    _scrollController.addListener(_onScroll);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFiles({bool append = false}) async {
    final page = append
        ? widget.torrentService.pagination.currentPage + 1
        : 1;

    await widget.torrentService.fetchFiles(
      widget.category.slug,
      sort: _currentSort,
      search: _searchController.text.isNotEmpty
          ? _searchController.text
          : null,
      page: page,
      append: append,
    );
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoadingMore &&
        widget.torrentService.pagination.hasMore) {
      _isLoadingMore = true;
      _loadFiles(append: true).whenComplete(() {
        _isLoadingMore = false;
      });
    }
  }

  @override
  void dispose() {
    widget.torrentService.removeListener(_onChanged);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: () {
          SoundService().play(SfxType.tap);
          HapticFeedback.lightImpact();
          Navigator.of(context).push(
            CyberPageRoute(
              builder: (_) => UploadFileScreen(
                torrentService: widget.torrentService,
                categories: widget.torrentService.categories,
                initialCategory: widget.category,
              ),
            ),
          );
        },
        child: const Icon(Icons.upload_file, color: Colors.white),
      ),
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              _buildSearchAndSort(),
              Expanded(child: _buildFileList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios,
                color: AppColors.primary, size: 20),
            onPressed: () {
              SoundService().play(SfxType.swoosh);
              Navigator.pop(context);
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.category.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  '${widget.torrentService.pagination.total} ไฟล์',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (widget.category.isAdult)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.3),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.eighteen_up_rating,
                      color: AppColors.error, size: 16),
                  SizedBox(width: 4),
                  Text(
                    '18+',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ).animate().slideY(begin: -0.3, end: 0, duration: 400.ms);
  }

  Widget _buildSearchAndSort() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'ค้นหาไฟล์...',
              prefixIcon:
                  const Icon(Icons.search, color: AppColors.textMuted),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear,
                          color: AppColors.textMuted, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        _loadFiles();
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _loadFiles(),
          ).animate().fadeIn(duration: 300.ms, delay: 100.ms),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildSortChip('newest', 'ล่าสุด', Icons.schedule),
              const SizedBox(width: 8),
              _buildSortChip('popular', 'ยอดนิยม', Icons.trending_up),
              const SizedBox(width: 8),
              _buildSortChip('size', 'ขนาด', Icons.storage),
            ],
          ).animate().fadeIn(duration: 300.ms, delay: 150.ms),
        ],
      ),
    );
  }

  Widget _buildSortChip(String sort, String label, IconData icon) {
    final isSelected = _currentSort == sort;
    return GestureDetector(
      onTap: () {
        if (_currentSort != sort) {
          SoundService().play(SfxType.toggle);
          HapticFeedback.selectionClick();
          setState(() => _currentSort = sort);
          _loadFiles();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.15)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.5)
                : AppColors.cardBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? AppColors.primary : AppColors.textMuted,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isSelected
                    ? AppColors.primary
                    : AppColors.textSecondary,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList() {
    if (widget.torrentService.isLoading &&
        widget.torrentService.files.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (widget.torrentService.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_open,
              size: 64,
              color: AppColors.textMuted,
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .moveY(begin: 0, end: -8, duration: 2500.ms),
            const SizedBox(height: 16),
            const Text(
              'ยังไม่มีไฟล์ในหมวดนี้',
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFiles,
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        itemCount: widget.torrentService.files.length +
            (widget.torrentService.pagination.hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= widget.torrentService.files.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2,
                ),
              ),
            );
          }

          final file = widget.torrentService.files[index];
          return _buildFileCard(file, index);
        },
      ),
    );
  }

  Widget _buildFileCard(BtFile file, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        onTap: () {
          SoundService().play(SfxType.tap);
          HapticFeedback.lightImpact();
          Navigator.of(context).push(
            CyberPageRoute(
              builder: (_) => FileDetailScreen(
                torrentService: widget.torrentService,
                fileId: file.id,
                initialFile: file,
              ),
            ),
          );
        },
        child: Row(
          children: [
            // Thumbnail or icon
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(10),
                image: file.thumbnailUrl != null &&
                        !file.thumbnailUrl!.startsWith('data:')
                    ? DecorationImage(
                        image: NetworkImage(file.thumbnailUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: file.thumbnailUrl == null
                  ? const Icon(
                      Icons.insert_drive_file,
                      color: AppColors.textMuted,
                      size: 24,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildFileChip(
                        Icons.storage,
                        file.fileSizeFormatted,
                      ),
                      const SizedBox(width: 8),
                      _buildFileChip(
                        Icons.download,
                        '${file.downloadCount}',
                      ),
                      const SizedBox(width: 8),
                      _buildFileChip(
                        Icons.people,
                        '${file.onlineSeedersCount}',
                        color: file.onlineSeedersCount > 0
                            ? AppColors.success
                            : AppColors.textMuted,
                      ),
                    ],
                  ),
                  if (file.uploaderDisplayName != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'by ${file.uploaderDisplayName}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              size: 14,
              color: AppColors.textMuted.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 350.ms, delay: (index.clamp(0, 10) * 50).ms)
        .slideX(
          begin: 0.05,
          end: 0,
          duration: 350.ms,
          delay: (index.clamp(0, 10) * 50).ms,
        );
  }

  Widget _buildFileChip(IconData icon, String text, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color ?? AppColors.textMuted),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: color ?? AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}
