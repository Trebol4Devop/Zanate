import 'package:flutter/foundation.dart';
import '../../core/config/supabase_config.dart';
import '../../core/services/supabase_service.dart';

/// Datos esenciales de la sesión activa para el intercambio SSO con clientes autorizados.
class SsoSessionData {
  final String accessToken;
  final String refreshToken;
  final int? expiresIn;

  const SsoSessionData({
    required this.accessToken,
    required this.refreshToken,
    this.expiresIn,
  });
}

/// Contrato desacoplado e inyectable para el servicio de Single Sign-On (SSO).
///
/// Permite abstraer la obtención de credenciales de sesión en widgets y pantallas,
/// facilitando pruebas unitarias sin acoplamiento a clientes concretos de backend.
abstract class SsoService {
  /// Retorna los tokens de la sesión activa actual o null si no hay sesión.
  Future<SsoSessionData?> getCurrentSession();

  /// Indica si el servicio de backend subyacente está configurado.
  bool get isConfigured;

  /// Indica si hay un usuario autenticado activo.
  bool get isAuthenticated;

  /// Retorna el correo electrónico del usuario activo si existe.
  String? get currentUserEmail;
}

/// Implementación estándar de [SsoService] respaldada por Supabase en Zanate.
class SupabaseSsoService implements SsoService {
  const SupabaseSsoService();

  @override
  bool get isConfigured => SupabaseConfig.isConfigured;

  @override
  bool get isAuthenticated =>
      isConfigured ? SupabaseService.isAuthenticated : true;

  @override
  String? get currentUserEmail => SupabaseService.currentUser?.email;

  @override
  Future<SsoSessionData?> getCurrentSession() async {
    if (!isConfigured) return null;
    try {
      final session = SupabaseConfig.client.auth.currentSession;
      if (session == null) return null;
      return SsoSessionData(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken ?? '',
        expiresIn: session.expiresIn,
      );
    } catch (e) {
      debugPrint('[SsoService] Error obteniendo sesión activa: ${e.runtimeType}');
      return null;
    }
  }
}
