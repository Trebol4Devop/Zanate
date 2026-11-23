# Fase 1 (Cont.): Seguridad en Cliente, Cooldown y Alias Único por Cuenta

Documentación técnica de las protecciones de entrada en PostgREST, limitación de frecuencia de publicaciones y el rediseño del sistema de alias libre único por cuenta.

---

## 1. Sanitización de filtros de búsqueda (`InputSanitizer`)

Archivo: [input_sanitizer.dart](../../comunidad_universitaria/lib/core/utils/input_sanitizer.dart)

### 1.1 Problema cubierto
Las consultas `.insert()`, `.update()` y `.eq()` del cliente Supabase son parametrizadas y no son vulnerables a SQL injection clásico. Sin embargo, las búsquedas interpoladas dentro de `.or('title.ilike.%$q%,content.ilike.%$q%')` permiten manipular la gramática de filtros de PostgREST si el usuario introduce comas (`,`), paréntesis (`(`, `)`), comodines (`*`, `%`, `_`) o comillas.

### 1.2 Implementación y puntos de uso
- `InputSanitizer.sanitizePostgrestSearch(String raw, {int maxLength = 100})`:
  1. Reemplaza `[,()*\\'";%_]` por espacios.
  2. Colapsa espacios repetidos (`\s+`) y aplica `.trim()`.
  3. Trunca a `100` caracteres.
- Integrado antes de todo `.or(...)` de búsqueda en:
  - [forum_service.dart](../../comunidad_universitaria/lib/core/services/forum_service.dart) (`fetchPosts` con y sin `showOnlyBookmarks`, omitiendo `.or()` si el resultado limpio queda vacío).
  - [groups_service.dart](../../comunidad_universitaria/lib/core/services/groups_service.dart) (`fetchGroups`).
  - [marketplace_service.dart](../../comunidad_universitaria/lib/core/services/marketplace_service.dart) (`fetchListings`).

---

## 2. Cooldown de 30 segundos entre publicaciones (`PublishCooldownService`)

Archivo: [publish_cooldown_service.dart](../../comunidad_universitaria/lib/core/services/publish_cooldown_service.dart)

### 2.1 Diseño
- **Duración:** `defaultCooldown = Duration(seconds: 30)`.
- **Ámbitos independientes:** `'post'` (Foro), `'group'` (Grupos) y `'listing'` (Marketplace).
- **Doble almacenamiento:** mapa en memoria (`_memoryLastPublish`) sincronizado con `SharedPreferences` bajo claves `publish_cooldown_<scope>` para persistir incluso si se recarga la página o la app.
- **API pública:**
  - `remainingCooldown(String scope, {Duration cooldown = defaultCooldown, DateTime? now})` -> devuelve `Duration?` restante o `null` si puede publicar.
  - `recordPublish(String scope, {DateTime? now})` -> registra el instante tras un `INSERT` exitoso.
  - `formatCooldownMessage(Duration remaining)` -> `'Espera <N> segundos antes de publicar nuevamente.'` (mínimo 1 s).
  - `clearForTest()` -> limpia memoria y claves `publish_cooldown_*` en `SharedPreferences`; invocado automáticamente desde `resetTestState()` en [test_setup.dart](../../comunidad_universitaria/test/helpers/test_setup.dart).

### 2.2 Flujo en UI y servicios
1. **En la UI (`CreatePostDialog`, `CreateGroupDialog`, `CreateListingDialog`):** la verificación ocurre **antes** de subir imágenes o videos al Worker R2, evitando archivos huérfanos cuando el usuario está en espera.
2. **En los servicios (`ForumService.createPost`, `GroupsService.createGroup`, `MarketplaceService.createListing`):** la verificación se repite antes del `INSERT` (lanzando `Exception` o `MarketplaceException(code: 'rate_limited')`) y `recordPublish` solo se ejecuta tras éxito real.
3. **Importante:** esta capa mejora la experiencia de usuario y detiene envíos repetidos desde la app; la aplicación estricta contra llamadas directas a API REST queda respaldada por los triggers `BEFORE INSERT` de la Fase 3 ([04-fase-3-plan-base-de-datos.md](04-fase-3-plan-base-de-datos.md)).

---

## 3. Sistema de Alias Único y Libre por Cuenta

### 3.1 Por qué una publicación anterior mostró un nombre distinto
El análisis del código previo reveló tres causas exactas:
1. `LocalStorageService.getOrGenerateAlias` guardaba el alias únicamente en `SharedPreferences` local; la tabla `public.profiles` en [comunidad.sql](../../definition/comunidad.sql) no almacenaba columna `alias`.
2. Al publicar en el foro, `ForumService.createPost` (y `addComment`) pasaban el alias por `AnonymousAliasGenerator.ensureValidForBackend(authorAlias)`. Si el alias no pertenecía al catálogo cerrado (`Sustantivo + Adjetivo` o `Estudiante <Palabra> #<1-4 dígitos>`), la función **lo descartaba silenciosamente y retornaba `generate()`** (un alias aleatorio distinto).
3. Cada fila de `posts` almacena una copia estática de `author_alias` en el momento de creación (mientras que la autoría técnica se asocia a `user_id` y `author_hash`).

### 3.2 Cambios implementados

| Archivo | Contrato implementado |
| :--- | :--- |
| [anonymous_aliases.dart](../../comunidad_universitaria/lib/core/constants/anonymous_aliases.dart) | Se definen `minAliasLength = 2`, `maxAliasLength = 32`, `normalizeCustomAlias` (limpia `\r\n\t`, colapsa espacios) e `isValidCustomAlias`. `ensureValidForBackend(alias)` ahora conserva cualquier alias libre válido (ej. `Anonymus`, `Usac_Dev-99`) recortado a `32` chars; solo genera uno aleatorio si tiene menos de `2` caracteres. Se preserva `isValid()` sin cambios para no romper el catálogo aleatorio del botón de dado. |
| [profile_service.dart](../../comunidad_universitaria/lib/core/services/profile_service.dart) | Agrega `AliasException(message, code)`, `fetchAccountAlias()` y `saveAccountAlias(rawAlias)`. Flujo de guardado: valida longitud (`2..32`), llama al RPC `claim_unique_alias(p_alias)` en Supabase si hay sesión autenticada (rechazando con `code: 'alias_taken'` o SQLSTATE `23505` si otra cuenta ya lo usa), cae de forma segura a `UPDATE profiles SET alias` o guardado local si el RPC/columna aún no existen (`PGRST202` / `42883` / `42703` previos a Fase 3), y actualiza `LocalStorageService.saveAlias`. También `loadProfile()` y `saveProfile()` sincronizan el alias con la cuenta. |
| [alias_modal.dart](../../comunidad_universitaria/lib/features/profile/widgets/alias_modal.dart) | Reemplaza el campo de solo lectura (`InputDecorator`) por un `TextField` editable con `maxLength: 32`, `hintText: 'Ej. Anonymus'`, error inline (`errorText: _errorText`), botón de dado opcional para sugerencias aleatorias y spinner al guardar vía `ProfileService.saveAccountAlias`. Texto limpio sin paréntesis conforme a `definition/GEMINI.md`. |
| [main.dart](../../comunidad_universitaria/lib/main.dart) | `_ComunidadUSACAppState.initState()` ejecuta `_syncAccountAlias()` en segundo plano para traer `ProfileService.fetchAccountAlias()` al iniciar la sesión y actualizar `_activeAlias`. |

*(Nota sobre publicaciones históricas: los posts creados días atrás antes de este ajuste mantienen en `posts.author_alias` el texto con el que se insertaron en su momento; los nuevos posts ya envían y conservan el alias libre único de la cuenta).*

---

## 4. Verificación ejecutada

Comando ejecutado desde `comunidad_universitaria/`:

```bash
flutter analyze --no-fatal-infos \
  lib/core/constants/anonymous_aliases.dart \
  lib/core/services/profile_service.dart \
  lib/features/profile/widgets/alias_modal.dart \
  lib/main.dart \
  test/widgets/shared/alias_modal_test.dart \
  test/media_and_security_test.dart && \
flutter test \
  test/media_and_security_test.dart \
  test/core/anonymous_aliases_test.dart \
  test/models_and_privacy_test.dart \
  test/widgets/shared/alias_modal_test.dart \
  test/services/forum_service_test.dart \
  test/widgets/profile_screen_test.dart
```

- **`flutter analyze --no-fatal-infos`:** `0` errores, `0` advertencias.
- **`flutter test`:** **49 de 49 pruebas aprobadas**, validando:
  - `InputSanitizer.sanitizePostgrestSearch` elimina `,()*\'";%_`, mantiene palabras válidas y recorta a `100` caracteres.
  - `PublishCooldownService` bloquea inmediatamente tras publicar, calcula el tiempo restante y libera al cumplirse los `30` segundos.
  - `ensureValidForBackend('  Anonymus  ')` retorna `'Anonymus'`.
  - `ProfileService.saveAccountAlias` invoca `claim_unique_alias` y lanza `AliasException(code: 'alias_taken')` ante duplicados.
  - `AliasModal` permite escribir texto libre, valida longitud mínima `>= 2` y mantiene funcional el generador aleatorio del dado.
