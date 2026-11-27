# CLAUDE.md — Zanate (`Comunidad_USAC`)

Instrucciones obligatorias para Claude Code al trabajar en **Zanate** (`Trebol4Devop/Zanate`, carpeta local `Comunidad_USAC`).

## Lectura obligatoria antes de editar código o infraestructura
Antes de modificar SQL, `comunidad_universitaria/`, Workers (`workers/*`) o Edge Functions (`supabase/functions/*`), lee:
1. [`AGENTS.md`](./AGENTS.md)
2. [`docs/contracts/SYNC_PROTOCOL.md`](./docs/contracts/SYNC_PROTOCOL.md)
3. [`docs/contracts/shared-ecosystem-contract.json`](./docs/contracts/shared-ecosystem-contract.json)
4. [`docs/contratos_y_lineamientos.md`](./docs/contratos_y_lineamientos.md) y [`definition/GEMINI.md`](./definition/GEMINI.md)
5. [`.agents/skills/zanate-repo-sync/SKILL.md`](./.agents/skills/zanate-repo-sync/SKILL.md)

## Puntos críticos del repositorio
- **Repo hermano:** `../PEMTREE-admin` (**Zanate Admin** / `Trebol4Devop/PEMTREE-admin`), con el que comparte la base de datos remota Supabase `hfvsstkfqszpjrsrwhql` (`jsdshvnkbrkwobfhdysh` está prohibido).
- **Migraciones espejo:** cualquier cambio en `supabase/migrations/` debe sincronizarse 1:1 hacia `../PEMTREE-admin/supabase/migrations/` y validarse con `check_ecosystem_sync.py`.
- **Prohibido tocar base remota sin permiso explícito del usuario** y prohibido `supabase db reset --linked`.
- **Zero-PII:** `profiles.alias` existe y es válido; `profiles.full_name`, `cui`, `dpi_hash` y texto OCR están prohibidos.
- **Ramas:** trabaja en ramas creadas desde `develop`, valida abajo y haz `merge --no-ff` únicamente hacia `develop` (no toques `main`, `beta/release` ni stashes existentes sin autorización).

## Verificación obligatoria
```bash
python3 scripts/ci/check_sql_contracts.py
python3 scripts/ci/check_ecosystem_sync.py --require-sibling
./scripts/sync-supabase-migrations.sh --check
```
*(Más `flutter analyze`, `flutter test`, `npm test` en `workers/*` y `supabase test db --local` según archivos modificados.)*
