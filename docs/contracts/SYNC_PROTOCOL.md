# Protocolo Formal de Sincronización entre Repositorios — Ecosistema Zanate / PEMTREE

**Versión:** `1.0.0`  
**Fecha:** 2026-11-27  
**Manifiesto legible por máquina:** [`docs/contracts/shared-ecosystem-contract.json`](./shared-ecosystem-contract.json)

Este documento es el contrato vinculante para programadores y agentes de inteligencia artificial que trabajen en **Zanate** (`Comunidad_USAC`) o en **Zanate Admin** (`PEMTREE-admin`). Ambos repositorios operan sobre la **misma base de datos remota de Supabase (`hfvsstkfqszpjrsrwhql`)**, por lo que todo cambio de esquema, RLS, RPC, Edge Function, Worker, variable de entorno o CSP impacta a todo el ecosistema.

---

## 1. Mapa del Ecosistema y Nomenclatura Canónica

| Producto | Carpeta local | Repositorio GitHub | Stack principal | Rama de integración | Ramas protegidas |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Zanate** (App & Backend principal) | `Comunidad_USAC` | `Trebol4Devop/Zanate` | Flutter, Supabase, Cloudflare Workers | `develop` | `main`, `beta/release` |
| **Zanate Admin** (Panel administrativo) | `PEMTREE-admin` | `Trebol4Devop/PEMTREE-admin` | React 19, Vite, Tailwind, Supabase | `develop` | `main` |

> **Aclaración clave de carpetas:** el proyecto y producto **Zanate** (`Trebol4Devop/Zanate`) vive en la carpeta local **`Comunidad_USAC`**. El panel administrativo **Zanate Admin** (`Trebol4Devop/PEMTREE-admin`) vive en la carpeta hermana **`PEMTREE-admin`**.

### Proyecto Supabase Único Compartido
- **Proyecto oficial:** `PEMTREE`
- **Project Ref obligatorio:** `hfvsstkfqszpjrsrwhql`
- **Project Ref deprecado y PROHIBIDO:** `jsdshvnkbrkwobfhdysh` (no debe aparecer en código fuente, configuración, scripts ni migraciones nuevas).

---

## 2. Matriz de Propiedad (Ownership Matrix)

| Activo / Directorio | Dueño primario | Regla de sincronización |
| :--- | :--- | :--- |
| `supabase/migrations/` | **Compartido 1:1** (`Comunidad_USAC` como fuente canónica) | Toda migración creada o modificada en un repositorio **debe replicarse de inmediato al otro** con `./scripts/sync-supabase-migrations.sh` y versionarse en ambos con el mismo nombre y contenido. |
| `supabase/functions/moderation-worker/` | `Comunidad_USAC` | Solo se edita en `Comunidad_USAC`. Si cambia veredictos o `moderation_status`, actualizar el panel. |
| `supabase/functions/send-push/` | `Comunidad_USAC` | Solo se edita en `Comunidad_USAC`. |
| `supabase/functions/r2-signer/` | `PEMTREE-admin` | Solo se edita en `PEMTREE-admin`. Mantener sincronizada `ALLOWED_FILENAMES` con el manifiesto y los assets de mapa en Flutter. |
| `workers/verification/`, `workers/billing/`, `worker/` | `Comunidad_USAC` | Pertenecen a `Comunidad_USAC`. Si cambian endpoints admin (p. ej. billing Recurrente o verificación) o dominios, actualizar `PEMTREE-admin` (`VITE_*`, `src/lib/*`, `index.html` CSP). |
| `comunidad_universitaria/` (Flutter) | `Comunidad_USAC` | Consume Supabase vía `anon` / `authenticated` con RLS y RPCs públicas/usuario. |
| `src/` (Panel React) | `PEMTREE-admin` | Consume Supabase como staff autenticado vía RPCs `SECURITY DEFINER` y vistas administrativas. |
| Archivos espejo de contrato (`mirrored_contract_files`) | **Compartido 1:1** | `docs/contracts/SYNC_PROTOCOL.md`, `docs/contracts/shared-ecosystem-contract.json`, `scripts/sync-supabase-migrations.sh` y `scripts/ci/check_ecosystem_sync.py` deben mantenerse idénticos en ambos repos. |

---

## 3. Contratos Inmutables de Base de Datos y Seguridad

1. **Solo lectura remota sin autorización explícita:** está **prohibido** aplicar migraciones, modificar RLS, triggers, funciones o datos en la base remota (`hfvsstkfqszpjrsrwhql`) sin autorización explícita del usuario. Cuando sea aprobado, usar `supabase db push --dry-run` antes de aplicar; está **terminantemente prohibido** ejecutar `supabase db reset --linked`.
2. **Semántica canónica de `moderation_status`:**
   - `0`: Pendiente de revisión automática (visible públicamente según RLS `IS DISTINCT FROM 2`).
   - `1`: Aprobado (visible).
   - `2`: Oculto / Rechazado (**oculto** para el público).
   - `3`: En cola de revisión humana.
   - Ningún listado público debe filtrar `moderation_status = 0`; usar `moderation_status IS DISTINCT FROM 2` (`.neq('moderation_status', 2)`).
3. **Contrato `profiles` y Zero-PII:**
   - **Prohibido almacenar o consultar PII directa:** nunca referenciar ni recrear `profiles.full_name`, `profiles.cui`, `profiles.cui_hash`, `verification_requests.extracted_ocr_text`, `merchant_verification_requests.dpi_hash`, `dpi_front_key` ni `dpi_back_key`.
   - **`profiles.alias` SÍ existe:** fue incorporado en `20261123164346_media_video_unique_alias_and_cooldown.sql` como alias único no-PII. Todo módulo que muestre autoría de perfil debe usar `alias` y jamás `full_name`.
   - **Columnas protegidas de perfil:** `is_verified`, `verification_status`, `seller_verification_status`, `carne_hash` solo pueden mutarse en servidor vía RPC o trigger.
4. **Frontera de acceso (App vs. Admin):**
   - La app (`Comunidad_USAC`) opera con RLS estricta y RPCs de usuario/públicas.
   - El panel (`PEMTREE-admin`) valida rol de staff (`is_pemtree_admin`, `is_pemtree_moderator`, `is_marketplace_staff`, **nunca UUIDs hardcodeados**) y ejecuta acciones administrativas exclusivamente mediante RPCs `SECURITY DEFINER` auditadas (`admin_list_grouped_entity_reports`, `admin_resolve_entity_reports`, `admin_toggle_legal_hold`, `ocultar_contenido_moderado`, `restaurar_contenido_moderado`, `eliminar_contenido_moderado`, `test_profanity_filter`, `admin_issue_forum_strike`, `admin_list_marketplace_subscriptions`, `admin_get_marketplace_subscription`, `admin_list_recurrente_webhook_events`, etc.).
   - Prohibido incluir fallbacks en cliente que oculten errores `42703` / `42501` / `PGRST204` o intenten mutar tablas base sin permiso.
5. **Estándar obligatorio para nuevas migraciones SQL:**
   - Nombre estricto: `YYYYMMDDHHMMSS_descripcion_snake_case.sql` con timestamp UTC único (sin prefijos duplicados).
   - SQL **idempotente** (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, bloques `DO $$ ... END $$;` para constraints).
   - Toda tabla nueva debe ejecutar `ENABLE ROW LEVEL SECURITY`, revocar permisos base y conceder `GRANT` mínimos.
   - Políticas RLS separadas por rol (`TO anon` y `TO authenticated`), usando `(select auth.uid())` para evitar reevaluación por fila y prevenir `initplan` lentos.
   - Funciones `SECURITY DEFINER` con `SET search_path TO ''`, esquemas calificados (`public.`, `private.`) y `REVOKE ALL ... FROM PUBLIC, anon` cuando corresponda.
   - Respetar estrictamente `is_legal_hold = true` en triggers, purgas y eliminaciones.
   - Verificar índices existentes antes de crear nuevos para evitar duplicados.

---

## 4. Evolución Compatible (Expand-and-Contract)

Porque la app Flutter y el panel React no siempre se despliegan en el mismo segundo, ningún cambio de esquema puede romper al cliente hermano en producción:

1. **Fase 1 — Expandir:** añadir nuevas columnas (anulables o con valor por defecto), nuevas tablas, nuevas vistas o nuevos RPCs conservando temporalmente la interfaz anterior.
2. **Fase 2 — Migrar ambos clientes:** actualizar `Comunidad_USAC` y `PEMTREE-admin`, validando contratos (`check_sql_contracts.py` y `check_ecosystem_sync.py`) y pruebas en los dos repositorios.
3. **Fase 3 — Contraer:** solo cuando ambos clientes ya dependan exclusivamente de los objetos nuevos y hayan sido desplegados, crear una migración posterior que retire los objetos obsoletos y sincronizarla en ambos repos.

---

## 5. Variables de Entorno, Secretos y CSP

1. **Variables públicas del panel (`PEMTREE-admin/.env`, NO versionado):**
   - Solo variables `VITE_*`: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_COMMUNITY_AUTH_URL`, `VITE_MODERATION_API_URL`, `VITE_BILLING_WORKER_URL`, `VITE_MAP_R2_PUBLIC_URL`.
   - Mantener finales de línea **LF** y sin `/` final en URLs públicas de R2 (`VITE_MAP_R2_PUBLIC_URL`).
   - Toda nueva variable pública debe agregarse en `PEMTREE-admin/.env.example` y en `required_env_vars` de [`shared-ecosystem-contract.json`](./shared-ecosystem-contract.json).
2. **Secretos privados de Edge Functions (`PEMTREE-admin/supabase/.env`, NO versionado):**
   - `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_R2_ACCESS_KEY_ID`, `CLOUDFLARE_R2_SECRET_ACCESS_KEY`, `CLOUDFLARE_R2_BUCKET_NAME`.
   - Nunca mover secretos `CLOUDFLARE_*` ni `service_role` a `.env` raíz de Vite, al código cliente ni a `Comunidad_USAC`.
3. **Política de Seguridad de Contenido (`PEMTREE-admin/index.html` CSP `connect-src`):**
   - Debe autorizar `https://*.supabase.co`, `wss://*.supabase.co`, `https://*.workers.dev`, `https://*.r2.cloudflarestorage.com`, `https://*.pages.dev` y `https://*.netlify.app`.
   - Si en `Comunidad_USAC` se agrega o cambia el dominio de un Cloudflare Worker o servicio consumido por el panel, se debe actualizar `index.html` y `required_csp_connect_src` en el manifiesto.
4. **Whitelist de assets de mapa (`r2-signer`):**
   - `ALLOWED_FILENAMES` en `PEMTREE-admin/supabase/functions/r2-signer/index.ts` incluye: `usac_buildings.geojson`, `usac_pois_and_indoors.json`, `campus_places_info.json`, `campus_graph.json`, `usac_boundary.geojson`, `map_version.json`.
   - Cualquier archivo nuevo requiere actualizar `r2-signer`, `src/lib/r2StorageService.js`, el cliente mapa de Flutter y `r2_signer_allowed_filenames` en el manifiesto.

---

## 6. Matriz de Acción Cruzada

| Si cambiaste esto en un repositorio... | Debes hacer esto inmediatamente en el otro repositorio y en este |
| :--- | :--- |
| Nueva migración SQL o ajuste de esquema/RLS/RPC | Ejecutar `./scripts/sync-supabase-migrations.sh --push-to-app` o `--pull-from-app`, verificar `--check`, correr `check_sql_contracts.py` y `check_ecosystem_sync.py` en **ambos** repos y commitear el `.sql` en ambos. |
| Renombre o retiro de columna/tabla/vista/RPC usado por clientes | Aplicar **Expand-and-Contract** (Sección 4); actualizar queries en `Comunidad_USAC/comunidad_universitaria/lib/` y `PEMTREE-admin/src/lib/`, más `critical_shared_rpcs` si aplica. |
| Nuevo Cloudflare Worker o cambio de URL/endpoint consumido por el panel | Actualizar `PEMTREE-admin/.env.example`, `.env` local, clientes en `src/lib/`, `index.html` CSP `connect-src` y `shared-ecosystem-contract.json`. |
| Cambio en lista de archivos de mapa R2 | Sincronizar `PEMTREE-admin/supabase/functions/r2-signer/index.ts`, `src/lib/r2StorageService.js`, servicio mapa en Flutter y `r2_signer_allowed_filenames` en `shared-ecosystem-contract.json`. |
| Nueva regla Zero-PII o cambio de estados `moderation_status` | Actualizar Edge Function `moderation-worker`, migración + pgTAP, validadores Flutter y lógica de moderación en `PEMTREE-admin/src/`. |
| Actualización a este protocolo o al manifiesto JSON | Replicar exactamente los 4 archivos de `mirrored_contract_files` en **ambos** repositorios y confirmar con `check_ecosystem_sync.py --require-sibling`. |

---

## 7. Flujo Git Obligatorio

1. Partir siempre de `develop` actualizado creando una rama temática (`feat/...`, `fix/...`, `chore/...`, `docs/...`).
2. Realizar commits atómicos descriptivos.
3. Si agregas o modificas scripts ejecutables (`.sh`, `.py`), asegúrate de conservar el bit ejecutable en Git usando `git add --chmod=+x <ruta>` (verifica que `git ls-files -s` muestre `100755`).
4. Antes de fusionar a `develop`, ejecutar todas las verificaciones de la Sección 8 y confirmar salida `0`.
5. Integrar mediante `git merge --no-ff <rama>` hacia `develop` únicamente, nunca sobre `main` ni `beta/release` sin proceso de release aprobado.
6. Prohibido commitear `.env`, `.env.local`, `supabase/.env` o `supabase/.temp/`.

---

## 8. Comandos de Verificación Obligatorios

### En `PEMTREE-admin` (Zanate Admin)
```bash
pnpm run check:contracts
python3 scripts/ci/check_ecosystem_sync.py --require-sibling
./scripts/sync-supabase-migrations.sh --check
pnpm build
```

### En `Comunidad_USAC` (Zanate)
```bash
python3 scripts/ci/check_sql_contracts.py
python3 scripts/ci/check_ecosystem_sync.py --require-sibling
./scripts/sync-supabase-migrations.sh --check
```
*(Cuando el cambio afecte código Flutter, Workers o migraciones SQL, ejecutar además `flutter analyze`, `flutter test`, `npm test` en el worker modificado y `supabase test db --local`.)*
