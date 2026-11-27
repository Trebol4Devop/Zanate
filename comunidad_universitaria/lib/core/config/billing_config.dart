/// Configuración del Cloudflare Worker de facturación (Recurrente).
///
/// La URL se puede definir en build con:
/// `--dart-define=BILLING_WORKER_URL=https://billing.ejemplo.workers.dev`
class BillingConfig {
  BillingConfig._();

  static const String workerUrl = String.fromEnvironment(
    'BILLING_WORKER_URL',
    defaultValue: '',
  );

  static bool get isConfigured => workerUrl.trim().isNotEmpty;
}
