import 'package:flutter/foundation.dart';
import '../../../core/config/supabase_config.dart';
import '../../../core/services/supabase_service.dart';

/// Consulta el historial de solicitudes de comerciante en Zanate.
///
/// El alta de comerciantes ahora se realiza exclusivamente vía soporte
/// (`mailto:trebol4devop@proton.me`). Esta clase queda deprecada y solo se
/// conserva para consultar el motivo de rechazo de solicitudes históricas
/// desde [VerificationController].
@Deprecated(
  'El alta de comerciantes ahora se realiza vía soporte (mailto:trebol4devop@proton.me). '
  'Conservado únicamente para lectura de motivo de rechazo de solicitudes históricas en VerificationController.',
)
class MerchantVerificationService {
  const MerchantVerificationService();

  /// Consulta la solicitud más reciente de comerciante para el usuario autenticado.
  /// Se utiliza para mostrar el motivo de rechazo histórico en el Marketplace.
  @Deprecated(
    'Uso restringido a lectura de motivo de rechazo histórico en VerificationController. '
    'El nuevo flujo de comerciantes opera vía soporte.',
  )
  Future<Map<String, dynamic>?> fetchLatestMerchantRequest() async {
    if (!SupabaseConfig.isConfigured) return null;
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;

    try {
      final res = await SupabaseService.client
          .from('merchant_verification_requests')
          .select('status, rejection_reason, created_at')
          .eq('user_id', uid)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (res == null) return null;
      return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint(
        '[MerchantVerificationService] Error consultando solicitud reciente',
      );
      return null;
    }
  }
}
