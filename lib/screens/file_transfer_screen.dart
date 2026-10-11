import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';

import '../models/member.dart';
import '../platform/platform_info.dart';
import '../services/file_transfer_service.dart';
import '../services/sound_service.dart';
import '../widgets/m3/m3.dart';
import 'shell/app_services.dart';
import 'shell/app_shell.dart';

/// "ส่งไฟล์" — share files with every machine in the current LAN network
/// (P2P, relay fallback), receive what friends shared, follow progress and
/// open what arrived.
///
/// The service shares to the whole network (there is no per-machine send),
/// so the member list in the hero shows who will see the file rather than
/// picking a single target.
class FileTransferScreen extends StatefulWidget {
  final AppServices services;

  const FileTransferScreen({super.key, required this.services});

  @override
  State<FileTransferScreen> createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen> {
  AppServices get s => widget.services;
  FileTransferService get files => s.files;

  bool _sharing = false;
  int _shareDone = 0;
  int _shareTotal = 0;
  bool _opening = false;
  bool _asking = false;
  String? _downloadDir;

  final Set<String> _receiving = {};
  final Set<int> _unsharing = {};

  /// Files the user declined ("ไม่รับ"). Kept for this app session only.
  final Set<String> _hidden = {};

  /// Last status seen per transfer, to announce finished downloads once.
  final Map<FileTransfer, TransferStatus> _seen = {};

  @override
  void initState() {
    super.initState();
    for (final t in files.transfers) {
      _seen[t] = t.status;
    }
    files.addListener(_onFilesChanged);
    s.network.addListener(_refresh);
    s.p2p.addListener(_refresh);
    _loadDownloadDir();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (s.network.currentNetwork != null && !files.isLoading) {
        files.refreshFileList();
      }
    });
  }

  @override
  void dispose() {
    files.removeListener(_onFilesChanged);
    s.network.removeListener(_refresh);
    s.p2p.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onFilesChanged() {
    if (!mounted) return;
    final current = files.transfers;
    for (final t in current) {
      final before = _seen[t];
      _seen[t] = t.status;
      if (before == null || before == t.status) continue;
      if (t.direction != TransferDirection.download) continue;
      if (t.status == TransferStatus.completed && t.localPath != null) {
        final path = paths.normalize(t.localPath!);
        SoundService().play(SfxType.notification);
        m3Toast(
          context,
          'รับ "${t.fileName}" ครบแล้ว',
          tone: M3Tone.green,
          action: SnackBarAction(
            label: 'เปิดไฟล์',
            onPressed: () {
              if (mounted) _openFile(path, received: true);
            },
          ),
        );
      } else if (t.status == TransferStatus.failed) {
        SoundService().play(SfxType.error);
        m3Toast(
          context,
          'รับ "${t.fileName}" ไม่สำเร็จ — ${_friendly(t.error ?? 'ลองอีกครั้ง')}',
          tone: M3Tone.red,
        );
      }
    }
    _seen.removeWhere((t, _) => !current.contains(t));
    setState(() {});
  }

  Future<void> _loadDownloadDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(
          () => _downloadDir = paths.join(dir.path, 'LocalVPN', 'Downloads'));
    } catch (_) {
      // No documents folder (should not happen) — the card says so.
    }
  }

  Future<void> _refreshAll() async {
    final net = s.network.currentNetwork;
    if (net == null) return;
    await Future.wait([
      files.refreshFileList(),
      s.network.getMembers(net.slug),
    ]);
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  /// [m3Confirm] that ignores a second tap while a question is open.
  Future<bool> _confirm({
    required String icon3d,
    required String title,
    required String message,
    required String confirmLabel,
    String cancelLabel = 'ยกเลิก',
  }) async {
    if (_asking) return false;
    _asking = true;
    try {
      return await m3Confirm(
        context,
        icon3d: icon3d,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: true,
      );
    } finally {
      _asking = false;
    }
  }

  Future<void> _pickAndShare() async {
    if (_sharing) return;
    final slug = s.network.currentNetwork?.slug;
    if (slug == null) return;
    setState(() {
      _sharing = true;
      _shareDone = 0;
      _shareTotal = 0;
    });
    try {
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          lockParentWindow: true,
          dialogTitle: 'เลือกไฟล์ที่จะส่งให้เพื่อนในวง',
        );
      } catch (_) {
        if (mounted) {
          m3Toast(context, 'เปิดหน้าต่างเลือกไฟล์ไม่ได้ ลองอีกครั้ง',
              tone: M3Tone.red);
        }
        return;
      }
      final picked = result?.files.map((f) => f.path).whereType<String>().toList() ??
          const <String>[];
      if (picked.isEmpty) return;
      if (mounted) setState(() => _shareTotal = picked.length);

      var ok = 0;
      var switched = false;
      for (final path in picked) {
        // The user left or changed network while we were busy: don't push
        // the rest of the files into a different network.
        if (s.network.currentNetwork?.slug != slug) {
          switched = true;
          break;
        }
        var success = false;
        try {
          success = await files.shareFile(path);
        } catch (_) {
          success = false;
        }
        if (success) ok++;
        if (mounted) setState(() => _shareDone++);
      }
      if (!mounted) return;

      final n = picked.length;
      if (ok > 0) {
        SoundService().play(SfxType.coin);
        HapticFeedback.heavyImpact();
      } else {
        SoundService().play(SfxType.error);
      }
      final String msg;
      final M3Tone tone;
      if (switched) {
        msg = 'เปลี่ยนวงระหว่างแชร์ — แชร์ไปแล้ว $ok ไฟล์ ที่เหลือหยุดไว้';
        tone = M3Tone.amber;
      } else if (ok == n) {
        msg = n == 1
            ? 'แชร์ไฟล์สำเร็จ — ทุกคนในเครือข่ายจะเห็น'
            : 'แชร์ครบ $n ไฟล์ — ทุกคนในเครือข่ายจะเห็น';
        tone = M3Tone.green;
      } else if (ok == 0) {
        msg = 'ไม่สามารถแชร์ไฟล์ได้ ตรวจสอบอินเทอร์เน็ตแล้วลองอีกครั้ง';
        tone = M3Tone.red;
      } else {
        msg = 'แชร์สำเร็จ $ok จาก $n ไฟล์ ไฟล์ที่เหลือลองอีกครั้ง';
        tone = M3Tone.amber;
      }
      m3Toast(context, msg, tone: tone);
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
          _shareDone = 0;
          _shareTotal = 0;
        });
      }
    }
  }

  Future<void> _receive(SharedFile f) async {
    if (_receiving.contains(f.fileHash)) return;
    if (files.transfers.any((t) => t.fileHash == f.fileHash && _isActive(t))) {
      return;
    }
    setState(() => _receiving.add(f.fileHash));
    // A retry: drop the old failed/cancelled entry first, otherwise incoming
    // chunks would be matched to the stale transfer.
    if (files.transfers.any((t) => t.fileHash == f.fileHash)) {
      files.removeTransfer(f.fileHash);
    }
    try {
      final t = await files.downloadFile(f);
      if (!mounted) return;
      if (t == null) {
        m3Toast(context, 'ไฟล์นี้กำลังรับอยู่หรือมีในเครื่องแล้ว',
            tone: M3Tone.amber);
      } else if (_isActive(t)) {
        m3Toast(context, 'เริ่มรับ "${f.fileName}" แล้ว');
      }
      // Failures are announced by _onFilesChanged.
    } catch (_) {
      if (mounted) {
        m3Toast(context, 'รับไฟล์ไม่สำเร็จ ลองอีกครั้ง', tone: M3Tone.red);
      }
    } finally {
      if (mounted) setState(() => _receiving.remove(f.fileHash));
    }
  }

  void _decline(SharedFile f) {
    setState(() => _hidden.add(f.fileHash));
    m3Toast(
      context,
      'ซ่อน "${f.fileName}" แล้ว',
      action: SnackBarAction(
        label: 'เลิกซ่อน',
        onPressed: () {
          if (mounted) setState(() => _hidden.remove(f.fileHash));
        },
      ),
    );
  }

  Future<void> _cancel(FileTransfer t) async {
    final up = t.direction == TransferDirection.upload;
    final ok = await _confirm(
      icon3d: up ? M3Icons.upload : M3Icons.download,
      title: up ? 'ยกเลิกการส่งไฟล์?' : 'ยกเลิกการรับไฟล์?',
      message: up
          ? 'เพื่อนจะหยุดได้รับ "${t.fileName}" จากเครื่องนี้'
          : 'ชิ้นส่วนของ "${t.fileName}" ที่รับมาแล้วจะถูกทิ้ง ถ้าต้องการไฟล์นี้ต้องเริ่มรับใหม่',
      confirmLabel: 'ยกเลิกการถ่ายโอน',
      cancelLabel: 'ทำต่อ',
    );
    if (!ok || !mounted) return;
    if (!_isActive(t)) return; // finished while the dialog was open
    files.cancelTransfer(t.fileHash);
    m3Toast(context, 'ยกเลิก "${t.fileName}" แล้ว', tone: M3Tone.amber);
  }

  Future<void> _removeTransfer(FileTransfer t) async {
    final keepsFile = t.status == TransferStatus.completed &&
        t.direction == TransferDirection.download &&
        t.localPath != null;
    final ok = await _confirm(
      icon3d: M3Icons.file,
      title: 'ลบออกจากรายการ?',
      message: keepsFile
          ? 'ลบแค่รายการนี้ ไฟล์ "${t.fileName}" ยังอยู่ในโฟลเดอร์ที่ได้รับ'
          : 'ลบ "${t.fileName}" ออกจากประวัติ',
      confirmLabel: 'ลบ',
    );
    if (!ok || !mounted) return;
    // A retry of the same file may have started meanwhile — keep it.
    if (files.transfers.any((x) => x.fileHash == t.fileHash && _isActive(x))) {
      return;
    }
    files.removeTransfer(t.fileHash);
  }

  Future<void> _unshare(SharedFile f) async {
    if (_unsharing.contains(f.id)) return;
    final ok = await _confirm(
      icon3d: M3Icons.upload,
      title: 'หยุดแชร์ไฟล์นี้?',
      message:
          'เพื่อนในวงจะไม่เห็น "${f.fileName}" อีก ไฟล์ในเครื่องนี้ไม่ถูกลบ',
      confirmLabel: 'หยุดแชร์',
    );
    if (!ok || !mounted) return;
    setState(() => _unsharing.add(f.id));
    try {
      await files.unshareFile(f.id, f.fileHash);
      if (!mounted) return;
      final still = files.networkFiles.any((x) => x.id == f.id);
      if (still) {
        m3Toast(context, 'ยังลบไฟล์ออกจากวงไม่ได้ ลองอีกครั้ง',
            tone: M3Tone.amber);
      } else {
        m3Toast(context, 'หยุดแชร์ "${f.fileName}" แล้ว', tone: M3Tone.green);
      }
    } catch (_) {
      if (mounted) {
        m3Toast(context, 'หยุดแชร์ไม่สำเร็จ ลองอีกครั้ง', tone: M3Tone.red);
      }
    } finally {
      if (mounted) setState(() => _unsharing.remove(f.id));
    }
  }

  Future<void> _openFile(String rawPath, {required bool received}) async {
    if (_opening) return;
    final path = paths.normalize(rawPath);
    final name = paths.basename(path);
    if (received && _isRiskyFile(name)) {
      final ok = await _confirm(
        icon3d: M3Icons.lock,
        title: 'เปิดไฟล์โปรแกรม?',
        message: '"$name" เป็นไฟล์ที่สั่งงานเครื่องได้และมาจากเพื่อนในวง '
            'เปิดเฉพาะเมื่อไว้ใจผู้ส่งเท่านั้น',
        confirmLabel: 'เปิดไฟล์',
      );
      if (!ok || !mounted) return;
    }
    _opening = true;
    try {
      if (!await File(path).exists()) {
        if (mounted) {
          m3Toast(context, 'ไม่พบไฟล์ — อาจถูกย้ายหรือลบไปแล้ว',
              tone: M3Tone.amber);
        }
        return;
      }
      final r = await OpenFile.open(path);
      if (!mounted) return;
      if (r.type != ResultType.done) {
        m3Toast(
          context,
          switch (r.type) {
            ResultType.noAppToOpen => 'ไม่มีโปรแกรมที่เปิดไฟล์ชนิดนี้ได้',
            ResultType.permissionDenied => 'ไม่ได้รับสิทธิ์ให้เปิดไฟล์',
            ResultType.fileNotFound => 'ไม่พบไฟล์ — อาจถูกย้ายหรือลบไปแล้ว',
            _ => 'เปิดไฟล์ไม่ได้ ลองเปิดจากโฟลเดอร์แทน',
          },
          tone: M3Tone.amber,
        );
      }
    } catch (_) {
      if (mounted) {
        m3Toast(context, 'เปิดไฟล์ไม่ได้ ลองเปิดจากโฟลเดอร์แทน',
            tone: M3Tone.amber);
      }
    } finally {
      _opening = false;
    }
  }

  Future<void> _openFolder(String dir, {bool create = false}) async {
    if (_opening) return;
    _opening = true;
    try {
      final d = Directory(dir);
      if (create) await d.create(recursive: true);
      if (!await d.exists()) {
        if (mounted) {
          m3Toast(context, 'ไม่พบโฟลเดอร์ — อาจถูกย้ายหรือลบไปแล้ว',
              tone: M3Tone.amber);
        }
        return;
      }
      final r = await OpenFile.open(dir);
      if (!mounted) return;
      if (r.type != ResultType.done) {
        m3Toast(context,
            'เปิดโฟลเดอร์ไม่ได้ — คัดลอกตำแหน่งไปวางใน File Explorer แทน',
            tone: M3Tone.amber);
      }
    } catch (_) {
      if (mounted) {
        m3Toast(context,
            'เปิดโฟลเดอร์ไม่ได้ — คัดลอกตำแหน่งไปวางใน File Explorer แทน',
            tone: M3Tone.amber);
      }
    } finally {
      _opening = false;
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    m3Toast(context, 'คัดลอกตำแหน่งแล้ว', tone: M3Tone.green);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final net = s.network.currentNetwork;
    final own = s.network.ownVirtualIp;

    final active = files.transfers.where(_isActive).toList();
    final activeHashes = {for (final t in active) t.fileHash};
    bool isMine(SharedFile f) =>
        files.isSeeder(f.fileHash) ||
        (own != null && f.ownerVirtualIp == own);
    final incomingAll = files.networkFiles
        .where((f) => !isMine(f) && !activeHashes.contains(f.fileHash))
        .toList();
    final incoming =
        incomingAll.where((f) => !_hidden.contains(f.fileHash)).toList();
    final hiddenCount = incomingAll.length - incoming.length;
    final mine = files.networkFiles.where(isMine).toList();
    final finished = files.transfers.where((t) => !_isActive(t)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final friends = s.network.members
        .where((m) => m.isOnline && m.virtualIp != own)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    return M3PageBody(
      onRefresh: _refreshAll,
      children: [
        M3PageHeader(
          icon3d: M3Icons.fileTransfer,
          title: 'ส่งไฟล์',
          subtitle: net == null
              ? 'เข้าร่วมวงเพื่อส่งไฟล์ถึงเพื่อน'
              : 'ส่งตรงถึงเครื่องในวง "${net.name}" · P2P พร้อมรีเลย์สำรอง',
          trailing: const ShellBadges(),
        ).animate().fadeIn(duration: 300.ms),
        const SizedBox(height: 16),
        if (net == null) ...[
          GlassPanel(
            child: M3EmptyState(
              icon3d: M3Icons.networks,
              title: 'ยังไม่ได้เข้าร่วมวง',
              message: 'เข้าร่วมหรือสร้างวงก่อน แล้วส่งไฟล์ถึงเพื่อนในวงได้ทันที',
              action: GlossButton(
                label: 'ไปหน้าเครือข่าย',
                icon3d: M3Icons.scan,
                onPressed: () =>
                    AppShellScope.of(context).goTo(ShellTab.networks),
              ),
            ),
          ).animate().fadeIn(delay: 60.ms, duration: 300.ms),
          const SizedBox(height: 16),
          _historyCard(finished),
        ] else ...[
          if (!s.p2p.isActive) ...[
            M3Banner(
              tone: M3Tone.amber,
              icon3d: M3Icons.relay,
              title: 'ช่องทาง P2P ยังไม่พร้อม',
              message: s.p2p.error != null
                  ? 'เปิดการเชื่อมต่อ P2P ไม่สำเร็จ ลองออกจากวงแล้วเข้าร่วมใหม่อีกครั้ง'
                  : 'เชื่อมต่อเครือข่ายก่อนเพื่อแชร์ไฟล์ — กำลังเปิดการเชื่อมต่อกับเพื่อนในวง',
            ),
            const SizedBox(height: 14),
          ],
          LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 840;
            final hero = _sendHero(
              netName: net.name,
              friends: friends,
              narrow: !wide && c.maxWidth < 600,
            );
            final activeCard = _activeCard(active, roomy: wide);
            final incomingCard = _incomingCard(incoming, hiddenCount);
            final history = _historyCard(finished);
            final mineCard = _mineCard(mine);
            const gap = SizedBox(height: 16, width: 16);

            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  hero,
                  gap,
                  activeCard,
                  gap,
                  incomingCard,
                  gap,
                  history,
                  gap,
                  mineCard,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 11, child: hero),
                    gap,
                    Expanded(flex: 9, child: activeCard),
                  ],
                ),
                gap,
                incomingCard,
                gap,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: history),
                    gap,
                    Expanded(child: mineCard),
                  ],
                ),
              ],
            );
          })
              .animate()
              .fadeIn(delay: 60.ms, duration: 350.ms)
              .slideY(begin: 0.03, end: 0),
        ],
      ],
    );
  }

  // ── Hero: pick files + who receives them ──────────────────────────────

  Widget _sendHero({
    required String netName,
    required List<NetworkMember> friends,
    required bool narrow,
  }) {
    final p = context.m3;
    return GlassPanel(
      highlight: true,
      gloss: false,
      radius: 24,
      accent: _sharing && _shareTotal > 0 ? p.cyan : null,
      padding: EdgeInsets.all(narrow ? 16 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon3D(M3Icons.fileTransfer,
                  size: narrow ? 54 : 70, glow: p.logoGlow),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ส่งไฟล์ถึงเพื่อนในวง',
                      style: TextStyle(
                        fontFamily: M3Fonts.head,
                        fontSize: narrow ? 21 : 25,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        shadows: p.titleShadow,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'วง "$netName" · ส่งตรงแบบ P2P ถ้าต่อตรงไม่ได้จะส่งผ่านรีเลย์ให้อัตโนมัติ',
                      style: M3Text.sub(context).copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _DropZone(
            busy: _sharing && _shareTotal > 0,
            done: _shareDone,
            total: _shareTotal,
            onTap: _sharing ? null : _pickAndShare,
          ),
          const SizedBox(height: 16),
          _recipients(friends),
        ],
      ),
    );
  }

  Widget _recipients(List<NetworkMember> friends) {
    const maxShown = 12;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('ผู้รับ', style: M3Text.h3(context)),
            const SizedBox(width: 8),
            const M3Tag('ทุกเครื่องในวง', tone: M3Tone.cyan),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'ออนไลน์ ${friends.length} เครื่อง',
                maxLines: 1,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: M3Text.sub(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          friends.isEmpty
              ? 'ยังไม่มีเพื่อนออนไลน์ — แชร์ไว้ก่อนได้ เพื่อนที่เข้าวงทีหลังจะเห็นไฟล์และรับได้ขณะที่เครื่องนี้ออนไลน์'
              : 'ไฟล์ที่แชร์จะขึ้นให้ทุกเครื่องในวงเห็นและกดรับได้ทันที',
          style: M3Text.sub(context),
        ),
        if (friends.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final m in friends.take(maxShown))
                _RecipientChip(
                  member: m,
                  direct: s.p2p.peers[m.virtualIp]?.isDirectConnected,
                ),
              if (friends.length > maxShown)
                Text('และอีก ${friends.length - maxShown} เครื่อง',
                    style: M3Text.sub(context)),
            ],
          ),
        ],
      ],
    );
  }

  // ── Active transfers ──────────────────────────────────────────────────

  Widget _activeCard(List<FileTransfer> active, {required bool roomy}) {
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.p2pDirect,
            title: 'กำลังส่ง / รับ',
            subtitle: active.isEmpty
                ? null
                : 'รับเป็นชิ้น ๆ จากหลายเครื่องพร้อมกัน',
            trailing: active.isEmpty ? null : M3Count(active.length),
          ),
          const SizedBox(height: 12),
          if (active.isEmpty)
            roomy
                ? const M3EmptyState(
                    icon3d: M3Icons.download,
                    title: 'ไม่มีการถ่ายโอนไฟล์',
                    message: 'ไฟล์ที่กำลังส่งหรือรับจะแสดงความคืบหน้าที่นี่',
                  )
                : const _QuietEmpty(
                    icon3d: M3Icons.download,
                    text: 'ไม่มีการถ่ายโอนไฟล์ — ไฟล์ที่กำลังรับจะแสดงความคืบหน้าที่นี่',
                  )
          else
            for (var i = 0; i < active.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _activeTile(active[i]),
            ],
        ],
      ),
    );
  }

  Widget _activeTile(FileTransfer t) {
    final p = context.m3;
    final up = t.direction == TransferDirection.upload;
    final waiting = t.status == TransferStatus.waiting;
    final route = _routeTag(t);
    return M3Inset(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon3D(up ? M3Icons.upload : M3Icons.download, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: M3Text.h3(context),
                    ),
                    Text(
                      '${up ? 'ส่งให้' : 'รับจาก'} ${t.peerDisplayName} · ${t.fileSizeFormatted}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: M3Text.sub(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (waiting)
                Text(
                  'รอ seeder...',
                  style: TextStyle(
                    fontFamily: M3Fonts.head,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p.amber,
                  ),
                )
              else
                Text('${(t.progress * 100).toStringAsFixed(0)}%',
                    style: M3Text.num(context, size: 20)),
            ],
          ),
          const SizedBox(height: 10),
          M3ProgressBar(
            value: waiting ? null : t.progress,
            tone: up ? M3Tone.green : M3Tone.cyan,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!waiting)
                      Text(
                        t.speedFormatted,
                        style: M3Text.mono(context,
                            size: 12,
                            weight: FontWeight.w700,
                            color: p.numText),
                      ),
                    if (!waiting)
                      Text(
                        '${t.completedChunks.length}/${t.totalChunks} ชิ้น · ${t.activeSeeders.length} seeders',
                        style: M3Text.mono(context, size: 11.5, color: p.text3),
                      ),
                    ?route,
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GlossButton(
                label: 'ยกเลิก',
                icon: Icons.close_rounded,
                size: GlossSize.small,
                variant: GlossVariant.glass,
                onPressed: () => _cancel(t),
              ),
            ],
          ),
          if (t.error != null) ...[
            const SizedBox(height: 6),
            Text(_friendly(t.error!),
                style: M3Text.sub(context).copyWith(color: p.red)),
          ],
        ],
      ),
    );
  }

  /// Direct / relay tag from the P2P state of the machines we pull from.
  Widget? _routeTag(FileTransfer t) {
    final states = [
      for (final vip in t.activeSeeders) s.p2p.peers[vip]?.isDirectConnected,
    ].whereType<bool>().toList();
    if (states.isEmpty) return null;
    final direct = states.where((d) => d).length;
    final relay = states.length - direct;
    if (relay == 0) {
      return const M3Tag('P2P ตรง', tone: M3Tone.green, icon: Icons.bolt_rounded);
    }
    if (direct == 0) {
      return const M3Tag('ผ่านรีเลย์',
          tone: M3Tone.amber, icon: Icons.swap_horiz_rounded);
    }
    return M3Tag('ตรง $direct · รีเลย์ $relay', tone: M3Tone.cyan);
  }

  // ── Incoming (files friends shared) ───────────────────────────────────

  Widget _incomingCard(List<SharedFile> incoming, int hiddenCount) {
    final loading = files.isLoading;
    final firstLoad = loading && files.networkFiles.isEmpty;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.download,
            title: 'ไฟล์ที่เพื่อนแชร์มา',
            subtitle:
                'กดรับเพื่อดาวน์โหลดตรงจากเครื่องเพื่อน ยิ่งมีคนแชร์ต่อยิ่งเร็ว',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (incoming.isNotEmpty) ...[
                  M3Count(incoming.length),
                  const SizedBox(width: 10),
                ],
                if (loading && !firstLoad) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                GlossIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'รีเฟรช',
                  onPressed: loading ? null : () => files.refreshFileList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (firstLoad)
            const M3EmptyState(
              icon3d: M3Icons.folder,
              title: 'กำลังโหลดรายการไฟล์…',
            )
          else if (incoming.isEmpty)
            M3EmptyState(
              icon3d: M3Icons.folder,
              title: files.networkFiles.isNotEmpty
                  ? 'ไม่มีไฟล์ใหม่จากเพื่อน'
                  : 'ยังไม่มีไฟล์ในเครือข่าย',
              message:
                  'กดปุ่ม "เลือกไฟล์" เพื่อเริ่มแชร์ หรือรอให้เพื่อนในวงแชร์ไฟล์มา',
              action: GlossButton(
                label: 'รีเฟรชรายการ',
                icon: Icons.refresh_rounded,
                variant: GlossVariant.glass,
                loading: loading,
                onPressed: loading ? null : () => files.refreshFileList(),
              ),
            )
          else
            for (var i = 0; i < incoming.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _incomingTile(incoming[i]),
            ],
          if (hiddenCount > 0) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: M3Chip(
                label: 'แสดงไฟล์ที่ซ่อน ($hiddenCount)',
                icon: Icons.visibility_rounded,
                onTap: () => setState(_hidden.clear),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _incomingTile(SharedFile f) {
    final p = context.m3;
    final busy = _receiving.contains(f.fileHash);
    final failed = files.transfers
        .where((t) =>
            t.fileHash == f.fileHash && t.status == TransferStatus.failed)
        .firstOrNull;
    final seeds = f.onlineSeedersCount;
    return _FileTile(
      leading: _FileGlyph(fileName: f.fileName),
      title: f.fileName,
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(f.fileSizeFormatted, style: M3Text.sub(context)),
          Text('จาก ${f.ownerDisplayName}', style: M3Text.sub(context)),
          M3Tag('$seeds seed',
              tone: seeds > 0 ? M3Tone.cyan : M3Tone.amber,
              icon: Icons.cloud_upload_rounded),
        ],
      ),
      footer: failed?.error == null
          ? null
          : Text(
              'รอบก่อน: ${_friendly(failed!.error!)}',
              style: M3Text.sub(context).copyWith(color: p.red),
            ),
      actions: [
        GlossButton(
          label: failed != null ? 'ลองใหม่' : 'รับไฟล์',
          icon: Icons.download_rounded,
          size: GlossSize.small,
          variant: GlossVariant.green,
          loading: busy,
          onPressed: busy ? null : () => _receive(f),
        ),
        GlossButton(
          label: 'ไม่รับ',
          size: GlossSize.small,
          variant: GlossVariant.glass,
          tooltip: 'ซ่อนไฟล์นี้จากรายการ',
          onPressed: busy ? null : () => _decline(f),
        ),
      ],
    );
  }

  // ── History + received folder ─────────────────────────────────────────

  Widget _historyCard(List<FileTransfer> finished) {
    final received = finished
        .where((t) =>
            t.status == TransferStatus.completed &&
            t.direction == TransferDirection.download)
        .length;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.folder,
            title: 'ประวัติและไฟล์ที่ได้รับ',
            subtitle: received > 0
                ? 'รับครบแล้ว $received ไฟล์ · ประวัติจะล้างเมื่อปิดโปรแกรม'
                : 'ประวัติจะล้างเมื่อปิดโปรแกรม ไฟล์ที่รับแล้วยังอยู่ในโฟลเดอร์',
            trailing: finished.isEmpty ? null : M3Count(finished.length),
          ),
          const SizedBox(height: 12),
          _downloadFolderBox(),
          const SizedBox(height: 12),
          if (finished.isEmpty)
            const _QuietEmpty(
              icon3d: M3Icons.file,
              text: 'ยังไม่มีประวัติการรับส่งไฟล์',
            )
          else
            for (var i = 0; i < finished.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _historyTile(finished[i]),
            ],
        ],
      ),
    );
  }

  Widget _downloadFolderBox() {
    final p = context.m3;
    final dir = _downloadDir;
    return M3Inset(
      child: Row(
        children: [
          const Icon3D(M3Icons.folder, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('ไฟล์ที่ได้รับบันทึกไว้ที่',
                    style: M3Text.sub(context).copyWith(fontSize: 11.5)),
                const SizedBox(height: 2),
                Text(
                  dir ?? 'หาโฟลเดอร์เอกสารของเครื่องไม่พบ',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: M3Text.mono(context,
                      size: 12.5, weight: FontWeight.w600, color: p.numText),
                ),
              ],
            ),
          ),
          if (dir != null) ...[
            const SizedBox(width: 8),
            GlossIconButton(
              icon: Icons.copy_rounded,
              size: 30,
              tooltip: 'คัดลอกตำแหน่ง',
              onPressed: () => _copy(dir),
            ),
            if (isDesktop) ...[
              const SizedBox(width: 6),
              GlossIconButton(
                icon: Icons.folder_open_rounded,
                size: 30,
                tooltip: 'เปิดโฟลเดอร์',
                onPressed: () => _openFolder(dir, create: true),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _historyTile(FileTransfer t) {
    final p = context.m3;
    final up = t.direction == TransferDirection.upload;
    final (label, tone) = _statusOf(t);
    final path = t.status == TransferStatus.completed &&
            !up &&
            t.localPath != null
        ? paths.normalize(t.localPath!)
        : null;
    return _FileTile(
      leading: _FileGlyph(
        fileName: t.fileName,
        opacity: t.status == TransferStatus.completed ? 1 : 0.55,
      ),
      title: t.fileName,
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          M3Tag(label, tone: tone, dot: true),
          Text(
            '${up ? 'ส่ง' : 'รับ'} · ${t.fileSizeFormatted} · เริ่ม ${_hhmm(t.createdAt)}',
            style: M3Text.sub(context),
          ),
        ],
      ),
      footer: path != null
          ? Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: M3Text.mono(context, size: 11.5, color: p.text3),
            )
          : (t.error != null
              ? Text(_friendly(t.error!),
                  style: M3Text.sub(context).copyWith(color: p.red))
              : null),
      actions: [
        if (path != null)
          GlossButton(
            label: 'เปิดไฟล์',
            icon: Icons.open_in_new_rounded,
            size: GlossSize.small,
            onPressed: () => _openFile(path, received: true),
          ),
        if (path != null && isDesktop)
          GlossIconButton(
            icon: Icons.folder_open_rounded,
            size: 30,
            tooltip: 'เปิดโฟลเดอร์ที่เก็บไฟล์',
            onPressed: () => _openFolder(paths.dirname(path)),
          ),
        if (path != null)
          GlossIconButton(
            icon: Icons.copy_rounded,
            size: 30,
            tooltip: 'คัดลอกตำแหน่งไฟล์',
            onPressed: () => _copy(path),
          ),
        GlossIconButton(
          icon: Icons.delete_outline_rounded,
          size: 30,
          tooltip: 'ลบออกจากรายการ',
          onPressed: () => _removeTransfer(t),
        ),
      ],
    );
  }

  // ── Files this machine shares ─────────────────────────────────────────

  Widget _mineCard(List<SharedFile> mine) {
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3CardHeader(
            icon3d: M3Icons.upload,
            title: 'ไฟล์ที่แชร์จากเครื่องนี้',
            subtitle: 'เพื่อนรับไฟล์จากเครื่องนี้ได้ขณะที่เปิดโปรแกรมอยู่',
            trailing: mine.isEmpty ? null : M3Count(mine.length),
          ),
          const SizedBox(height: 12),
          if (mine.isEmpty)
            const _QuietEmpty(
              icon3d: M3Icons.upload,
              text: 'ยังไม่ได้แชร์ไฟล์ — เลือกไฟล์ด้านบนเพื่อเริ่มส่ง',
            )
          else
            for (var i = 0; i < mine.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _mineTile(mine[i]),
            ],
        ],
      ),
    );
  }

  Widget _mineTile(SharedFile f) {
    final own = s.network.ownVirtualIp;
    final ownerIsMe = own != null && f.ownerVirtualIp == own;
    final seeding = files.isSeeder(f.fileHash);
    final local = f.localPath ??
        files.transfers
            .where((t) =>
                t.fileHash == f.fileHash &&
                t.status == TransferStatus.completed &&
                t.localPath != null)
            .firstOrNull
            ?.localPath;
    final busy = _unsharing.contains(f.id);
    return _FileTile(
      leading: _FileGlyph(fileName: f.fileName, opacity: seeding ? 1 : 0.55),
      title: f.fileName,
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(f.fileSizeFormatted, style: M3Text.sub(context)),
          if (!seeding)
            const M3Tag('ไม่ได้ปล่อยไฟล์อยู่', tone: M3Tone.amber)
          else if (ownerIsMe)
            const M3Tag('ของฉัน',
                tone: M3Tone.green, icon: Icons.check_circle_rounded)
          else
            const M3Tag('รับมาแล้ว · ช่วยแชร์ต่อ',
                tone: M3Tone.green, icon: Icons.check_circle_rounded),
          M3Tag('${f.onlineSeedersCount} seed',
              tone: M3Tone.cyan, icon: Icons.cloud_upload_rounded),
        ],
      ),
      footer: seeding
          ? null
          : Text(
              'เปิดโปรแกรมใหม่แล้วจึงไม่ได้ปล่อยไฟล์นี้ เลือกไฟล์เดิมเพื่อแชร์อีกครั้ง',
              style: M3Text.sub(context),
            ),
      actions: [
        if (local != null)
          GlossButton(
            label: 'เปิด',
            icon: Icons.open_in_new_rounded,
            size: GlossSize.small,
            variant: GlossVariant.glass,
            onPressed: () => _openFile(local, received: !ownerIsMe),
          ),
        if (ownerIsMe)
          GlossButton(
            label: 'หยุดแชร์',
            size: GlossSize.small,
            variant: GlossVariant.glass,
            loading: busy,
            onPressed: busy ? null : () => _unshare(f),
          ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  static bool _isActive(FileTransfer t) =>
      t.status == TransferStatus.waiting ||
      t.status == TransferStatus.transferring;

  static (String, M3Tone) _statusOf(FileTransfer t) => switch (t.status) {
        TransferStatus.waiting => ('รอ seeder...', M3Tone.amber),
        TransferStatus.transferring => (
            '${(t.progress * 100).toStringAsFixed(0)}%',
            M3Tone.cyan
          ),
        TransferStatus.completed => ('เสร็จ', M3Tone.green),
        TransferStatus.failed => ('ล้มเหลว', M3Tone.red),
        TransferStatus.cancelled => ('ยกเลิก', M3Tone.neutral),
      };

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Service errors are Thai, but a few append the raw exception
  /// ("บันทึกไฟล์ล้มเหลว: FileSystemException…") — keep only the Thai part.
  static String _friendly(String e) {
    final i = e.indexOf(': ');
    if (i > 0 &&
        RegExp(r'(Exception|Error|errno)', caseSensitive: false)
            .hasMatch(e.substring(i))) {
      return e.substring(0, i);
    }
    return e;
  }
}

// ── Private widgets ─────────────────────────────────────────────────────

/// Big dashed "drop zone" style button that opens the file picker.
class _DropZone extends StatefulWidget {
  final bool busy;
  final int done;
  final int total;
  final VoidCallback? onTap;

  const _DropZone({
    required this.busy,
    required this.done,
    required this.total,
    required this.onTap,
  });

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final enabled = widget.onTap != null;
    final hot = _hover && enabled;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final verb = isMobile ? 'แตะ' : 'คลิก';

    final String title;
    final String sub;
    if (widget.busy) {
      title = 'กำลังเตรียมไฟล์…';
      sub = widget.total > 1
          ? 'แชร์แล้ว ${widget.done} จาก ${widget.total} ไฟล์ · ไฟล์ใหญ่ใช้เวลาตรวจสอบสักครู่'
          : 'กำลังตรวจสอบไฟล์และลงทะเบียนในวง · ไฟล์ใหญ่ใช้เวลาสักครู่';
    } else {
      title = 'เลือกไฟล์เพื่อส่ง';
      sub = '$verbเพื่อเลือกไฟล์ (เลือกได้หลายไฟล์) แล้วทุกเครื่องในวงจะกดรับได้ทันที';
    }

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                SoundService().play(SfxType.tap);
                widget.onTap!();
              }
            : null,
        child: CustomPaint(
          foregroundPainter: _DashedBorderPainter(
            color: hot || widget.busy ? p.cyan : p.cyanSoftLine,
            radius: 16,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: EdgeInsets.symmetric(
                horizontal: 16, vertical: narrow ? 18 : 26),
            decoration: BoxDecoration(
              color: hot ? p.hover : p.inset,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                AnimatedScale(
                  scale: hot ? 1.08 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: Icon3D(M3Icons.upload, size: narrow ? 58 : 72),
                ),
                const SizedBox(height: 10),
                Text(title,
                    textAlign: TextAlign.center, style: M3Text.h2(context)),
                const SizedBox(height: 4),
                Text(sub,
                    textAlign: TextAlign.center, style: M3Text.sub(context)),
                const SizedBox(height: 14),
                if (widget.busy)
                  SizedBox(
                    width: 240,
                    child: M3ProgressBar(
                      value: widget.total > 1
                          ? widget.done / widget.total
                          : null,
                    ),
                  )
                else
                  GlossButton(
                    label: 'เลือกไฟล์',
                    icon: Icons.add_rounded,
                    onPressed: widget.onTap,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedBorderPainter({required this.color, required this.radius});

  static const double _stroke = 1.6;
  static const double _dash = 7;
  static const double _gap = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(_stroke / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = math.min(d + _dash, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

/// One online friend in the hero's "ผู้รับ" list.
class _RecipientChip extends StatelessWidget {
  final NetworkMember member;
  final bool? direct;

  const _RecipientChip({required this.member, this.direct});

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    final d = direct;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
      decoration: BoxDecoration(
        color: p.inset,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon3D(
            _isPhone(member.displayName)
                ? M3Icons.devicePhone
                : M3Icons.devicePc,
            size: 26,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              member.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: M3Text.h3(context).copyWith(fontSize: 13),
            ),
          ),
          const SizedBox(width: 6),
          if (d != null)
            M3Tag(d ? 'ตรง' : 'รีเลย์',
                tone: d ? M3Tone.green : M3Tone.amber)
          else
            StatusOrb(color: p.green, size: 7, pulse: false),
        ],
      ),
    );
  }
}

/// A file row inside a card. Actions sit on the right, or drop below the
/// text when the card is too narrow for them.
class _FileTile extends StatelessWidget {
  final Widget leading;
  final String title;
  final Widget? subtitle;
  final Widget? footer;
  final List<Widget> actions;

  const _FileTile({
    required this.leading,
    required this.title,
    this.subtitle,
    this.footer,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: p.row,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line.withValues(alpha: 0.5)),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final info = Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: M3Text.h3(context),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    subtitle!,
                  ],
                  if (footer != null) ...[
                    const SizedBox(height: 3),
                    footer!,
                  ],
                ],
              ),
            ),
          ],
        );
        if (actions.isEmpty) return info;
        final stacked = c.maxWidth < 300 + actions.length * 60;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              info,
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: info),
            const SizedBox(width: 10),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              actions[i],
            ],
          ],
        );
      }),
    );
  }
}

/// 3D file icon with a small badge for the file type.
class _FileGlyph extends StatelessWidget {
  final String fileName;
  final double opacity;

  const _FileGlyph({required this.fileName, this.opacity = 1});

  static const double size = 40;

  @override
  Widget build(BuildContext context) {
    final p = context.m3;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon3D(M3Icons.file, size: size, opacity: opacity),
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: p.popup,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: p.line),
              ),
              child: Icon(_fileIcon(fileName), size: 11, color: p.cyan),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small one-line empty state for secondary cards.
class _QuietEmpty extends StatelessWidget {
  final String icon3d;
  final String text;

  const _QuietEmpty({required this.icon3d, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon3D(icon3d, size: 34, opacity: 0.7),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: M3Text.sub(context))),
        ],
      ),
    );
  }
}

bool _isPhone(String name) {
  final n = name.toLowerCase();
  return n.contains('android') || n.contains('phone') || n.contains('iphone');
}

IconData _fileIcon(String fileName) {
  final ext = paths.extension(fileName).replaceFirst('.', '').toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'bmp' => Icons.image,
    'mp4' || 'avi' || 'mov' || 'mkv' || 'wmv' => Icons.movie,
    'mp3' || 'wav' || 'flac' || 'aac' || 'ogg' => Icons.music_note,
    'pdf' => Icons.picture_as_pdf,
    'doc' || 'docx' => Icons.description,
    'xls' || 'xlsx' => Icons.table_chart,
    'ppt' || 'pptx' => Icons.slideshow,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.archive,
    'apk' => Icons.android,
    'txt' || 'md' || 'log' => Icons.text_snippet,
    _ => Icons.insert_drive_file,
  };
}

/// Files that run code when opened — ask before opening one a peer sent.
bool _isRiskyFile(String fileName) {
  const risky = {
    'exe', 'msi', 'msix', 'bat', 'cmd', 'com', 'scr', 'pif', 'cpl', 'msc',
    'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'hta', 'lnk',
    'url', 'reg', 'jar', 'apk', 'appx', 'appxbundle',
  };
  final ext = paths.extension(fileName).replaceFirst('.', '').toLowerCase();
  return risky.contains(ext);
}
