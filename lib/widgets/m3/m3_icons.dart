import 'package:flutter/material.dart';

/// The app's 3D icon set (assets/m3/icons, generated for LocalVPN).
class M3Icons {
  M3Icons._();

  static const _dir = 'assets/m3/icons';

  static const String networks = '$_dir/networks.webp';
  static const String createNetwork = '$_dir/create-network.webp';
  static const String scan = '$_dir/scan.webp';
  static const String members = '$_dir/members.webp';
  static const String fileTransfer = '$_dir/file-transfer.webp';
  static const String torrent = '$_dir/torrent.webp';
  static const String vpnProxy = '$_dir/vpn-proxy.webp';
  static const String gameBoost = '$_dir/game-boost.webp';
  static const String ping = '$_dir/ping.webp';
  static const String smartRoute = '$_dir/smart-route.webp';
  static const String p2pDirect = '$_dir/p2p-direct.webp';
  static const String relay = '$_dir/relay.webp';
  static const String upload = '$_dir/upload.webp';
  static const String download = '$_dir/download.webp';
  static const String leaderboard = '$_dir/leaderboard.webp';
  static const String trophy = '$_dir/trophy.webp';
  static const String folder = '$_dir/folder.webp';
  static const String file = '$_dir/file.webp';
  static const String profile = '$_dir/profile.webp';
  static const String kyc = '$_dir/kyc.webp';
  static const String crown = '$_dir/crown.webp';
  static const String update = '$_dir/update.webp';
  static const String lock = '$_dir/lock.webp';
  static const String qr = '$_dir/qr.webp';
  static const String settings = '$_dir/settings.webp';
  static const String power = '$_dir/power.webp';
  static const String invite = '$_dir/invite.webp';
  static const String adapter = '$_dir/adapter.webp';
  static const String devicePc = '$_dir/device-pc.webp';
  static const String devicePhone = '$_dir/device-phone.webp';

  static const String logo = 'assets/m3/logo.webp';

  static const List<String> all = [
    networks, createNetwork, scan, members, fileTransfer, torrent,
    vpnProxy, gameBoost, ping, smartRoute, p2pDirect, relay,
    upload, download, leaderboard, trophy, folder, file,
    profile, kyc, crown, update, lock, qr,
    settings, power, invite, adapter, devicePc, devicePhone, logo,
  ];

  /// Warm the image cache so icons don't pop in on first paint.
  static Future<void> precache(BuildContext context) async {
    for (final a in all) {
      await precacheImage(AssetImage(a), context);
    }
  }
}

/// A 3D icon image. Use instead of Material [Icon] for anything that
/// represents a feature, a section or a state.
class Icon3D extends StatelessWidget {
  final String asset;
  final double size;
  final double opacity;

  /// Adds a soft coloured halo behind the icon (hero spots only).
  final Color? glow;

  const Icon3D(
    this.asset, {
    super.key,
    this.size = 40,
    this.opacity = 1,
    this.glow,
  });

  @override
  Widget build(BuildContext context) {
    Widget img = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      isAntiAlias: true,
      gaplessPlayback: true,
    );
    if (opacity < 1) img = Opacity(opacity: opacity, child: img);
    if (glow == null) return img;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size * 0.7,
          height: size * 0.7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: glow!,
                blurRadius: size * 0.45,
                spreadRadius: size * 0.05,
              ),
            ],
          ),
        ),
        img,
      ],
    );
  }
}
