import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/feedback_model.dart';
import '../models/management_models.dart';
import 'auth_service.dart';

class ManagementService {
  ManagementService(this._authService);

  final AuthService _authService;

  Future<ProductListResponse> fetchProducts({String query = ''}) async {
    final queryPart = query.trim().isEmpty ? '' : '?q=${Uri.encodeQueryComponent(query.trim())}';
    final response = await http.get(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/products/$queryPart'),
      headers: _authService.authHeaders(),
    );

    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to load products.');
    }

    final productsRaw = body['products'];
    final products = productsRaw is List
        ? productsRaw.whereType<Map<String, dynamic>>().map(ProductRecord.fromJson).toList(growable: false)
        : <ProductRecord>[];
    return ProductListResponse(
      canEdit: (body['can_edit'] ?? false) == true,
      products: products,
    );
  }

  Future<String> createProduct({
    required String name,
    required String sku,
    required String category,
    required String brand,
    required String unitPrice,
    required String costPrice,
    required int stockQuantity,
    required String description,
    required bool isActive,
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/products/'),
      headers: _authService.authHeaders(),
      body: jsonEncode({
        'name': name,
        'sku': sku,
        'category': category,
        'brand': brand,
        'unit_price': unitPrice,
        'cost_price': costPrice,
        'stock_quantity': stockQuantity,
        'description': description,
        'is_active': isActive,
      }),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to create product.');
    }
    return (body['message'] ?? 'Product created.').toString();
  }

  Future<String> updateProduct({
    required int productId,
    required String name,
    required String sku,
    required String category,
    required String brand,
    required String unitPrice,
    required String costPrice,
    required int stockQuantity,
    required String description,
    required bool isActive,
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/products/$productId/update/'),
      headers: _authService.authHeaders(),
      body: jsonEncode({
        'name': name,
        'sku': sku,
        'category': category,
        'brand': brand,
        'unit_price': unitPrice,
        'cost_price': costPrice,
        'stock_quantity': stockQuantity,
        'description': description,
        'is_active': isActive,
      }),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to update product.');
    }
    return (body['message'] ?? 'Product updated.').toString();
  }

  Future<ClientListResponse> fetchClients({String query = ''}) async {
    final queryPart = query.trim().isEmpty ? '' : '?q=${Uri.encodeQueryComponent(query.trim())}';
    final response = await http.get(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/clients/$queryPart'),
      headers: _authService.authHeaders(),
    );

    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to load clients.');
    }

    final clientsRaw = body['clients'];
    final clients = clientsRaw is List
        ? clientsRaw.whereType<Map<String, dynamic>>().map(ClientRecord.fromJson).toList(growable: false)
        : <ClientRecord>[];
    return ClientListResponse(
      canEdit: (body['can_edit'] ?? false) == true,
      clients: clients,
    );
  }

  Future<String> createClient({
    required String name,
    required String phone,
    required String email,
    required String companyName,
    required String address,
    required String notes,
    required bool isActive,
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/clients/'),
      headers: _authService.authHeaders(),
      body: jsonEncode({
        'name': name,
        'phone': phone,
        'email': email,
        'company_name': companyName,
        'address': address,
        'notes': notes,
        'is_active': isActive,
      }),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to create client.');
    }
    return (body['message'] ?? 'Client created.').toString();
  }

  Future<String> updateClient({
    required int clientId,
    required String name,
    required String phone,
    required String email,
    required String companyName,
    required String address,
    required String notes,
    required bool isActive,
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/clients/$clientId/update/'),
      headers: _authService.authHeaders(),
      body: jsonEncode({
        'name': name,
        'phone': phone,
        'email': email,
        'company_name': companyName,
        'address': address,
        'notes': notes,
        'is_active': isActive,
      }),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to update client.');
    }
    return (body['message'] ?? 'Client updated.').toString();
  }

  Future<PendingApprovalsResponse> fetchPendingApprovals() async {
    final response = await http.get(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/approvals/pending/'),
      headers: _authService.authHeaders(),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to load approvals.');
    }

    final approvalsRaw = body['approvals'];
    final approvals = approvalsRaw is List
        ? approvalsRaw
              .whereType<Map<String, dynamic>>()
              .map(PendingApprovalItem.fromJson)
              .toList(growable: false)
        : <PendingApprovalItem>[];
    return PendingApprovalsResponse(
      canAct: (body['can_act'] ?? false) == true,
      approvals: approvals,
    );
  }

  Future<String> respondPendingApproval({
    required int assignmentId,
    required String action,
    String note = '',
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/approvals/pending/$assignmentId/action/'),
      headers: _authService.authHeaders(),
      body: jsonEncode({'action': action, 'note': note}),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to submit approval response.');
    }
    return (body['message'] ?? 'Response submitted.').toString();
  }

  Future<ReportsSummary> fetchReportsSummary({String preset = 'this_month'}) async {
    final response = await http.get(
      Uri.parse('${AppConfig.baseUrl}/api/mobile/reports/summary/?preset=${Uri.encodeQueryComponent(preset)}'),
      headers: _authService.authHeaders(),
    );
    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to load reports.');
    }

    return ReportsSummary.fromJson(body);
  }

  Future<TechnicianFeedbackResponse> fetchTechnicianFeedback({
    String rating = 'all',
    String query = '',
  }) async {
    final queryParams = <String, String>{};
    if (rating.isNotEmpty && rating != 'all') {
      queryParams['rating'] = rating;
    }
    if (query.trim().isNotEmpty) {
      queryParams['q'] = query.trim();
    }
    final uri = Uri.parse('${AppConfig.baseUrl}/api/mobile/technician/feedback/')
        .replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

    final response = await http.get(
      uri,
      headers: _authService.authHeaders(),
    );

    final body = _safeJsonDecode(response.body);
    if (response.statusCode == 401) {
      await _authService.logout();
      throw Exception(body['message'] ?? 'Session expired. Please login again.');
    }
    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to load technician feedback.');
    }

    return TechnicianFeedbackResponse.fromJson(body);
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
