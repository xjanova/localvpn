import 'package:flutter/material.dart';

import '../services/p2p_service.dart';
import 'm3/m3.dart';

/// How a member is reached: direct P2P (free), the relay, still connecting,
/// or not at all (different app version).
class PeerPathTag extends StatelessWidget {
  const PeerPathTag(this.path, {super.key, this.short = false});

  final P2pPath path;

  /// One-word labels for chips.
  final bool short;

  @override
  Widget build(BuildContext context) {
    final (label, shortLabel, tone) = switch (path) {
      P2pPath.direct => ('P2P ตรง', 'ตรง', M3Tone.green),
      P2pPath.relay => ('ผ่านรีเลย์', 'รีเลย์', M3Tone.amber),
      P2pPath.connecting => ('กำลังเชื่อม', 'เชื่อม…', M3Tone.neutral),
      P2pPath.unavailable => ('ต้องอัปเดตแอป', 'อัปเดต', M3Tone.red),
    };
    return M3Tag(short ? shortLabel : label, tone: tone);
  }
}
