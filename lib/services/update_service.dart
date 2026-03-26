import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateService extends ChangeNotifier {
  static const String _checkUpdateUrl =
      'https://xman4289.com/api/v1/product/localvpn/update/check';
  static const String _currentVersion = '1.0.0';
  static const String _prefLastUpdateCheck = 'last_update_check';
  static const Duration _checkInterval = Duration(hours: 6);

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

  String get currentVersion => _currentVersion;

  Future<void> checkForUpdate({bool force = false}) async {
    if (_isChecking) return;

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
    if (_downloadUrl == null) return;

    final uri = Uri.tryParse(_downloadUrl!);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
