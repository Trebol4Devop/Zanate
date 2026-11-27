---
name: zanate-repo-sync
description: >-
  Use this skill before creating or modifying Supabase migrations, RLS policies,
  RPCs, views, Cloudflare Workers, Edge Functions, CSP headers, environment
  variables, or shared contracts across Zanate (Comunidad_USAC) and Zanate Admin
  (PEMTREE-admin) to keep both repositories and the shared remote database aligned.
---

# Zanate Ecosystem Cross-Repo Sync Runbook

Este runbook guía paso a paso cualquier cambio que afecte el backend compartido entre **Zanate** (`Comunidad_USAC`, `Trebol4Devop/Zanate`) y **Zanate Admin** (`PEMTREE-admin`, `Trebol4Devop/PEMTREE-admin`) sobre el proyecto Supabase `PEMTREE` (`hfvsstkfqszpjrsrwhql`).

Referencias normativas:
- `docs/contracts/SYNC_PROTOCOL.md`
- `docs/contracts/shared-ecosystem-contract.json`
- `AGENTS.md`

## Procedimiento Paso a Paso

### 1. Preflight en ambos repositorios
1. Verifica que ambos repositorios estén limpios y en `develop` antes de empezar:
   ```bash
   git -C ../Comunidad_USAC status --short
   git -C ../PEMTREE-admin status --short
   ```
2. Crea una rama temática desde `develop` en el repo donde vas a trabajar (y en el hermano si el cambio toca ambos):
   ```bash
   git checkout -b fix/<alcance> develop
   ```
3. Confirma la paridad inicial de migraciones:
   ```bash
   ./scripts/sync-supabase-migrations.sh --check
   ```

### 2. Diseño SQL y Evolución Compatible
1. Crea la migración con `supabase migration new <descripcion_snake_case>` o con prefijo UTC único `YYYYMMDDHHMMSS_descripcion_snake_case.sql`.
2. Asegura cumplimiento del contrato en `SYNC_PROTOCOL.md`:
   - Idempotencia (`IF NOT EXISTS`, `CREATE OR REPLACE`, bloques `DO $$`).
   - RLS habilitada, políticas separadas `TO anon` y `TO authenticated`, `(select auth.uid())`.
   - `SECURITY DEFINER` con `SET search_path TO ''`, esquemas calificados y revocación de `PUBLIC`/`anon` si aplica.
   - Prohibido `profiles.full_name` o PII directa; usar `profiles.alias`.
   - Respetar `is_legal_hold = true` y códigos `moderation_status` (`0`, `1`, `2`, `3`).
   - Si modificas columnas/RPCs en uso por alguno de los clientes, aplica **Expand-and-Contract**.
3. **Nunca** apliques migraciones remotas sin autorización explícita del usuario. Si obtienes autorización:
   ```bash
   supabase db push --dry-run
   ```

### 3. Sincronización 1:1 hacia el Repositorio Hermano
1. Copia la migración hacia el otro repo desde `Comunidad_USAC` o `PEMTREE-admin`:
   - Si creaste la migración en `Comunidad_USAC`: ejecuta `./scripts/sync-supabase-migrations.sh --pull-from-app`.
   - Si la creaste en `PEMTREE-admin`: ejecuta `./scripts/sync-supabase-migrations.sh --push-to-app`.
2. Verifica que el resultado sea `Solo en admin: 0 | Solo en app: 0 | Diferentes: 0`:
   ```bash
   ./scripts/sync-supabase-migrations.sh --check
   ```
3. Si actualizaste archivos de `mirrored_contract_files`, copia los mismos cambios al hermano para mantenerlos byte-idénticos.

### 4. Actualización de Clientes, Workers, CSP y Manifiesto
- **App/Workers (`Comunidad_USAC`):** actualiza `comunidad_universitaria/lib/*`, `workers/*`, `supabase/functions/*` y pruebas `supabase/tests/*`.
- **Panel (`PEMTREE-admin`):** actualiza `src/lib/*`, `index.html` (si cambió algún dominio Worker/R2 en `connect-src`), `.env.example` (si hay nueva variable pública `VITE_*`) y `supabase/functions/r2-signer/index.ts` (`ALLOWED_FILENAMES`).
- **Manifiesto (`docs/contracts/shared-ecosystem-contract.json`):** si agregaste un RPC crítico compartido, variable requerida, origen CSP o archivo de mapa R2, actualiza el JSON en **ambos** repositorios.

### 5. Verificación Obligatoria Antes de Merge

En **Comunidad_USAC**:
```bash
python3 scripts/ci/check_sql_contracts.py
python3 scripts/ci/check_ecosystem_sync.py --require-sibling
./scripts/sync-supabase-migrations.sh --check
```

En **PEMTREE-admin**:
```bash
pnpm run check:contracts
python3 scripts/ci/check_ecosystem_sync.py --require-sibling
./scripts/sync-supabase-migrations.sh --check
pnpm build
```

### 6. Commit y Merge Limpio
1. Si tocaste scripts `.sh` o `.py`, conserva el permiso ejecutable:
   ```bash
   git add --chmod=+x <ruta_script>
   git ls-files -s <ruta_script>   # debe mostrar 100755
   ```
2. Realiza commits atómicos, integra con `git merge --no-ff <rama>` hacia `develop` únicamente en ambos repositorios y verifica `git status --short` limpio antes de hacer push a `origin/develop`.
