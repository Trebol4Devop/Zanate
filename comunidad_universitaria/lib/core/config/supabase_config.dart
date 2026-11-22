import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://hfvsstkfqszpjrsrwhql.supabase.co',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhmdnNzdGtmcXN6cGpyc3J3aHFsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM1NDQzOTgsImV4cCI6MjA5OTEyMDM5OH0.Ne5vvKXWsKSv_hbYMeV9NOpiOgIcsOzYjz8xKshhn60',
  );

  /// Indica si la variable SUPABASE_URL fue provista externamente vía --dart-define.
  static const bool isSupabaseUrlProvided = bool.hasEnvironment('SUPABASE_URL');

  static bool _isInitialized = false;

  @visibleForTesting
  static bool? debugOverrideConfigured;

  static bool get hasCredentials =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      !supabaseUrl.contains('tu-proyecto');

  static bool get isConfigured =>
      debugOverrideConfigured ?? (_isInitialized && hasCredentials);

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> initialize() async {
    if (kDebugMode && !isSupabaseUrlProvided) {
      debugPrint(
        '⚠️ [Zanate][SupabaseConfig] AVISO: SUPABASE_URL no fue provista mediante --dart-define. '
        'Usando URL predeterminada del proyecto oficial ($supabaseUrl). '
        'Para entornos de staging o producción personalizada, defina '
        '--dart-define=SUPABASE_URL=... y --dart-define=SUPABASE_ANON_KEY=...',
      );
    }

    if (!hasCredentials) return;
    try {
      try {
        // If Supabase was already initialized, accessing client won't throw
        final _ = Supabase.instance.client;
        _isInitialized = true;
        return;
      } catch (_) {
        // Supabase.instance not initialized yet, proceed
      }

      await Supabase.initialize(
        url: supabaseUrl,
        // ignore: deprecated_member_use
        anonKey: supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
        debug: false,
      );
      _isInitialized = true;
    } catch (e) {
      debugPrint(
        'Aviso: No se pudo conectar con Supabase ($e). Modo local/demostración activado.',
      );
      _isInitialized = false;
    }
  }
}
