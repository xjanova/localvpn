import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/bt_models.dart';
import '../../platform/platform_info.dart';
import '../../services/sound_service.dart';
import '../../services/torrent_service.dart';
import '../../widgets/m3/m3.dart';
import 'category_files_screen.dart';

/// Hash of the file this page started downloading. The service runs one
/// download at a time and doesn't say which file it is, so progress is only
/// shown on the page of the file that is really downloading.
String? _activeDownloadHash;

/// Where finished downloads were saved this session (file hash → path).
final Map<String, String> _savedPaths = {};

/// One community file: hero with the numbers, download through the server
/// relay (progress, save location), seeding, details and the seeder list.
class FileDetailScreen extends StatefulWidget {
  final TorrentService torrentService;
  final int fileId;
  final BtFile? initialFile;

  const FileDetailScreen({
    super.key,
    required this.torrentService,
    required this.fileId,
    this.initialFile,
  });

  @override
  State<FileDetailScreen> createState() => _FileDetailScreenState();
}

class _FileDetailScreenState extends State<FileDetailScreen> {
  BtFile? _file;
  List<BtSeeder> _seeders = [];
  bool _isLoading = true;
  bool _fetching = false;
  bool _seedersLoaded = false;

  bool _isRegistering = false;
  bool _preparing = false; // overwrite check before a download

  String? _saveDir;
  bool _existsLocally = false;

  TorrentService get t => widget.torrentService;

  @override
  void initState() {
    super.initState();
    _file = widget.initialFile;
    t.addListener(_onServiceChanged);
    _loadDetail();
    _resolveSaveDir();
  }

  @override
  void dispose() {
    t.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDetail() async {
    if (_fetching) return;
    _fetching = true;
    if (!_isLoading) setState(() => _isLoading = true);

    final results = await Future.wait([
      t.fetchFileDetail(widget.fileId),
      t.fetchSeeders(widget.fileId),
    ]);
    _fetching = false;

    if (!mounted) return;
    setState(() {
      _file = results[0] as BtFile? ?? _file;
      _seeders = results[1] as List<BtSeeder>;
      _seedersLoaded = true;
      _isLoading = false;
    });
    _checkLocal();
  }

  // ── Save location ─────────────────────────────────────────────────────

  /// Same folder the service writes to: Documents/LocalVPN/Torrent.
  Future<void> _resolveSaveDir() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _saveDir = '${d.path}/LocalVPN/Torrent');
      _checkLocal();
    } catch (_) {}
  }

  Future<void> _checkLocal() async {
    final dir = _saveDir;
    final f = _file;
    if (dir == null || f == null || !_safeName(f.fileName)) return;
    try {
      final exists = await File('$dir/${f.fileName}').exists();
      if (!mounted) return;
      if (exists != _existsLocally) setState(() => _existsLocally = exists);
    } catch (_) {}
  }

  /// A server-supplied name must stay inside the download folder.
  static bool _safeName(String name) =>
      name.trim().isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !RegExp(r'[\\/:]').hasMatch(name);

  static String _display(String path) =>
      isWindows ? path.replaceAll('/', r'\') : path;

  String? _savedPathFor(BtFile f) {
    final saved = _savedPaths[f.fileHash];
    if (saved != null) return saved;
    final dir = _saveDir;
    if (_existsLocally && dir != null) return '$dir/${f.fileName}';
    return null;
  }

  Future<void> _openPath(String path) async {
    try {
      final r = await OpenFile.open(_display(path));
      if (!mounted) return;
      if (r.type != ResultType.done) {
        m3Toast(context, 'เปิดไม่ได้ — ไม่พบโปรแกรมที่ใช้เปิดไฟล์นี้',
            tone: M3Tone.amber);
      }
    } catch (_) {
      if (mounted) m3Toast(context, 'เปิดไม่ได้', tone: M3Tone.red);
    }
  }

  Future<void> _openFolder() async {
    final dir = _saveDir;
    if (dir == null) return;
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {}
    await _openPath(dir);
  }

  // ── Actions ───────────────────────────────────────────────────────────

  static String _friendly(String raw) {
    if (raw.contains('TimeoutException')) {
      return 'เซิร์ฟเวอร์ตอบช้าเกินไป ลองใหม่อีกครั้ง';
    }
    if (raw.contains('SocketException') ||
        raw.contains('ClientException') ||
        raw.contains('HandshakeException')) {
      return 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ ตรวจสอบอินเทอร์เน็ตแล้วลองใหม่';
    }
    if (raw.contains('FormatException')) {
      return 'ข้อมูลจากเซิร์ฟเวอร์ไม่ถูกต้อง ลองใหม่อีกครั้ง';
    }
    if (raw.contains('FileSystemException')) {
      return 'บันทึกไฟล์ลงเครื่องไม่สำเร็จ ตรวจสอบพื้นที่ว่างและสิทธิ์ของโฟลเดอร์';
    }
    return raw.replaceFirst(RegExp(r'^\w*Exception:\s*'), '');
  }

  Future<void> _download(BtFile file) async {
    final online = _seeders.where((s) => s.isOnline).toList();
    if (online.isEmpty || t.isDownloadingFile || _preparing) return;
    if (!_safeName(file.fileName)) {
      m3Toast(context, 'ชื่อไฟล์นี้ไม่ปลอดภัย จึงบันทึกลงเครื่องไม่ได้',
          tone: M3Tone.red);
      return;
    }

    setState(() => _preparing = true);
    var proceed = true;
    final dir = _saveDir;
    if (dir != null) {
      bool exists = false;
      try {
        exists = await File('$dir/${file.fileName}').exists();
      } catch (_) {}
      if (!mounted) return;
      if (exists) {
        proceed = await m3Confirm(
          context,
          icon3d: M3Icons.file,
          title: 'เขียนทับไฟล์เดิม?',
          message: 'มีไฟล์ "${file.fileName}" อยู่ในโฟลเดอร์ดาวน์โหลดแล้ว '
              'ถ้าดาวน์โหลดต่อ ไฟล์เดิมจะถูกแทนที่',
          confirmLabel: 'เขียนทับ',
          destructive: true,
        );
      }
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    if (!proceed || t.isDownloadingFile) return;

    _activeDownloadHash = file.fileHash;
    final path = await t.downloadFile(file, online);
    if (_activeDownloadHash == file.fileHash) _activeDownloadHash = null;
    if (path != null) _savedPaths[file.fileHash] = path;
    if (!mounted) return;

    if (path != null) {
      SoundService().play(SfxType.coin);
      HapticFeedback.heavyImpact();
      m3Toast(context, 'ดาวน์โหลดสำเร็จ: ${file.displayTitle}',
          tone: M3Tone.green);
      setState(() => _existsLocally = true);
      _loadDetail();
    } else {
      m3Toast(
        context,
        _friendly(t.downloadError ?? t.error ?? 'ดาวน์โหลดไม่สำเร็จ ลองใหม่อีกครั้ง'),
        tone: M3Tone.red,
      );
      setState(() {});
    }
  }

  Future<void> _seed(BtFile file) async {
    if (_isRegistering) return;
    setState(() => _isRegistering = true);
    try {
      final success = await t.registerSeeder(fileHash: file.fileHash);
      if (!mounted) return;
      if (success) {
        SoundService().play(SfxType.coin);
        HapticFeedback.mediumImpact();
        m3Toast(context, 'ลงทะเบียนเป็น Seeder แล้ว', tone: M3Tone.green);
        _loadDetail();
      } else {
        m3Toast(context, _friendly(t.error ?? 'ลงทะเบียนไม่สำเร็จ'),
            tone: M3Tone.red);
      }
    } catch (_) {
      if (!mounted) return;
      m3Toast(context, 'เกิดข้อผิดพลาด ลงทะเบียนไม่สำเร็จ', tone: M3Tone.red);
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  void _copyHash(BtFile file) {
    Clipboard.setData(ClipboardData(text: file.fileHash));
    SoundService().play(SfxType.coin);
    HapticFeedback.lightImpact();
    m3Toast(context, 'คัดลอก File Hash แล้ว', tone: M3Tone.green);
  }

  void _copyMagnet(BtFile file) {
    final parts = <String>[
      'hash:${file.fileHash}',
      'name:${file.fileName}',
    ];
    for (final s in _seeders.where((s) => s.isOnline)) {
      if (s.publicIp != null && s.publicPort != null) {
        parts.add('peer:${s.publicIp}:${s.publicPort}');
      }
    }
    Clipboard.setData(ClipboardData(text: 'magnet:?${parts.join('&')}'));
    SoundService().play(SfxType.coin);
    HapticFeedback.lightImpact();
    m3Toast(context, 'คัดลอก Magnet Link แล้ว', tone: M3Tone.green);
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final catName = file?.category?.name;

    return M3PageBody(
      onRefresh: _loadDetail,
      children: [
        M3PageHeader(
          icon3d: M3Icons.file,
          title: 'รายละเอียดไฟล์',
          subtitle: catName != null ? 'หมวด $catName' : 'ไฟล์จากคลังชุมชน',
          onBack: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: 16),
        if (file == null && _isLoading)
          const GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.file,
              title: 'กำลังโหลดข้อมูลไฟล์…',
            ),
          )
        else if (file == null)
          GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.file,
              title: 'ไม่พบไฟล์',
              message: 'ไฟล์นี้อาจถูกลบหรือปิดการแชร์แล้ว',
              action: GlossButton(
                label: 'ลองอีกครั้ง',
                icon: Icons.refresh_rounded,
                onPressed: _loadDetail,
              ),
            ),
          )
        else ...[
          _hero(file)
              .animate()
              .fadeIn(duration: 350.ms)
              .slideY(begin: 0.04, end: 0),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            final download = _downloadCard(file);
            final details = _detailsCard(file);
            final seeders = _seedersCard();
            if (c.maxWidth >= 980) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [details, const SizedBox(height: 16), seeders],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(flex: 4, child: download),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                download,
                const SizedBox(height: 16),
                details,
                const SizedBox(height: 16),
                seeders,
              ],
            );
          }).animate().fadeIn(delay: 80.ms, duration: 320.ms),
        ],
      ],
    );
  }

  int _onlineCount(BtFile f) => _seedersLoaded
      ? _seeders.where((s) => s.isOnline).length
      : f.onlineSeedersCount;

  String? _dateOf(BtFile f) {
    final d = f.createdAt?.toLocal();
    return d == null ? null : '${d.day}/${d.month}/${d.year}';
  }

  Widget _hero(BtFile f) {
    final p = context.m3;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final seeding = t.seedingFileHashes.contains(f.fileHash);
    final online = _onlineCount(f);
    final hasLocal = _savedPathFor(f) != null;
    final downloadingThis =
        t.isDownloadingFile && _activeDownloadHash == f.fileHash;
    final canDownload = _seedersLoaded &&
        online > 0 &&
        !t.isDownloadingFile &&
        !_preparing;
    final date = _dateOf(f);
    final uploader = f.uploaderDisplayName;
    final showFileName =
        f.title != null && f.title!.isNotEmpty && f.title != f.fileName;

    final iconSize = narrow ? 88.0 : 128.0;
    final icon = TorrentFileThumb.hasImage(f)
        ? TorrentFileThumb(file: f, size: iconSize)
        : Icon3D(
            M3Icons.file,
            size: iconSize,
            glow: seeding ? p.green.withValues(alpha: 0.4) : p.logoGlow,
          );

    final metrics = <(String, String, Color?)>[
      ('ขนาด', f.fileSizeFormatted, null),
      ('ดาวน์โหลด', '${f.downloadCount}', null),
      ('Seeder ออนไลน์', '$online', online > 0 ? p.green : p.red),
    ];

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          f.displayTitle,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: M3Fonts.head,
            fontSize: narrow ? 21 : 27,
            fontWeight: FontWeight.w700,
            height: 1.2,
            color: p.text,
            shadows: p.titleShadow,
          ),
        ),
        if (showFileName) ...[
          const SizedBox(height: 3),
          Text(
            f.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: M3Text.mono(context, size: 12.5, color: p.text3),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          'โดย ${uploader == null || uploader.isEmpty ? 'ไม่ทราบชื่อ' : uploader}'
          '${date == null ? '' : ' · $date'}',
          style: M3Text.sub(context),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (f.category != null)
              M3Tag(f.category!.name,
                  tone: M3Tone.gold,
                  icon: torrentCategoryGlyph(f.category!.icon)),
            if (f.category?.isAdult == true)
              const M3Tag('18+', tone: M3Tone.red),
            if (seeding)
              const M3Tag('กำลัง Seed อยู่', tone: M3Tone.green, dot: true),
            if (hasLocal)
              const M3Tag('มีในเครื่องแล้ว',
                  tone: M3Tone.cyan, icon: Icons.check_circle_rounded),
            if (_isLoading) const TorrentMiniSpinner(size: 16),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: narrow ? 20 : 32,
          runSpacing: 10,
          children: [
            for (final (label, value, color) in metrics)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: M3Text.num(context,
                          size: narrow ? 21 : 26,
                          color: color,
                          red: color == p.red)),
                  Text(label,
                      style: M3Text.sub(context).copyWith(fontSize: 11.5)),
                ],
              ),
          ],
        ),
      ],
    );

    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GlossButton(
          label: downloadingThis
              ? 'กำลังดาวน์โหลด ${(t.downloadProgress * 100).toStringAsFixed(0)}%'
              : (online > 0 ? 'ดาวน์โหลด ($online Seeder)' : 'ดาวน์โหลด'),
          icon3d: M3Icons.download,
          size: GlossSize.large,
          expand: true,
          loading: downloadingThis || _preparing,
          tooltip: online == 0 ? 'ต้องมี Seeder ออนไลน์จึงจะดาวน์โหลดได้' : null,
          onPressed: canDownload ? () => _download(f) : null,
        ),
        const SizedBox(height: 10),
        GlossButton(
          label: seeding ? 'กำลัง Seed อยู่' : 'ลงทะเบียนเป็น Seeder',
          icon: Icons.cloud_upload_rounded,
          variant: seeding ? GlossVariant.green : GlossVariant.glass,
          expand: true,
          loading: _isRegistering,
          onPressed: _isRegistering ? null : () => _seed(f),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: GlossButton(
                label: 'คัดลอก Hash',
                icon: Icons.copy_rounded,
                size: GlossSize.small,
                variant: GlossVariant.glass,
                expand: true,
                onPressed: () => _copyHash(f),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GlossButton(
                label: 'Magnet Link',
                icon: Icons.link_rounded,
                size: GlossSize.small,
                variant: GlossVariant.glass,
                expand: true,
                onPressed: () => _copyMagnet(f),
              ),
            ),
          ],
        ),
      ],
    );

    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: downloadingThis
          ? p.cyan
          : (seeding ? p.green : null),
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
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
                icon,
                const SizedBox(width: 22),
                Expanded(child: info),
                const SizedBox(width: 18),
                SizedBox(width: 270, child: actions),
              ],
            ),
    );
  }

  Widget _downloadCard(BtFile f) {
    final p = context.m3;
    final onlineSeeders = _seeders.where((s) => s.isOnline).toList();
    final online = _onlineCount(f);
    final downloadingThis =
        t.isDownloadingFile && _activeDownloadHash == f.fileHash;
    final busyOther = t.isDownloadingFile && !downloadingThis;
    final pct = (t.downloadProgress * 100).clamp(0, 100).toStringAsFixed(0);
    final saved = _savedPathFor(f);
    final dir = _saveDir;
    final shownPath = saved ??
        dir ??
        (isWindows ? r'Documents\LocalVPN\Torrent' : 'LocalVPN/Torrent');

    Widget status;
    if (downloadingThis) {
      status = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text('กำลังดาวน์โหลด…', style: M3Text.h3(context)),
              ),
              Text('$pct%', style: M3Text.num(context, size: 24)),
            ],
          ),
          const SizedBox(height: 8),
          M3ProgressBar(value: t.downloadProgress),
          const SizedBox(height: 6),
          Text(
            'ออกจากหน้านี้ได้ ระบบจะดาวน์โหลดต่อเบื้องหลัง — อย่าปิดแอปจนกว่าจะเสร็จ',
            style: M3Text.sub(context).copyWith(fontSize: 12),
          ),
        ],
      );
    } else if (busyOther) {
      status = const M3Banner(
        tone: M3Tone.amber,
        icon: Icons.hourglass_top_rounded,
        title: 'กำลังดาวน์โหลดไฟล์อื่นอยู่',
        message: 'ดาวน์โหลดได้ทีละไฟล์ — รอให้ไฟล์ก่อนหน้าเสร็จก่อน',
      );
    } else if (_seedersLoaded && online == 0) {
      status = const M3Banner(
        tone: M3Tone.amber,
        icon3d: M3Icons.relay,
        title: 'ยังไม่มี Seeder ออนไลน์',
        message: 'ต้องมี Seeder ออนไลน์จึงจะดาวน์โหลดได้ (ผ่าน server relay)',
      );
    } else if (!_seedersLoaded) {
      status = const M3Banner(
        tone: M3Tone.cyan,
        icon3d: M3Icons.relay,
        title: 'กำลังตรวจหา Seeder…',
      );
    } else {
      status = M3Banner(
        tone: M3Tone.green,
        icon3d: M3Icons.p2pDirect,
        title: saved != null ? 'ดาวน์โหลดแล้ว' : 'พร้อมดาวน์โหลด',
        message: 'มี Seeder ออนไลน์ $online เครื่อง',
      );
    }

    return GlassPanel(
      accent: downloadingThis ? p.cyan.withValues(alpha: 0.8) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(
            icon3d: M3Icons.download,
            title: 'ดาวน์โหลดผ่าน Server Relay',
            subtitle: 'ขอชิ้นส่วนไฟล์จาก Seeder ผ่านเซิร์ฟเวอร์ แล้วตรวจ SHA-256 ก่อนบันทึก',
          ),
          const SizedBox(height: 14),
          status,
          const SizedBox(height: 14),
          M3Inset(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon3D(M3Icons.folder, size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            saved != null ? 'บันทึกไว้ที่' : 'ไฟล์จะถูกบันทึกที่',
                            style: M3Text.sub(context).copyWith(fontSize: 11.5),
                          ),
                          Text(
                            _display(shownPath),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: M3Text.mono(context,
                                size: 12.5, color: p.text2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (saved != null || (isDesktop && dir != null)) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (saved != null)
                        GlossButton(
                          label: 'เปิดไฟล์',
                          icon: Icons.open_in_new_rounded,
                          size: GlossSize.small,
                          onPressed: () => _openPath(saved),
                        ),
                      if (isDesktop && dir != null)
                        GlossButton(
                          label: 'เปิดโฟลเดอร์',
                          icon: Icons.folder_open_rounded,
                          size: GlossSize.small,
                          variant: GlossVariant.glass,
                          onPressed: _openFolder,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onlineSeeders.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('P2P Peers', style: M3Text.label(context)),
            const SizedBox(height: 6),
            for (final s in onlineSeeders)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    StatusOrb(color: p.green, size: 8, pulse: false),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.publicIp != null && s.publicPort != null
                            ? '${s.publicIp}:${s.publicPort}'
                            : 'ไม่ทราบ IP',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: M3Text.mono(context, size: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _detailsCard(BtFile f) {
    final p = context.m3;
    final desc = f.description?.trim() ?? '';
    final date = _dateOf(f);
    final uploader = f.uploaderDisplayName;
    final shortHash = f.fileHash.length >= 16
        ? '${f.fileHash.substring(0, 16)}…'
        : f.fileHash;

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const M3CardHeader(icon3d: M3Icons.file, title: 'ข้อมูลไฟล์'),
          const SizedBox(height: 12),
          if (desc.isNotEmpty) ...[
            Text('รายละเอียด', style: M3Text.label(context)),
            const SizedBox(height: 6),
            M3Inset(
              child: SelectableText(
                desc,
                style: M3Text.body(context)
                    .copyWith(fontSize: 13.5, color: p.text2, height: 1.55),
              ),
            ),
            const SizedBox(height: 12),
          ],
          M3KeyValue('ผู้อัพโหลด',
              uploader == null || uploader.isEmpty ? 'ไม่ทราบชื่อ' : uploader),
          if (f.category != null) M3KeyValue('หมวดหมู่', f.category!.name),
          if (date != null) M3KeyValue('อัพโหลดเมื่อ', date),
          M3KeyValue('ขนาด', f.fileSizeFormatted),
          M3KeyValue('ชื่อไฟล์', f.fileName, mono: true),
          if (f.chunkSize != null)
            M3KeyValue('Chunk Size', '${f.chunkSize} bytes', mono: true),
          if (f.totalChunks != null)
            M3KeyValue('Total Chunks', '${f.totalChunks}', mono: true),
          M3KeyValue(
            'Hash',
            shortHash,
            mono: true,
            trailing: GlossIconButton(
              icon: Icons.copy_rounded,
              size: 28,
              tooltip: 'คัดลอก File Hash',
              onPressed: () => _copyHash(f),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seedersCard() {
    final p = context.m3;
    final online = _seeders.where((s) => s.isOnline).length;
    final sorted = [..._seeders]
      ..sort((a, b) => (b.isOnline ? 1 : 0).compareTo(a.isOnline ? 1 : 0));

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.p2pDirect,
            title: 'Seeders',
            subtitle: _seeders.isEmpty
                ? null
                : 'ออนไลน์ $online จาก ${_seeders.length} เครื่อง',
            trailing: _isLoading
                ? const TorrentMiniSpinner()
                : GlossIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'รีเฟรช',
                    onPressed: _loadDetail,
                  ),
          ),
          const SizedBox(height: 12),
          if (!_seedersLoaded)
            const M3EmptyState(
              icon3d: M3Icons.relay,
              title: 'กำลังโหลดรายชื่อ Seeder…',
            )
          else if (_seeders.isEmpty)
            const M3EmptyState(
              icon3d: M3Icons.relay,
              title: 'ไม่มี seeder ออนไลน์',
              message: 'เมื่อมีคนแชร์ไฟล์นี้ รายชื่อจะแสดงที่นี่',
            )
          else
            for (final s in sorted)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: M3Row(
                  leading: Icon3D(M3Icons.devicePc,
                      size: 36, opacity: s.isOnline ? 1 : 0.45),
                  title: s.displayName ?? s.machineId,
                  subtitleWidget: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (s.publicIp != null && s.publicPort != null)
                        Text('${s.publicIp}:${s.publicPort}',
                            style: M3Text.mono(context, size: 12)),
                      Text(
                        s.machineId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: M3Text.mono(context, size: 10.5, color: p.text3),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (s.chunksBitmap == 'all') ...[
                        const M3Tag('Full', tone: M3Tone.green),
                        const SizedBox(width: 6),
                      ],
                      M3Tag(
                        s.isOnline ? 'ออนไลน์' : 'ออฟไลน์',
                        tone: s.isOnline ? M3Tone.green : M3Tone.neutral,
                        dot: true,
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
