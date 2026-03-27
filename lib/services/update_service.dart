import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateService extends ChangeNotifier {
  static const String _checkUpdateUrl =
      'https://xman4289.com/api/v1/product/localvpn/update/check';
  static const String _prefLastUpdateCheck = 'last_update_check';
  static const Duration _checkInterval = Duration(hours: 6);

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

    // Get real version from package info
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;
    } catch (_) {
      // Fallback to default
    }

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
        _updateAvailable = data['has_update'] == true;

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

      // Save to app's external storage directory
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        throw const FileSystemException('ไม่สามารถเข้าถึง storage ได้');
      }

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
          // Unknown total: show indeterminate-like progress
          _downloadProgress = -1;
        }
        notifyListeners();
      }

      await sink.flush();
      await sink.close();

      _downloadProgress = 1.0;
      _isDownloading = false;
      notifyListeners();

      client.close();

      // Open the APK to trigger install prompt
      await OpenFile.open(filePath);
    } catch (e) {
      client?.close();
      _downloadError = e.toString().replaceFirst('Exception: ', '');
      _isDownloading = false;
      _downloadProgress = 0.0;
      notifyListeners();
      debugPrint('Download update error: $e');
    }
  }

  void clearError() {
    _downloadError = null;
    notifyListeners();
  }
}
