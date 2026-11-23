import 'package:shared_preferences/shared_preferences.dart';

/// Controla el tiempo mínimo de espera entre publicaciones consecutivas
/// del mismo usuario para evitar sobrecarga o envío en masa.
class PublishCooldownService {
  PublishCooldownService._();

  static const Duration defaultCooldown = Duration(seconds: 30);
  static const String _prefPrefix = 'publish_cooldown_';
  static final Map<String, DateTime> _memoryLastPublish = {};

  /// Retorna el tiempo restante de espera para [scope], o `null` si puede publicar.
  static Future<Duration?> remainingCooldown(
    String scope, {
    Duration cooldown = defaultCooldown,
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now().toUtc();
    DateTime? last = _memoryLastPublish[scope];

    if (last == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final millis = prefs.getInt('$_prefPrefix$scope');
        if (millis != null) {
          last = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
          _memoryLastPublish[scope] = last;
        }
      } catch (_) {}
    }

    if (last == null) return null;

    final elapsed = current.difference(last);
    if (elapsed.isNegative) return null;
    if (elapsed >= cooldown) return null;
    return cooldown - elapsed;
  }

  /// Registra el instante de una publicación exitosa para [scope].
  static Future<void> recordPublish(String scope, {DateTime? now}) async {
    final current = (now ?? DateTime.now()).toUtc();
    _memoryLastPublish[scope] = current;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_prefPrefix$scope', current.millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Limpia marcas almacenadas (solo para pruebas).
  static Future<void> clearForTest() async {
    _memoryLastPublish.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(_prefPrefix)) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  /// Mensaje amigable en español indicando los segundos restantes.
  static String formatCooldownMessage(Duration remaining) {
    final secs = remaining.inSeconds < 1 ? 1 : remaining.inSeconds;
    return 'Espera $secs segundos antes de publicar nuevamente.';
  }
}
