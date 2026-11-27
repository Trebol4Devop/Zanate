import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/billing_config.dart';
import '../config/supabase_config.dart';
import '../models/marketplace_subscription.dart';
import 'supabase_service.dart';

class BillingException implements Exception {
  final String message;
  final int? statusCode;

  const BillingException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class BillingService {
  final http.Client _httpClient;
  final SupabaseClient? _supabaseClientOverride;
  final String _workerUrl;
  final String? Function()? accessTokenProvider;

  BillingService({
    http.Client? httpClient,
    SupabaseClient? supabaseClient,
    String? workerUrl,
    this.accessTokenProvider,
  }) : _httpClient = httpClient ?? http.Client(),
       _supabaseClientOverride = supabaseClient,
       _workerUrl = (workerUrl ?? BillingConfig.workerUrl).trim();

  String get _normalizedBaseUrl {
    if (_workerUrl.isEmpty) {
      throw const BillingException(
        'El servicio de facturación no está configurado (BILLING_WORKER_URL).',
      );
    }
    return _workerUrl.endsWith('/')
        ? _workerUrl.substring(0, _workerUrl.length - 1)
        : _workerUrl;
  }

  SupabaseClient get _client =>
      _supabaseClientOverride ?? SupabaseService.client;

  String _requireAccessToken() {
    final token =
        accessTokenProvider?.call() ??
        _client.auth.currentSession?.accessToken;
    if (token == null || token.trim().isEmpty) {
      throw const BillingException(
        'Debes iniciar sesión para gestionar tu suscripción.',
        statusCode: 401,
      );
    }
    return token;
  }

  Future<Map<String, dynamic>> _sendWorkerRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final token = _requireAccessToken();
    final uri = Uri.parse('$_normalizedBaseUrl$path');
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    late final http.Response response;
    switch (method) {
      case 'POST':
        response = await _httpClient.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'PUT':
        response = await _httpClient.put(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'DELETE':
        response = await _httpClient.delete(uri, headers: headers);
      default:
        throw BillingException('Método HTTP no soportado: $method');
    }

    final decoded = response.body.trim().isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(response.body) as Map);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BillingException(
        decoded['message']?.toString() ??
            'No se pudo procesar la solicitud de facturación.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }

  Future<String> createCheckoutSession(String planId) async {
    final data = await _sendWorkerRequest(
      'POST',
      '/api/v1/billing/checkout',
      body: {'plan_id': planId},
    );
    final url = data['checkout_url']?.toString() ?? '';
    if (url.isEmpty) {
      throw const BillingException(
        'El servidor no devolvió una URL de checkout válida.',
      );
    }
    return url;
  }

  Future<String> createCardSetupSession() async {
    final data = await _sendWorkerRequest(
      'POST',
      '/api/v1/billing/setup-card',
    );
    final url = data['checkout_url']?.toString() ?? '';
    if (url.isEmpty) {
      throw const BillingException(
        'El servidor no devolvió una URL para actualizar tu tarjeta.',
      );
    }
    return url;
  }

  Future<void> changePlan(
    String newPlanId, {
    String mode = 'next_cycle',
  }) async {
    await _sendWorkerRequest(
      'PUT',
      '/api/v1/billing/subscription',
      body: {'plan_id': newPlanId, 'mode': mode},
    );
  }

  Future<void> cancelSubscription() async {
    await _sendWorkerRequest('DELETE', '/api/v1/billing/subscription');
  }

  Future<MarketplaceSubscription?> fetchMySubscription() async {
    if (_supabaseClientOverride == null && !SupabaseConfig.isConfigured) {
      return null;
    }

    final response = await _client.rpc('get_my_subscription');
    if (response == null) return null;
    if (response is List) {
      if (response.isEmpty) return null;
      return MarketplaceSubscription.fromMap(
        Map<String, dynamic>.from(response.first as Map),
      );
    }
    if (response is Map) {
      return MarketplaceSubscription.fromMap(
        Map<String, dynamic>.from(response),
      );
    }
    return null;
  }
}
