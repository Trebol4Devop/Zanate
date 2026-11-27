# Reglas para GitHub Copilot — Zanate (`Comunidad_USAC`)

Este repositorio (`Trebol4Devop/Zanate`, carpeta local `Comunidad_USAC`) comparte la base de datos Supabase `PEMTREE` (`hfvsstkfqszpjrsrwhql`) con el panel hermano **Zanate Admin** (`../PEMTREE-admin`). Cumple siempre [`docs/contracts/SYNC_PROTOCOL.md`](../docs/contracts/SYNC_PROTOCOL.md), [`docs/contratos_y_lineamientos.md`](../docs/contratos_y_lineamientos.md) y [`AGENTS.md`](../AGENTS.md):

1. **No uses ref deprecado:** `jsdshvnkbrkwobfhdysh` está prohibido.
2. **Base remota protegida:** nunca sugieras `supabase db reset --linked` ni apliques migraciones remotas sin autorización explícita (ver `definition/GEMINI.md`).
3. **Migraciones sincronizadas 1:1:** toda nueva migración en `supabase/migrations/` debe seguir `YYYYMMDDHHMMSS_snake_case.sql`, ser idempotente, tener pruebas pgTAP y replicarse en `../PEMTREE-admin/supabase/migrations/` con `./scripts/sync-supabase-migrations.sh`.
4. **Expand-and-Contract:** no rompas queries de Flutter ni de `PEMTREE-admin` en cambios de esquema/RPC.
5. **Zero-PII:** usa `profiles.alias` (`20261123164346`); prohibido `profiles.full_name`, `cui`, `dpi_hash` o texto OCR persistido.
6. **`moderation_status`:** `0` pendiente, `1` aprobado, `2` oculto, `3` revisión humana. En feeds públicos filtra `.neq('moderation_status', 2)`, nunca `= 0`.
7. **Workers y Edge Functions:** si modificas `workers/*` o `supabase/functions/*` consumidos por el panel, documenta y actualiza el impacto en `PEMTREE-admin` (`SYNC_PROTOCOL.md`, `shared-ecosystem-contract.json`, CSP y `.env.example`).
8. **Antes de cerrar cambios:** ejecuta `python3 scripts/ci/check_sql_contracts.py`, `python3 scripts/ci/check_ecosystem_sync.py --require-sibling` y `./scripts/sync-supabase-migrations.sh --check` (además de `flutter analyze` y `flutter test` si tocaste Flutter).
