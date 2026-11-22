# Registro de Decisiones de Arquitectura (ADRs) — Zanate

Este documento compila las Decisiones de Arquitectura de Software (ADR) para el proyecto **Zanate** (anteriormente "Comunidad USAC"). Cada registro captura el contexto técnico, la decisión adoptada y sus consecuencias prácticas para el backend (Supabase / PostgreSQL), clientes (Flutter) y servicios auxiliares (Workers / Edge Functions).

---

## Índice de Decisiones

- [ADR-001: Consolidación de Proyecto Supabase Oficial Único y Depreciación de Entorno Histórico](#adr-001-consolidación-de-proyecto-supabase-oficial-único-y-depreciación-de-entorno-histórico)
- [ADR-002: Modelo de Privacidad Zero-PII y Aceptación Formal de Riesgo Residual en Cliente](#adr-002-modelo-de-privacidad-zero-pii-y-aceptación-formal-de-riesgo-residual-en-cliente)
- [ADR-003: Retiro Definitivo de MFA / TOTP / AAL2 de la Arquitectura](#adr-003-retiro-definitivo-de-mfa--totp--aal2-de-la-arquitectura)
- [ADR-004: Conservación de OCR On-Device como Apoyo Opcional sin Persistencia de Texto](#adr-004-conservación-de-ocr-on-device-como-apoyo-opcional-sin-persistencia-de-texto)
- [ADR-005: Columna `profiles.seller_verification_status` como Columna Protegida de Solo Lectura](#adr-005-columna-profilesseller_verification_status-como-columna-protegida-de-solo-lectura)

---

## ADR-001: Consolidación de Proyecto Supabase Oficial Único y Depreciación de Entorno Histórico

- **Estado:** Aprobado
- **Fecha:** 2026-11-21

### Contexto
Durante las fases iniciales de desarrollo del proyecto "Comunidad USAC", se configuró un proyecto Supabase con identificador `jsdshvnkbrkwobfhdysh`. Posteriormente, se integró el ecosistema con el panel administrativo y catálogo de PEMTREE (`PEMTREE-admin`), que utiliza el proyecto de referencia `hfvsstkfqszpjrsrwhql`. La coexistencia de dos identificadores en la documentación generaba confusión operativa, riesgo de ejecutar `supabase db push` o migraciones contra el entorno equivocado, y desalineación en callbacks OAuth y variables de entorno del cliente Flutter y web.

### Decisión
Se ratifica como **único proyecto oficial y compartido de Supabase** para todo el ecosistema Zanate (App Flutter, Backend, SSO y PEMTREE-admin) el identificador:
- Reference ID: `hfvsstkfqszpjrsrwhql`
- URL de API: `https://hfvsstkfqszpjrsrwhql.supabase.co`
- Callback Auth oficial: `https://hfvsstkfqszpjrsrwhql.supabase.co/auth/v1/callback`

El proyecto histórico `jsdshvnkbrkwobfhdysh` queda **formalmente deprecado**. Queda estrictamente prohibido su uso en comandos de CLI (`supabase db push --project-ref ...`), scripts de CI/CD, despliegues de Edge Functions o configuración de clientes.

### Consecuencias
- **Positivas:**
  - Una sola base de datos y catálogo de usuarios para Zanate y PEMTREE-admin.
  - Eliminación del riesgo de aplicar migraciones dispares entre bases de datos huérfanas.
  - Consistencia en la configuración de Google Cloud OAuth y PKCE para todas las plataformas.
- **Negativas / Riesgos Aceptados:**
  - Toda migración de esquema en `supabase/migrations/` impacta simultáneamente a Zanate y PEMTREE-admin. Se exige validar compatibilidad hacia atrás y pruebas de no regresión antes de aplicar cambios en remoto.
  - Prohibido de forma absoluta ejecutar `supabase db reset --linked`.

---

## ADR-002: Modelo de Privacidad Zero-PII y Aceptación Formal de Riesgo Residual en Cliente

- **Estado:** Aprobado
- **Fecha:** 2026-11-21

### Contexto
El producto maneja datos sensibles de la comunidad universitaria. Con la migración `20261117120000_zero_pii_hardening.sql` y las directrices de `docs/verification/zero-pii.md`, se estableció un estándar estricto para erradicar la persistencia de Información de Identificación Personal (PII): no almacenar nombres reales (`full_name`), documentos de identidad civil (`cui`, `dpi`), ni imágenes o textos de carnés.
En el cliente Flutter (`comunidad_universitaria/`), `LocalStorageService` utiliza `SharedPreferences` para almacenar preferencias locales y banderas de estado de sesión en texto plano dentro del almacenamiento privado de la aplicación. Se evaluó reemplazarlo por `flutter_secure_storage` (utilizando Keystore en Android, Keychain en iOS y Secret Service / libsecret en Linux). Sin embargo, esto introducía fallos de inicialización en plataformas de escritorio (Linux y Windows), dependencias del sistema operativo y problemas de sincronización de sesión.

### Decisión
1. **En Base de Datos y Backend (Cero PII estricto):**
   - No se almacenan nombres reales (`full_name` eliminado de `profiles`).
   - No se almacenan números CUI ni DPI.
   - Las credenciales identificatorias (carné y teléfono de contacto para comercios) se almacenan exclusivamente como hashes unidireccionales generados por el servidor mediante HMAC-SHA256 con sal secreta (`private.hash_credential`): `carne_hash` y `contact_phone_hash`.
   - No se persiste texto extraído por OCR ni imágenes de documentos.
2. **En Cliente Flutter (Riesgo residual formalmente aceptado):**
   - Se **acepta formalmente el riesgo residual** de almacenar configuraciones de usuario y estado local sin cifrar en `LocalStorageService` (`SharedPreferences`).
   - No se modifica `LocalStorageService` ni se introduce `flutter_secure_storage`.
   - Se mantiene como política de higiene de código prohibir el volcado de tokens de sesión (`access_token`, `refresh_token`), credenciales o datos sensibles a consola (`print`, `debugPrint`) o reportes de error.

### Consecuencias
- **Positivas:**
  - Máxima estabilidad multiplataforma (Android, iOS, Web, Windows, macOS, Linux) sin dependencias nativas de keyring o fallos de compilación en Linux/Windows.
  - La base de datos central en Supabase queda completamente blindada contra filtraciones de PII, cumpliendo los principios de privacidad por diseño.
- **Negativas / Riesgos Aceptados:**
  - En dispositivos con acceso root o donde un atacante obtenga acceso físico al sandbox de la aplicación, los datos almacenados en `SharedPreferences` podrían ser extraídos en texto claro. Este riesgo se califica como residual y aceptable considerando el perfil de amenaza y la naturaleza de los datos persistidos en cliente.

---

## ADR-003: Retiro Definitivo de MFA / TOTP / AAL2 de la Arquitectura

- **Estado:** Aprobado
- **Fecha:** 2026-11-21

### Contexto
Durante iteraciones pasadas se exploró imponer autenticación multifactor basada en tiempo (TOTP) elevando el nivel de seguridad a AAL2 (*Authenticator Assurance Level 2*) para operaciones de escritura en la base de datos (según la migración histórica `20261004000000_require_aal2_and_verified_sellers.sql`). Asimismo, se crearon componentes de UI como `TotpEnrollmentScreen` y `TotpSessionGuard`.
En la práctica, la aplicación adoptó de manera oficial el acceso exclusivo mediante Google OAuth con PKCE. En dicho flujo:
1. Google gestiona sus propios factores de autenticación en la cuenta del usuario.
2. Supabase Auth en el proyecto alojado no cuenta con flujo de recuperación ni códigos de respaldo para TOTP en la capa de la app, lo que exponía a los estudiantes a pérdida irrecuperable de acceso si cambiaban de dispositivo.
3. Las políticas RLS que exigían AAL2 entraban en conflicto directo con las sesiones válidas de OAuth (AAL1), bloqueando publicaciones legítimas en foros, grupos y marketplace.

### Decisión
Se retira **definitiva y permanentemente** el soporte y requisito de MFA / TOTP / AAL2 de la arquitectura de Zanate:
1. No es una funcionalidad pendiente, aplazada ni diferida; queda formalmente descartada.
2. La migración `20261121000100_drop_aal2_requirements.sql` revoca todas las políticas y restricciones de base de datos que exigían `aal() = 'aal2'`. Las operaciones para usuarios autenticados operan con normalidad en nivel AAL1.
3. Se remueven del alcance activo las pantallas de enrolamiento TOTP y guards de sesión asociados en Flutter.
4. Las pruebas automatizadas (pgTAP y unitarias) evalúan que las operaciones autenticadas operen de forma fluida sin requerir factores secundarios.

### Consecuencias
- **Positivas:**
  - Eliminación de bloqueos de cuenta y reducción drástica de casos de soporte por desincronización de llaves TOTP.
  - Flujo de autenticación sin fricción: un estudiante ingresa con Google OAuth y puede operar inmediatamente de acuerdo con su nivel de verificación estudiantil.
  - Políticas de seguridad RLS limpias, predecibles y de alto rendimiento.
- **Negativas / Riesgos Aceptados:**
  - La protección de la sesión recae en la seguridad del proveedor de identidad (Google) y la gestión del dispositivo del usuario.

---

## ADR-004: Conservación de OCR On-Device como Apoyo Opcional sin Persistencia de Texto

- **Estado:** Aprobado
- **Fecha:** 2026-11-21

### Contexto
El diseño original de verificación contemplaba que el usuario subiera una foto de su carné físico a Cloudflare R2, y que un Worker o servicio procesara el reconocimiento de texto (OCR) persistiendo `extracted_ocr_text` en la tabla `verification_requests`. Este modelo violaba las directrices Zero-PII al almacenar imágenes y textos de documentos oficiales no anonimizados en la nube.
Se evaluaron dos alternativas: eliminar completamente el reconocimiento óptico de caracteres obligando al usuario a tipear su carné, o conservarlo de manera local.

### Decisión
Se conserva el reconocimiento óptico de caracteres (`OcrService` y `CarnetPhotoValidator` mediante `google_mlkit_text_recognition` y `mobile_scanner`) como **herramienta de apoyo opcional ejecutada exclusivamente en el dispositivo (on-device)**:
1. El procesamiento se ejecuta en memoria en el dispositivo del estudiante con el único fin de prellenar el campo del número de carné en la interfaz.
2. La fotografía del carné **nunca se sube a Cloudflare R2 ni a Supabase Storage**.
3. **No se persiste texto OCR** en la base de datos (`extracted_ocr_text` retirado / prohibido en esquema).
4. La vinculación real y verificación de la credencial se realiza mediante el RPC `claim_student_credentials(p_carne text)`, el cual deriva el HMAC en Postgres y asocia el `carne_hash` al perfil.
5. Para usuarios en plataformas donde ML Kit no esté presente (Web/Desktop) o que prefieran no usar la cámara, se ofrece el ingreso manual directo del carné de 9 dígitos.

### Consecuencias
- **Positivas:**
  - Ergonomía y agilidad en dispositivos móviles: el estudiante apunta con la cámara y el número se autocompleta.
  - Cero exposición de datos personales: la imagen no se transmite por la red ni se guarda en almacenamiento secundario; el texto analizado se destruye tras extraer los dígitos.
- **Negativas / Riesgos Aceptados:**
  - El OCR actúa únicamente como asistencia de digitación de UI; no autentica ni valida la legitimidad física del carné. La validación matemática de formato y la unicidad del hash en base de datos residen en PostgreSQL.

---

## ADR-005: Columna `profiles.seller_verification_status` como Columna Protegida de Solo Lectura

- **Estado:** Aprobado
- **Fecha:** 2026-11-21

### Contexto
Durante revisiones de base de datos se reportó una aparente contradicción sobre la existencia de la columna `seller_verification_status` en la tabla `public.profiles`. En reportes antiguos de auditoría figuraba como columna inexistente frente al esquema original. Sin embargo, para soportar la arquitectura de marketplace y verificación de comerciantes (`docs/verification/merchant-contract.md`), la migración activa `20261113120000_marketplace_ux_backend.sql` introdujo formalmente la columna `profiles.seller_verification_status`.

### Decisión
Se ratifica que la columna `profiles.seller_verification_status` **sí existe en el esquema activo de PostgreSQL**:
1. **Esquema:** Definida en `public.profiles` con tipo `text` y restricción de dominio para estados de verificación comercial (`unverified`, `pending`, `verified`, `rejected`).
2. **Permisos de solo lectura para cliente:** El rol `authenticated` tiene concedido únicamente `GRANT SELECT` sobre dicha columna. Se prohíbe `GRANT UPDATE` a `authenticated`.
3. **Protección contra manipulación:** Triggers defensivos (`guard_seller_verification_fields`) impiden cualquier intento de alteración directa desde PostgREST.
4. **Mutaciones controladas:** Las transiciones de estado solo pueden ocurrir a través de RPCs privilegiados ejecutados por moderadores (`is_pemtree_admin`, `is_marketplace_staff`) o Edge Functions con rol `service_role`.
5. **Uso en cliente:** La App Flutter puede y debe consultar `seller_verification_status` (junto con `is_verified`) para determinar capacidades comerciales y renderizar las vistas adecuadas de Marketplace sin incurrir en errores `42703`.

### Consecuencias
- **Positivas:**
  - Alineación inequívoca entre el código Dart de la app Flutter, los contratos de verificación de comerciantes y el esquema de Supabase.
  - Prevención de vulnerabilidades de escalada de privilegios donde un usuario regular intente auto-aprobarse como vendedor.
- **Negativas / Riesgos Aceptados:**
  - Las consultas del cliente deben manejar adecuadamente el estado de solo lectura y cualquier fallo si una interfaz intentara actualizar el perfil completo con campos protegidos.
