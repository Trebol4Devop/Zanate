# Fase 3: Migración SQL en Base de Datos Supabase (Aplicada en PEMTREE)

Especificación y registro de la migración SQL ejecutada en **PEMTREE (`hfvsstkfqszpjrsrwhql`)** tras aprobación explícita del usuario, conforme a la Sección 5 de [definition/GEMINI.md](../../definition/GEMINI.md).

---

## 1. Archivos generados en Fase 3

| Archivo | Propósito |
| :--- | :--- |
| [20261123164346_media_video_unique_alias_and_cooldown.sql](../../supabase/migrations/20261123164346_media_video_unique_alias_and_cooldown.sql) | Migración SQL idempotente creada con `supabase migration new` (video en `posts`, alias único en `profiles`, RPC `claim_unique_alias` y cooldown de 30 s). |
| [media_alias_cooldown_test.sql](../../supabase/tests/database/media_alias_cooldown_test.sql) | Suite transaccional de `14` aserciones `pgTAP` para validar índices, unicidad insensible a mayúsculas, `video_url` y aislamiento de cooldown por usuario. |

---

## 2. Estado base contrastado contra `definition/comunidad.sql` (PEMTREE `hfvsstkfqszpjrsrwhql`)

El esquema remoto real de **PEMTREE** (`hfvsstkfqszpjrsrwhql`, `16,968` líneas en [comunidad.sql](../../definition/comunidad.sql)) confirma los siguientes puntos:

| Objeto | Estado observado en PEMTREE (`2026-11-23`) | Cambio introducido en la migración |
| :--- | :--- | :--- |
| `public.posts` | Tiene `image_url`, `gif_url`, `comments_count`, `hot_score`, `expires_at`, `deleted_at`, `is_legal_hold`, `forum_server_id`. **No tiene `video_url`**. | Agrega `video_url text`, constraint `posts_video_url_https_check` (`^https://`) y `GRANT` de columna. |
| `public.safe_posts_feed` y `public.v_public_posts` | `safe_posts_feed` lee de `posts` y `v_public_posts` lee de `safe_posts_feed`; ninguna proyecta `video_url`. | Actualiza primero `safe_posts_feed` y luego `v_public_posts` agregando `video_url` al final de ambas vistas (`WITH (security_invoker = true)`). |
| `public.profiles` | Sin columna `alias` ni función `claim_unique_alias`. | Agrega `alias text`, constraint `profiles_alias_length_check` (`2..32`), índice único `idx_profiles_alias_unique` sobre `lower(btrim(alias))` y RPC `public.claim_unique_alias(p_alias text)`. |
| `public.check_author_alias_validity()` | Activa en `posts`, `comments`, `student_groups` y `marketplace_items`; rechazaba nombres fuera del catálogo cerrado. | Se reemplaza para aceptar cualquier alias normalizado de `2..32` caracteres. |
| Cooldown `30 s` en tablas públicas | No existe límite en BD para `posts`, `student_groups`, `marketplace_items`. | Agrega índices `(user_id, created_at DESC)` y trigger `BEFORE INSERT` compartido `public.enforce_publish_cooldown_30s()` en las 3 tablas. |

---

## 3. Detalle técnico de cada bloque SQL

### 3.1 Bloque 1: Video en publicaciones del foro (`public.posts.video_url`)
- `ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS video_url text;`
- Restricción `posts_video_url_https_check`: solo permite `NULL`, cadena vacía o URLs `https://`.
- Permisos mínimos explícitos: `SELECT (video_url)` a `anon, authenticated`; `INSERT/UPDATE (video_url)` a `authenticated`.
- Actualiza `public.v_public_posts` agregando `p.video_url` **al final** de la proyección para no romper posiciones de columnas existentes.

### 3.2 Bloque 2: Alias único libre por cuenta (`public.profiles.alias` + `claim_unique_alias`)
- Índice único parcial `idx_profiles_alias_unique` sobre `lower(btrim(alias))` (`Anonymus` y `anonymus` se consideran el mismo alias).
- Función `public.claim_unique_alias(p_alias text)` (`SECURITY DEFINER`, `SET search_path = ''`):
  - Valida `auth.uid() IS NOT NULL` y rechaza sesiones anónimas (`is_anonymous = 'true'`).
  - Normaliza saltos/espacios múltiples y exige longitud entre `2` y `32` caracteres (`code: 'invalid_alias'`).
  - Hace `INSERT ... ON CONFLICT (id) DO UPDATE` sobre `public.profiles` y captura `unique_violation` (`23505`) devolviendo `{"ok": false, "code": "alias_taken", ...}`, exactamente lo que espera `ProfileService.saveAccountAlias` en [profile_service.dart](../../comunidad_universitaria/lib/core/services/profile_service.dart).
  - `REVOKE ALL ... FROM PUBLIC, anon` y `GRANT EXECUTE ... TO authenticated, service_role`.

### 3.3 Bloque 3: Cooldown de 30 segundos en servidor (`enforce_publish_cooldown_30s`)
- Tres índices parciales `(user_id, created_at DESC) WHERE user_id IS NOT NULL` en `posts`, `student_groups` y `marketplace_items` para consultas rápidas `O(log n)`.
- Trigger `BEFORE INSERT` compartido `public.enforce_publish_cooldown_30s()` (`SECURITY DEFINER`, `SET search_path = ''`):
  - Permite bypass controlado a `service_role` y operaciones internas de servidor (`postgres`, `supabase_admin`) usando JWT claims (`request.jwt.claims` ->> `'role'`), evitando `auth.role()` por buenas prácticas de Supabase.
  - Si el mismo `user_id` creó una fila en la tabla dentro de los últimos `30` segundos, lanza excepción `ERRCODE = '23514'` (`HINT = 'rate_limited'`) con los segundos exactos restantes.

---

## 4. Aplicación y verificación en PEMTREE (`hfvsstkfqszpjrsrwhql`)

- **Nota de historial:** `supabase db push` reportó 89 entradas históricas consolidadas previamente en `supabase_migrations.schema_migrations`, por lo que la migración idempotente se aplicó directamente con `supabase db query --remote=hfvsstkfqszpjrsrwhql --file ...` y se registró la versión `20261123164346` (`media_video_unique_alias_and_cooldown`) en `supabase_migrations.schema_migrations`.
- **Verificación posterior:** comprobación estructural de `posts.video_url`, `profiles.alias`, `idx_profiles_alias_unique`, `claim_unique_alias`, `enforce_publish_cooldown_30s`, `3` triggers `trg_cooldown_30s_*`, vistas `safe_posts_feed` / `v_public_posts`, advisors de seguridad y resincronización de [definition/comunidad.sql](../../definition/comunidad.sql).

### Comandos útiles para pruebas locales con Docker / pgTAP
```bash
# Levantar stack local y correr las pruebas pgTAP (incluye media_alias_cooldown_test.sql)
supabase db reset && supabase test db

# Resincronizar el esquema de referencia en cualquier momento
supabase db dump --remote=hfvsstkfqszpjrsrwhql -f definition/comunidad.sql
```
