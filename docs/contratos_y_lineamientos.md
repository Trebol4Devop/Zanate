# Contratos Técnicos y Lineamientos de Implementación — Zanate

**Versión:** 1.0  
**Fecha:** 21 de noviembre de 2026  
**Alcance:** App Flutter (`comunidad_universitaria/`), Backend Supabase (`supabase/`), Cloudflare Worker de verificación (`workers/verification/`) y Edge Function de moderación (`supabase/functions/moderation-worker/`).

Este documento establece los contratos vinculantes y reglas de implementación para todo el equipo de desarrollo de **Zanate**. Su objetivo es eliminar el _drift_ entre cliente, base de datos, workers y el panel administrativo (`Zanate-admin`), previniendo discrepancias funcionales, fallos silenciosos por permisos RLS/GRANT o filtraciones de datos personales.

> **Regla fundamental:** Cualquier divergencia entre el código implementado y los contratos definidos aquí (o en `docs/verification/zero-pii.md`) se considera un **bug bloqueante** y debe corregirse antes de integrar a `develop` o `main`.

---

## 1. Arquitectura y Fuente de Verdad

El ecosistema comparte un único proyecto oficial de Supabase (`hfvsstkfqszpjrsrwhql`) con `Zanate-admin` (el identificador histórico `jsdshvnkbrkwobfhdysh` está formalmente deprecado y prohibido). Por ello, todo cambio de datos impacta dos clientes simultáneamente.

| Componente                   | Ruta en el repositorio                  | Responsabilidad principal                                                                         |
| :--------------------------- | :-------------------------------------- | :------------------------------------------------------------------------------------------------ |
| **App Flutter (Zanate)**     | `comunidad_universitaria/`              | Cliente multiplataforma (Web, Android, iOS, Desktop). Consume Supabase con clave `anon` bajo RLS. |
| **Migraciones SQL activas**  | `supabase/migrations/`                  | **Única fuente de verdad** para evolucionar el esquema, triggers, vistas, RLS y RPCs.             |
| **Pruebas de BD (pgTAP)**    | `supabase/tests/`                       | Validación automatizada de RLS, triggers, contadores, RPCs y reglas Zero-PII.                     |
| **Edge Function Moderación** | `supabase/functions/moderation-worker/` | Procesamiento asíncrono de `moderation_jobs` (Capa 1 regex + análisis semántico).                 |
| **Worker de Verificación**   | `workers/verification/`                 | Endpoints administrativos (`/api/v1/admin/*`) y limpieza programada en Cloudflare R2.             |
| **Worker de Imágenes R2**    | Externo (`R2_WORKER_URL`)               | Carga y entrega de imágenes. No existe réplica local aislada; operar con cautela.                 |

### Artefactos que NO son fuente de verdad ejecutable

- `remote_public_snapshot.sql`: solo referencia histórica; **nunca** debe ejecutarse ni usarse como respaldo o migración.
- `supabase/migrations_historical/`: archivo histórico fuera de la secuencia activa de la CLI; **no editar**.
- `docs/ux/`: contiene especificaciones aspiracionales; validar siempre contra el esquema activo y los servicios reales antes de implementar.

---

## 2. Contratos de Base de Datos (Supabase / PostgreSQL)

### 2.1 Semántica canónica de `moderation_status`

Todos los módulos con contenido generado por usuarios (`posts`, `comments`, `marketplace_items`, `student_groups`) deben respetar exactamente los mismos códigos de estado en BD, Edge Function, App Flutter y `Zanate-admin`:

| Código | Estado                           | Visibilidad pública                               | Responsable de la transición                                             |
| :----- | :------------------------------- | :------------------------------------------------ | :----------------------------------------------------------------------- |
| `0`    | Pendiente de revisión automática | Visible según RLS (`IS DISTINCT FROM 2`)          | Valor inicial forzado por trigger al insertar                            |
| `1`    | Aprobado                         | Visible                                           | `moderation-worker` (`SAFE_CAMPUS_HUMOR`) o moderador vía RPC            |
| `2`    | Oculto / Rechazado               | **Oculto** para público                           | `moderation-worker` (riesgo con confianza `>= 0.80`) o moderador vía RPC |
| `3`    | En cola de revisión humana       | Visible hasta resolución (según política vigente) | `moderation-worker` (riesgo con `0.50 <= confianza < 0.80`)              |

**Regla obligatoria de lectura en cliente:**

- Para feeds y listados públicos, consultar las **tablas canónicas** (`posts`, `comments`, `marketplace_items`, `student_groups`) usando una **lista explícita de columnas** permitidas por `GRANT SELECT` y el filtro `.neq('moderation_status', 2)`.
- **Prohibido** usar `safe_posts_feed`, `safe_comments`, `safe_marketplace_items` o `safe_student_groups` en feeds públicos mientras dichas vistas mantengan `WHERE moderation_status = 0` (eso oculta contenido aprobado con `status = 1`). Su uso queda restringido únicamente a consultas de tipo "mis elementos" donde la vista incluye `OR is_mine(...)`, y solo hasta que se consoliden las migraciones de vistas.

### 2.2 Permisos `GRANT`, Triggers e Inmutabilidad

La base de datos aplica seguridad a nivel de columna y triggers defensivos (`enforce_system_defaults_on_insert`, `enforce_content_immutability_and_legal_hold`, `guard_*`). El cliente **nunca** debe intentar burlar ni asumir permisos que no existen:

1. **Escritura en `public.profiles` desde `authenticated`:** solo se permite `UPDATE` sobre `carrera`, `accepted_terms_version` y `accepted_terms_at`. Cualquier intento de actualizar `is_verified`, `verification_status`, `seller_verification_status`, `carne_hash` o campos inexistentes fallará con `42501` o `42703`.
2. **Campos controlados por el sistema (prohibido enviarlos o mutarlos directo desde el cliente):** `moderation_status`, `is_sponsored`, `upvotes`, `reported_count`, `shares_count`, `is_legal_hold`, `moderated_at`, `moderated_by`, `seller_verification_status`.
3. **Preferencias de notificaciones:** las carreras seleccionadas se persisten en la tabla normalizada `notification_preference_carreras`, **nunca** como una clave `carreras` dentro de `notification_preferences`.
4. **Columnas inexistentes o retiradas (prohibido referenciarlas en código nuevo):** `profiles.full_name`, `profiles.alias`, `profiles.cui`, `profiles.cui_hash`, `verification_requests.extracted_ocr_text`, `merchant_verification_requests.dpi_hash`, `dpi_front_key`, `dpi_back_key`. (Nota: la columna `profiles.seller_verification_status` **sí existe** en el esquema activo desde `20261113120000_marketplace_ux_backend.sql`, configurada como columna protegida de solo lectura para `authenticated`; ver ADR-005).
5. **Contenido bajo retención legal (`is_legal_hold = true`):** no puede editarse ni eliminarse; el cliente debe capturar y traducir el error mediante `LegalHoldException`.
6. **Contadores locales vs. persistidos:** `shares_count` no tiene `GRANT UPDATE` para `authenticated`; el conteo de compartidos se gestiona localmente vía `ShareCountService` hasta que exista un RPC específico.

### 2.3 Catálogo de RPCs Autorizados

Toda operación privilegiada, agregada o que involucre reglas de negocio sensibles debe ejecutarse mediante su RPC oficial y **nunca** tener fallbacks de `UPDATE` directo a la tabla base.

| Dominio                   | RPC                                                                                                                                                                                          | Rol autorizado                  | Propósito / Contrato                                                                                                                             |
| :------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Verificación**          | `claim_student_credentials(p_carne text)`                                                                                                                                                    | `authenticated`, `service_role` | Valida carné (9 dígitos, año 1980–actual), calcula `carne_hash` y actualiza el perfil del invocador.                                             |
| **Marketplace (Lectura)** | `get_marketplace_feed(...)`, `get_marketplace_item_detail(p_item_id)`, `get_related_marketplace_items(...)`, `get_seller_public_profile(...)`, `get_seller_catalog(...)`                     | `anon`, `authenticated`         | Lectura paginada y segura del catálogo y perfiles públicos de tienda.                                                                            |
| **Marketplace (Usuario)** | `get_my_marketplace_status()`, `get_my_marketplace_items(...)`, `get_my_bookmarked_items(...)`, `toggle_marketplace_bookmark(p_item_id)`, `track_marketplace_event(p_item_id, p_event_type)` | `authenticated`                 | Gestión de estado de vendedor, favoritos y métricas (`view`, `click_whatsapp`, `click_telegram`, `click_instagram`, `click_messenger`, `share`). |
| **Reportes**              | `report_forum_post(...)`, `report_forum_comment(...)`, `report_marketplace_item(...)`                                                                                                        | `authenticated`                 | Registro de denuncias y cuarentena automática según motivo de riesgo.                                                                            |
| **Reseñas**               | `upvote_seccion_review(p_review_id)`                                                                                                                                                         | `authenticated`                 | Voto idempotente en reseñas de secciones.                                                                                                        |
| **Moderación / Admin**    | `admin_*` (Marketplace, verificación, planes, auditoría) y `claim_moderation_jobs(...)`                                                                                                      | `service_role` / Staff validado | Acciones de panel y workers. Requieren rol validado (`is_pemtree_admin` / `is_pemtree_moderator` / `is_marketplace_staff`) y escriben auditoría. |

### 2.4 Flujo Obligatorio de Migraciones SQL

1. Crear siempre una nueva migración desde la raíz: `supabase migration new descripcion_clara`.
2. Escribir SQL **idempotente** (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, bloques `DO $$ ... END $$;` para constraints) evitando duplicar índices existentes como `profiles_carne_hash_unique`.
3. Toda tabla nueva debe activar `ENABLE ROW LEVEL SECURITY`, revocar permisos por defecto (`REVOKE ALL ... FROM PUBLIC, anon, authenticated`) y conceder explícitamente solo los `GRANT` necesarios.
4. Agregar o actualizar pruebas pgTAP en `supabase/tests/` cubriendo permisos por rol (`anon`, `authenticated`, staff) y triggers.
5. Validar en local con `supabase test db --local`.
6. **Prohibido** ejecutar `supabase db reset --linked`. Para remoto, el único proyecto oficial es `hfvsstkfqszpjrsrwhql` (`jsdshvnkbrkwobfhdysh` está formalmente deprecado y prohibido). Confirmar el `project-ref`, ejecutar `supabase db push --dry-run` y obtener aprobación explícita del equipo.
7. **Retiro definitivo de MFA/AAL2:** el requisito de MFA / TOTP / AAL2 fue retirado definitivamente de la arquitectura (ADR-003). La migración `20261121000100_drop_aal2_requirements.sql` revoca toda restricción AAL2 en las políticas RLS; las operaciones de usuarios autenticados operan con normalidad en AAL1.

---

## 3. Contrato de Privacidad y Arquitectura Zero-PII

Regido por `docs/verification/zero-pii.md`, la migración `20261117120000_zero_pii_hardening.sql` y el ADR-002:

1. **Cero PII directa en base de datos:** prohibido almacenar nombres reales (`full_name`), CUI/DPI, fotografías de documentos de identidad civil o texto crudo de OCR.
2. **Hashing unidireccional en servidor:** `carne_hash` y `contact_phone_hash` se calculan únicamente en PostgreSQL con `private.hash_credential` (HMAC-SHA256 con sal en `private.app_secrets`). El cliente nunca almacena ni deriva secretos de hashing.
3. **Unicidad de credenciales:**
   - Un carné (`carne_hash`) solo puede pertenecer a un perfil activo (`profiles_carne_hash_unique`).
   - Un teléfono de comerciante (`contact_phone_hash`) es único mientras la solicitud esté `pending` o `approved` (`idx_merchant_unique_active_phone_hash`), permitiendo reintentos si fue `rejected`.
4. **Zero-PII en cliente y servidor (Riesgo residual formalmente aceptado):**
   - **En base de datos:** se mantiene una estricta política Zero-PII sin `full_name`, CUI/DPI ni texto OCR, con hashes derivados exclusivamente en servidor.
   - **En cliente:** de acuerdo con el ADR-002, el riesgo residual de no cumplir 100% Zero-PII en el almacenamiento del cliente (`LocalStorageService` sobre `SharedPreferences`) está **formalmente aceptado**. No se modifica `LocalStorageService` ni se introduce `flutter_secure_storage`.
   - **Higiene de logs:** se prohíbe imprimir en `debugPrint`, `print` o reportes de error URLs de redirección, excepciones que contengan `access_token`, `refresh_token`, claves o PII.
5. **OCR on-device como apoyo opcional:** `OcrService` y `CarnetPhotoValidator` se conservan en la aplicación móvil como herramientas de apoyo opcional en el dispositivo para facilitar la lectura del carné del estudiante. No se suben imágenes a R2 ni se persiste texto OCR en Supabase (ADR-004).
6. **Anonimato en comunidad:** las publicaciones y comentarios exponen únicamente `author_alias` (validado contra el catálogo de alias anónimos) y `author_hash`; nunca `user_id` directo en feeds públicos.

---

## 4. Contratos de Autenticación, Sesión y Verificación

### 4.1 Ciclo de Vida de Sesión

El estado de arranque se centraliza en `SessionController` (`SessionPhase`: `loading`, `authenticated`, `guest`, `unauthenticated`):

- **Ruta `/auth/authorize` (SSO):** se resuelve antes del gate de bienvenida. Debe validar parámetros de seguridad (`sso_security_validator.dart`) y nunca loguear tokens.
- **Sesión real (Google OAuth con PKCE):** único método de cuenta real en la app. Entra directo a `AppShell`.
- **Modo invitado (`usac_guest_mode = true`):** acceso estrictamente de **solo lectura** en toda la app (reforzado en BD por RLS para `anon`). Al cerrar sesión se elimina `usac_guest_mode` y se retorna a `WelcomeScreen`.
- **Autenticación contextual (`AuthModal.show`):** abre el flujo de Google OAuth y ejecuta `onAuthenticated` al completar; no ofrece modo anónimo.

### 4.2 Niveles de Acceso y Verificación

| Perfil / Estado                                                        | Foro, Grupos, Mapa y Reseñas | Lectura Marketplace | Publicar en Marketplace      |
| :--------------------------------------------------------------------- | :--------------------------- | :------------------ | :--------------------------- |
| Invitado (`anon`)                                                      | Solo lectura                 | Sí                  | No                           |
| Autenticado no verificado (`unverified`, `pending_review`, `rejected`) | Lectura y escritura          | Sí                  | No (o sujeto a gate vigente) |
| Estudiante verificado (`verification_status = 'verified'`)             | Lectura y escritura          | Sí                  | Sí                           |
| Comerciante aprobado (`seller_profiles` aprobado)                      | Lectura y escritura          | Sí                  | Sí                           |

- **Invariante obligatoria:** `verification_status = 'verified' <=> is_verified = true`.
- **Verificación estudiantil automática:** disponible para correos `usac.edu.gt`, `*.usac.edu.gt` y dominios registrados en `facultades.allowed_domains`, completando carné vía `claim_student_credentials(p_carne)`.
- **Alta sin correo institucional y comerciantes (flujo vigente):** se atiende mediante **Contactar con soporte** (`mailto:trebol4devop@proton.me`). La app no sube fotografías de documentos ni crea filas en `merchant_verification_requests` directamente.
- **Retiro definitivo de TOTP / AAL2:** la funcionalidad MFA/TOTP y los requisitos AAL2 fueron retirados definitivamente de la arquitectura (ADR-003). No existen pantallas de inscripción TOTP en la app ni exigencias de factores secundarios en las políticas de BD.

---

## 5. Contratos de Workers y Edge Functions

### 5.1 Cloudflare Worker de Verificación (`workers/verification/`)

- **Endpoints versionados bajo `/api/v1/`:**
  - `GET /api/v1/health` → `{ "status": "ok", "service": "comunidad-usac-verification" }`
  - `POST /api/v1/admin/review-verification`
  - `POST /api/v1/admin/review-merchant`
  - `GET /api/v1/admin/merchant-document`
- **Formato estándar de error JSON:**
  ```json
  {
    "status": "error",
    "code": "codigo_snake_case",
    "message": "Descripción segura sin filtrar detalles internos"
  }
  ```
- **Seguridad y CORS:** validar `ALLOWED_ORIGINS` (nunca devolver `*` si hay orígenes configurados con credenciales), autenticar llamadas administrativas contra Supabase con verificación de rol staff, y ejecutar purga de objetos expirados en R2 (`cleanup.ts` + `admin_clear_merchant_keys`).

### 5.2 Edge Function `moderation-worker` (`supabase/functions/moderation-worker/`)

- **Política _fail-closed_:** si falta `WORKER_SECRET` o la cabecera/bearer no coincide exactamente, rechazar la solicitud sin procesar trabajos.
- **Precedencia de capas:** la Capa 1 (regex determinista para teléfonos GT `[2-7]\d{3}[-\s]?\d{4}`, CUI de 13 dígitos y carnés con contexto) **siempre prevalece** sobre el análisis semántico para evitar fugas de PII/doxxing.
- **Mapeo obligatorio de veredictos:**
  - `SAFE_CAMPUS_HUMOR` → `moderation_status = 1`
  - Riesgo con `0.50 <= confidence < 0.80` → `moderation_status = 3` (revisión humana)
  - Riesgo con `confidence >= 0.80` → `moderation_status = 2` (oculto)

---

## 6. Lineamientos de Implementación en Flutter (`comunidad_universitaria/`)

### 6.1 Estructura de Directorios y Fronteras

| Capa                      | Ruta                     | Regla de dependencia                                                                                    |
| :------------------------ | :----------------------- | :------------------------------------------------------------------------------------------------------ |
| **Configuración**         | `lib/core/config/`       | Temas, `SupabaseConfig`, `GoogleAuthConfig`, `SupportConfig`. Sin lógica de UI.                         |
| **Constantes**            | `lib/core/constants/`    | Catálogos (`categories.dart`), colores (`zanate_colors.dart`), alias y avatares.                        |
| **Modelos de dominio**    | `lib/core/models/`       | Clases inmutables con `fromMap`/`toMap` estrictamente alineadas a columnas reales de BD.                |
| **Servicios compartidos** | `lib/core/services/`     | Comunicación con Supabase, caché (`CacheService`) y almacenamiento local. Sin `BuildContext`.           |
| **Utilidades**            | `lib/core/utils/`        | Funciones puras (`responsive.dart`, `time_utils.dart`, `url_utils.dart`, `business_hours_helper.dart`). |
| **Features**              | `lib/features/<modulo>/` | Separación interna en `models/`, `screens/`, `services/`, `state/`, `utils/`, `widgets/`.               |

**Regla de acoplamiento:** los widgets y pantallas no invocan `Supabase.instance.client` directamente; toda lectura/escritura debe pasar por un servicio o controlador del módulo o de `lib/core/services/`.

### 6.2 Configuración de Entornos y Secretos

- **Desarrollo local obligatorio con `--dart-define`:** nunca asumir que ejecutar `flutter run` sin parámetros apunta a Supabase local (los valores por defecto en `supabase_config.dart` apuntan a remoto). Usar siempre:
  ```bash
  flutter run -d chrome \
    --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
    --dart-define=SUPABASE_ANON_KEY=<ANON_KEY_LOCAL>
  ```
- **Prohibido** incluir claves `service_role`, tokens de Cloudflare o secretos de workers en `lib/`, `.env` versionados o documentación.

### 6.3 Contratos de Servicios, Consultas y Manejo de Errores

1. **Proyecciones explícitas:** definir constantes privadas de columnas (`_postFallbackColumns`, `_commentFallbackColumns`, `_marketColumns`, `_planColumns`) en lugar de `select('*')` cuando la tabla tenga columnas restringidas o sensibles.
2. **Paginación obligatoria:** toda consulta de listado (`posts`, `comments`, `marketplace_items`, `student_groups`, perfil) debe declarar `limit` y `offset`/cursor. Prohibido introducir escaneos completos sin límite.
3. **Excepciones tipadas:** usar excepciones de dominio (`MarketplaceException(message, code: ...)`, `LegalHoldException`) para que la UI muestre mensajes claros sin exponer errores crudos de PostgREST.
4. **No silenciar errores de contrato:** un `catch` genérico no debe ocultar códigos `42703` (columna inexistente), `42501` (permiso denegado) o `PGRST204`/`PGRST202` convirtiéndolos en `false` o listas vacías sin registro controlado. Durante pruebas y desarrollo, estos errores deben ser visibles para detectar _drift_ inmediatamente.
5. **Validación dual:** las reglas de contenido prohibido (ej. `_prohibitedKeywords` en `MarketplaceService`) y validaciones de formato (carné, teléfono, longitudes) se validan en cliente para UX inmediata y se hacen cumplir en servidor mediante triggers/RPCs.
6. **Caché por namespace:** toda lectura cacheada en `CacheService` debe usar un namespace dedicado (`forum_posts`, `marketplace_items`, etc.) e invalidarse al crear, editar o eliminar elementos.
7. **Catálogo único de canales del foro:** `public.categorias_foro` es la **única fuente de verdad** de los canales. El cliente Flutter no mantiene listas de canales hardcodeadas en runtime: `ForumService.fetchForumChannels()` lee `id, nombre, descripcion, slug, icon, sort_order, is_active, is_system` y respeta el orden del backend (las constantes locales son solo respaldo offline). Los administradores gestionan el catálogo con `admin_upsert_forum_category(jsonb)` y `admin_delete_forum_category(text)`; el canal `todos` es de sistema (editable, no eliminable ni desactivable) y el resto —incluidos `general`, `prerrequisitos`, `catedraticos`, `apuntes`, `horarios`, `desahogo` y `desmadre`— admite crear, editar y eliminar. La vista `v_forum_category_admin` expone los conteos y la política de moderación para el panel. **Visibilidad:** `is_active = false` es un borrado lógico; el panel PEMTREE-admin conserva el canal (con la etiqueta «Inactivo», oculto por defecto tras el interruptor «Mostrar inactivos») y la app no lo muestra. Ambos clientes ordenan por `sort_order, id`.

### 6.4 Estado, UI y Testabilidad

- **Inyección de dependencias:** modelar dependencias externas con interfaces abstractas (patrón `AuthApi` + `SupabaseAuthApi` en `SessionController`) y anotar overrides de prueba con `@visibleForTesting`.
- **Pruebas sin red:** las pruebas unitarias y de widgets deben usar `FakePostgrest` (`test/helpers/fake_postgrest.dart`), fixtures (`test/helpers/fixtures.dart`) y `mocktail`, sin depender de Supabase remoto.
- **Pruebas E2E seguras:** toda prueba de escritura en `integration_test/` debe verificar que `SUPABASE_URL` apunte a `127.0.0.1` / `localhost` y omitirse si detecta un host remoto.
- **Tema y diseño responsivo:** usar exclusivamente tokens de `zanate_colors.dart`, `app_theme.dart` y `marketplace_theme.dart` (sin colores hardcodeados que rompan modo oscuro) y utilidades de `responsive.dart`. Toda pantalla nueva debe pasar pruebas de renderizado en modo oscuro (`dark_mode_smoke_test.dart`).

---

## 7. Flujo de Trabajo del Equipo, PRs y CI/CD

### 7.1 Estrategia de Ramas y Despliegue

- **Ramas de trabajo:** `feature/<modulo>-<descripcion>`, `fix/<modulo>-<descripcion>`, `chore/<descripcion>` creadas desde `develop`.
- **Integración:** Pull Request hacia `develop` con revisión de al menos un compañero y pipeline `.github/workflows/flutter-tests.yml` en verde.
- **Producción:** merge de `develop` hacia `main`. Solo `main` dispara `.github/workflows/deploy-cloudflare-pages.yml` (que ejecuta `flutter analyze --no-fatal-infos`, `flutter test --no-pub`, `flutter build web --release` y despliegue a Cloudflare Pages).

### 7.2 Checklist Obligatorio antes de Abrir Pull Request (Definition of Done)

- [ ] **Análisis estático limpio:** `flutter analyze` sin errores ni advertencias nuevas en `comunidad_universitaria/`.
- [ ] **Pruebas Flutter en verde:** `flutter test` ejecutado localmente; toda nueva lógica de negocio, modelo o widget crítico incluye prueba unitaria o de widget.
- [ ] **Coherencia con BD:** todas las tablas, columnas y RPCs usados en Flutter existen en `supabase/migrations/` y coinciden en nombre, tipo y `GRANT`.
- [ ] **Semántica de moderación:** ningún listado público filtra `moderation_status = 0` ni intenta `UPDATE` directo de `moderation_status`.
- [ ] **Cumplimiento Zero-PII:** cero referencias a `full_name`, `cui`/`dpi` o OCR en claro en base de datos; hashes HMAC en servidor; cero tokens o PII en logs (riesgo residual de `LocalStorageService` formalmente aceptado según ADR-002).
- [ ] **Migraciones y pgTAP (si aplica):** migración nueva versionada e idempotente + `supabase test db --local` pasando (especialmente `marketplace_ux_test.sql` y pruebas del módulo modificado).
- [ ] **Worker (si aplica):** pruebas `vitest` pasando en `workers/verification/` y contrato de endpoints/errores respetado.
- [ ] **Impacto en `Zanate-admin`:** si se modificó una tabla, vista, trigger o RPC compartido, quedó documentado en la descripción del PR y coordinado con el equipo del panel.

### 7.3 Protocolo para Cambiar un Contrato Acordado

Cuando un requerimiento nuevo exija modificar una tabla, RPC, endpoint de Worker o flujo de autenticación:

1. **Proponer el cambio antes de codificar** en un PR o issue de contrato (actualizando este documento o el contrato específico en `docs/verification/`).
2. **Versionar primero el backend** (migración SQL + pruebas pgTAP) manteniendo compatibilidad hacia atrás cuando `Zanate-admin` y la app no se desplieguen en el mismo instante.
3. **Actualizar clientes y workers** (`comunidad_universitaria/`, `workers/verification/`, `Zanate-admin`) contra el contrato aprobado.
4. **Registrar decisiones arquitectónicas (ADRs)** en `docs/adr/ADRS_ZANATE.md` para evitar implementaciones parciales o asunciones no acordadas.
