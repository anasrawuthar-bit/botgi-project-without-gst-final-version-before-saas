import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'token_store.dart';

class AuthService {
  AuthService(this._tokenStore);

  final TokenStore _tokenStore;
  String? _accessToken;
  Map<String, dynamic>? _currentUser;

  Map<String, dynamic>? get currentUser => _currentUser;
  String? get accessToken => _accessToken;

  Future<bool> restoreSession() async {
    final token = await _tokenStore.readToken();
    if (token == null || token.isEmpty) {
      return false;
    }

    _accessToken = token;
    try {
      await fetchMe();
      return true;
    } catch (_) {
      await logout();
      return false;
    }
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/api/mobile/login/');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );

    final body = _safeJsonDecode(response.body);
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Login failed.');
    }

    final token = (body['access_token'] ?? '').toString();
    if (token.isEmpty) {
      throw Exception('Access token missing from login response.');
    }

    _accessToken = token;
    _currentUser = body['user'] is Map<String, dynamic>
        ? (body['user'] as Map<String, dynamic>)
        : null;
    await _tokenStore.saveToken(token);
  }

  Future<void> loginWithQrToken({
    required String token,
    String? deviceName,
  }) async {
    String tokenToSubmit = token.trim();
    String? detectedServerUrl;

    if (tokenToSubmit.startsWith('{') && tokenToSubmit.endsWith('}')) {
      try {
        final parsed = jsonDecode(tokenToSubmit);
        if (parsed is Map) {
          if (parsed['token'] != null) {
            tokenToSubmit = parsed['token'].toString().trim();
          }
          if (parsed['server_url'] != null) {
            final raw = parsed['server_url'].toString().trim();
            if (raw.isNotEmpty) {
              detectedServerUrl = AppConfig.normalizeBaseUrl(raw);
            }
          }
        }
      } catch (_) {}
    }

    if (detectedServerUrl != null && detectedServerUrl.isNotEmpty) {
      await AppConfig.setMode(AppConfig.customMode);
      await AppConfig.setCustomBaseUrl(detectedServerUrl);
    }

    // Ensure baseUrl is not an unreachable local LAN address
    if (AppConfig.baseUrl.contains('192.168.') ||
        AppConfig.baseUrl.contains('10.0.2.2') ||
        AppConfig.baseUrl.contains('127.0.0.1') ||
        AppConfig.baseUrl.contains(':3000')) {
      await AppConfig.resetToDefault();
    }

    final uri = Uri.parse('${AppConfig.baseUrl}/api/mobile/qr-login/');
    final payload = <String, dynamic>{
      'token': tokenToSubmit,
      'device_name': deviceName ?? 'Android Technician Device',
    };

    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw Exception('Connection timed out connecting to ${AppConfig.baseUrl}. Please check internet connection.');
    } catch (e) {
      throw Exception('Could not connect to ${AppConfig.baseUrl}. (${e.toString().replaceFirst('Exception: ', '')})');
    }

    final body = _safeJsonDecode(response.body);
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'QR Login failed.');
    }

    final accessToken = (body['access_token'] ?? '').toString();
    if (accessToken.isEmpty) {
      throw Exception('Access token missing from QR login response.');
    }

    _accessToken = accessToken;
    _currentUser = body['user'] is Map<String, dynamic>
        ? (body['user'] as Map<String, dynamic>)
        : null;
    await _tokenStore.saveToken(accessToken);
  }

  Future<Map<String, dynamic>> fetchMe() async {
    final response = await http.get(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/me/'),
      headers: _authHeaders(),
    );
    final body = _safeJsonDecode(response.body);

    if (response.statusCode == 401) {
      await logout();
      throw Exception(
        body['message'] ?? 'Session expired. Please login again.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to fetch profile.');
    }

    final user = body['user'];
    if (user is! Map<String, dynamic>) {
      throw Exception('Invalid user response from server.');
    }
    _currentUser = user;
    return user;
  }

  Future<void> logout() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      try {
        final uri = Uri.parse('${AppConfig.baseUrl}/api/mobile/logout/');
        await http
            .post(uri, headers: _authHeaders())
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        // Proceed with local logout even if network request fails or times out
      }
    }
    _accessToken = null;
    _currentUser = null;
    await _tokenStore.clearToken();
  }

  Map<String, String> authHeaders() => _authHeaders();

  Map<String, String> _authHeaders() {
    if (_accessToken == null || _accessToken!.isEmpty) {
      return {'Content-Type': 'application/json'};
    }
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_accessToken',
    };
  }

  Map<String, dynamic> _safeJsonDecode(String rawBody) {
    if (rawBody.isEmpty) {
      return {};
    }
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Ignore decode errors and return fallback object.
    }
    return {};
  }
}
