import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  AppConfig._();

  static const String devMode = 'dev';
  static const String prodMode = 'prod';
  static const String customMode = 'custom';

  static const String prodBaseUrl = 'https://dir.anasrawuthar.in';
  static const String devBaseUrl = 'https://dir.anasrawuthar.in';

  static const String _modeKey = 'app_server_mode';
  static const String _customUrlKey = 'app_custom_base_url';

  static String _mode = prodMode;
  static String _customBaseUrl = '';

  static String get mode => _mode;
  static String get customBaseUrl => _customBaseUrl;

  static String get baseUrl {
    if (_mode == customMode && _customBaseUrl.isNotEmpty) {
      return _customBaseUrl;
    }
    return prodBaseUrl;
  }

  static String get wsBaseUrl {
    final base = baseUrl;
    if (base.startsWith('https://')) {
      return base.replaceFirst('https://', 'wss://');
    }
    return base.replaceFirst('http://', 'ws://');
  }

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString(_modeKey) ?? prodMode;
    _customBaseUrl = prefs.getString(_customUrlKey) ?? '';

    // Auto-clean stale LAN / local developer IPs from previous versions
    if (_customBaseUrl.contains('192.168.') ||
        _customBaseUrl.contains('10.0.2.2') ||
        _customBaseUrl.contains('127.0.0.1') ||
        _customBaseUrl.contains(':3000')) {
      _customBaseUrl = '';
      _mode = prodMode;
      await prefs.setString(_modeKey, prodMode);
      await prefs.setString(_customUrlKey, '');
    }

    if (_mode == devMode) {
      _mode = prodMode;
      await prefs.setString(_modeKey, prodMode);
    }
  }

  static Future<void> setMode(String nextMode) async {
    _mode = nextMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, _mode);
  }

  static Future<void> resetToDefault() async {
    _mode = prodMode;
    _customBaseUrl = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, prodMode);
    await prefs.setString(_customUrlKey, '');
  }

  static Future<void> setCustomBaseUrl(String rawUrl) async {
    _customBaseUrl = normalizeBaseUrl(rawUrl);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customUrlKey, _customBaseUrl);
  }

  static String normalizeBaseUrl(String rawUrl) {
    var trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    // Always enforce secure HTTPS
    if (trimmed.startsWith('http://')) {
      trimmed = 'https://${trimmed.substring(7)}';
    } else if (!trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    if (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}
