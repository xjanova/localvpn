import '../../services/file_transfer_service.dart';
import '../../services/game_boost_service.dart';
import '../../services/license_service.dart';
import '../../services/network_service.dart';
import '../../services/p2p_service.dart';
import '../../services/torrent_service.dart';
import '../../services/update_service.dart';
import '../../services/vpn_proxy_service.dart';
import '../../services/vpn_service.dart';

/// Every long-lived service, created once by the shell and handed to the
/// screens that need them.
class AppServices {
  final LicenseService license;
  final NetworkService network = NetworkService();
  final VpnService vpn = VpnService();
  final P2pService p2p = P2pService();
  final FileTransferService files = FileTransferService();
  final TorrentService torrent = TorrentService();
  final VpnProxyService proxy = VpnProxyService();
  final UpdateService update = UpdateService();
  late final GameBoostService boost = GameBoostService(proxy: proxy);

  AppServices(this.license) {
    final deviceId = license.deviceId;
    if (deviceId == null) return;
    final key = license.state.licenseKey;

    network.configure(deviceId: deviceId, licenseKey: key);
    network.attachP2p(p2p);
    vpn.attachP2p(p2p);

    files.configure(p2pService: p2p, deviceId: deviceId, licenseKey: key ?? '');
    p2p.onFileMessage = files.handleMessage;

    torrent.configure(
      machineId: deviceId,
      licenseKey: key,
      displayName: 'Device-${deviceId.substring(0, 8)}',
    );
    proxy.configure(deviceId: deviceId, licenseKey: key);
    _lastKey = key;
    license.addListener(_onLicenseChanged);
  }

  String? _lastKey;

  /// Activating or upgrading a licence while the app runs: hand the new key
  /// to every service so PRO limits lift without a restart.
  void _onLicenseChanged() {
    final deviceId = license.deviceId;
    final key = license.state.licenseKey;
    if (deviceId == null || key == _lastKey) return;
    _lastKey = key;
    network.configure(deviceId: deviceId, licenseKey: key);
    files.configure(p2pService: p2p, deviceId: deviceId, licenseKey: key ?? '');
    torrent.configure(
      machineId: deviceId,
      licenseKey: key,
      displayName: 'Device-${deviceId.substring(0, 8)}',
    );
    proxy.setLicenseKey(key);
  }

  /// Anything that keeps traffic flowing (worth hiding to the tray instead
  /// of quitting when the window closes).
  bool get hasActiveConnection =>
      vpn.isConnected ||
      proxy.status == VpnProxyStatus.connected ||
      proxy.status == VpnProxyStatus.connecting ||
      boost.isActive;

  Future<void> disconnectAll() async {
    await boost.stop();
    if (vpn.isConnected) await vpn.stopVpn();
    if (proxy.status != VpnProxyStatus.disconnected) await proxy.disconnect();
  }

  void dispose() {
    license.removeListener(_onLicenseChanged);
    boost.dispose();
    network.dispose();
    vpn.dispose();
    p2p.dispose();
    files.dispose();
    torrent.dispose();
    proxy.dispose();
    update.dispose();
  }
}
