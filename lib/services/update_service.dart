import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateService extends ChangeNotifier {
  static const String _checkUpdateUrl =
      'https://xman4289.com/api/v1/product/localvpn/update/check';
  static const String _prefLastUpdateCheck = 'last_update_check';
  static const Duration _checkInterval = Duration(hours: 6);

  /// MethodChannel for native APK installation
  static const MethodChannel _installChannel =
      MethodChannel('com.xjanova.localvpn/installer');

  String _currentVersion = '1.0.0';

  bool _updateAvailable = false;
  bool get updateAvailable => _updateAvailable;

  String? _latestVersion;
  String? get latestVersion => _latestVersion;

  String? _downloadUrl;
  String? get downloadUrl => _downloadUrl;

  String? _changelog;
  String? get changelog => _changelog;

  bool _isChecking = false;
  bool get isChecking => _isChecking;

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  double _downloadProgress = 0.0;
  double get downloadProgress => _downloadProgress;

  String? _downloadError;
  String? get downloadError => _downloadError;

  String get currentVersion => _currentVersion;

  Future<void> checkForUpdate({bool force = false}) async {
    if (_isChecking) return;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;
    } catch (_) {}

    if (!force) {
      final prefs = await SharedPreferences.getInstance();
      final lastCheck = prefs.getString(_prefLastUpdateCheck);
      if (lastCheck != null) {
        final last = DateTime.tryParse(lastCheck);
        if (last != null &&
            DateTime.now().difference(last) < _checkInterval) {
          return;
        }
      }
    }

    _isChecking = true;
    notifyListeners();

    try {
      final uri = Uri.parse(_checkUpdateUrl).replace(
        queryParameters: {'current_version': _currentVersion},
      );
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _latestVersion = data['latest_version'] as String?;
        _downloadUrl = data['download_url'] as String?;
        _changelog = data['changelog'] as String?;

        // Verify with local semantic version comparison
        final serverSaysUpdate = data['has_update'] == true;
        _updateAvailable = serverSaysUpdate &&
            _latestVersion != null &&
            _isNewerVersion(_currentVersion, _latestVersion!);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefLastUpdateCheck,
          DateTime.now().toIso8601String(),
        );
      }
    } catch (e) {
      debugPrint('Update check error: $e');
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  /// Semantic version comparison: returns true if latest > current
  bool _isNewerVersion(String current, String latest) {
    try {
      final curr = current.split('.').map(int.parse).toList();
      final lat = latest.split('.').map(int.parse).toList();

      // Pad to same length
      while (curr.length < lat.length) {
        curr.add(0);
      }
      while (lat.length < curr.length) {
        lat.add(0);
      }

      for (int i = 0; i < curr.length; i++) {
        if (lat[i] > curr[i]) return true;
        if (lat[i] < curr[i]) return false;
      }
      return false; // equal
    } catch (_) {
      return true; // can't parse, trust server
    }
  }

  Future<void> downloadUpdate() async {
    if (_downloadUrl == null || _isDownloading) return;

    _isDownloading = true;
    _downloadProgress = 0.0;
    _downloadError = null;
    notifyListeners();

    http.Client? client;
    try {
      final uri = Uri.parse(_downloadUrl!);
      client = http.Client();
      final request = http.Request('GET', uri);
      final streamedResponse = await client.send(request);

      if (streamedResponse.statusCode != 200) {
        throw HttpException(
          'ดาวน์โหลดล้มเหลว (${streamedResponse.statusCode})',
        );
      }

      final contentLength = streamedResponse.contentLength ?? 0;
      final fileName = 'LocalVPN-${_latestVersion ?? "update"}.apk';

      // Use app cache directory (works on all Android versions, no permissions needed)
      final dir = await _getDownloadDir();
      final filePath = '${dir.path}/$fileName';
      final file = File(filePath);

      // Delete old file if exists
      if (await file.exists()) {
        await file.delete();
      }

      final sink = file.openWrite();
      int received = 0;

      await for (final chunk in streamedResponse.stream) {
        sink.add(chunk);
        received += chunk.length;

        if (contentLength > 0) {
          _downloadProgress = received / contentLength;
        } else {
          _downloadProgress = -1;
        }
        notifyListeners();
      }

      await sink.flush();
      await sink.close();
      client.close();

      _downloadProgress = 1.0;
      _isDownloading = false;
      notifyListeners();

      // Install the APK via native intent with FileProvider
      await _installApk(filePath);
    } catch (e) {
      client?.close();
      _downloadError = e.toString().replaceFirst('Exception: ', '');
      _isDownloading = false;
      _downloadProgress = 0.0;
      notifyListeners();
      debugPrint('Download update error: $e');
    }
  }

  /// Get a writable directory for APK downloads.
  /// Tries external files dir first, falls back to cache.
  Future<Directory> _getDownloadDir() async {
    // Try external files directory (app-specific, no permission needed)
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) return extDir;
    } catch (_) {}

    // Fallback to app cache
    return await getTemporaryDirectory();
  }

  /// Install APK using native FileProvider intent.
  /// Falls back to open_file if native channel is not available.
  Future<void> _installApk(String filePath) async {
    try {
      // Use native MethodChannel to install via FileProvider content:// URI
      await _installChannel.invokeMethod('installApk', {'path': filePath});
    } on MissingPluginException {
      // Native handler not implemented — try direct open as fallback
      debugPrint('Native installer not available, trying direct open');
      try {
        // Import and use open_file as fallback
        final result = await Process.run('am', [
          'start',
          '-a', 'android.intent.action.VIEW',
          '-t', 'application/vnd.android.package-archive',
          '-d', 'file://$filePath',
        ]);
        debugPrint('Direct install result: ${result.exitCode}');
      } catch (e) {
        _downloadError = 'ไม่สามารถติดตั้งได้อัตโนมัติ กรุณาติดตั้งด้วยตนเอง: $filePath';
        notifyListeners();
      }
    } catch (e) {
      _downloadError = 'ติดตั้งไม่สำเร็จ: $e';
      notifyListeners();
    }
  }

  /// Clean up old APK files
  Future<void> cleanupOldApks() async {
    try {
      final dir = await _getDownloadDir();
      final files = dir.listSync().where(
          (f) => f is File && f.path.endsWith('.apk'));
      for (final file in files) {
        try {
          await (file as File).delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  void clearError() {
    _downloadError = null;
    notifyListeners();
  }
}
