/// Utilidades de sanitización de entradas de usuario antes de enviar consultas.
class InputSanitizer {
  InputSanitizer._();

  static final RegExp _postgrestControlChars = RegExp(r'''[,()*\\'";%_]''');
  static final RegExp _multiWhitespace = RegExp(r'\s+');

  /// Sanitiza una cadena de búsqueda antes de interpolarla en un filtro `.or()`
  /// de PostgREST, eliminando caracteres de control de filtros e inyección.
  static String sanitizePostgrestSearch(String raw, {int maxLength = 100}) {
    final cleaned = raw
        .replaceAll(_postgrestControlChars, ' ')
        .replaceAll(_multiWhitespace, ' ')
        .trim();
    if (cleaned.length <= maxLength) return cleaned;
    return cleaned.substring(0, maxLength).trim();
  }
}
