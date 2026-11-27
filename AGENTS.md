# AGENTS.md — Zanate (`Comunidad_USAC`)

Este archivo define las reglas obligatorias para cualquier desarrollador o agente de IA que trabaje en **Zanate** (`Trebol4Devop/Zanate`, carpeta local **`Comunidad_USAC`**).

> **Documentos rectores:** lee [`docs/contracts/SYNC_PROTOCOL.md`](./docs/contracts/SYNC_PROTOCOL.md), [`docs/contracts/shared-ecosystem-contract.json`](./docs/contracts/shared-ecosystem-contract.json), [`docs/contratos_y_lineamientos.md`](./docs/contratos_y_lineamientos.md) y [`definition/GEMINI.md`](./definition/GEMINI.md) antes de modificar base de datos, RPCs, Workers, Edge Functions o UI Flutter. Runbook operativo en [`.agents/skills/zanate-repo-sync/SKILL.md`](./.agents/skills/zanate-repo-sync/SKILL.md).

## 1. Contexto del Ecosistema

- **Este repositorio (`Comunidad_USAC` / `Trebol4Devop/Zanate`):** App multiplataforma Flutter (`comunidad_universitaria/`), Workers de Cloudflare (`workers/verification/`, `workers/billing/`, `worker/`), Edge Functions (`moderation-worker`, `send-push`) y fuente canónica primaria de `supabase/migrations/`.
- **Repositorio hermano (`../PEMTREE-admin` / `Trebol4Devop/PEMTREE-admin`):** Panel web **Zanate Admin** (React 19 + Vite + Supabase).
- **Base de datos compartida única:** Supabase proyecto `PEMTREE` (`project_ref = hfvsstkfqszpjrsrwhql`). El ref histórico `jsdshvnkbrkwobfhdysh` está **prohibido**.

## 2. Reglas Innegociables

1. **Base remota de solo lectura sin autorización explícita:** prohibido alterar esquema, RLS, triggers, funciones o datos en `hfvsstkfqszpjrsrwhql` ni aplicar migraciones remotas sin autorización previa del usuario (ver `definition/GEMINI.md` Sección 5). Nunca ejecutes `supabase db reset --linked`.
2. **Paridad 1:1 de `supabase/migrations/`:** toda migración añadida o modificada aquí debe replicarse de inmediato en `../PEMTREE-admin/supabase/migrations/` con `./scripts/sync-supabase-migrations.sh --pull-from-app` (ejecutado desde `PEMTREE-admin` o `--check` / `--push-to-app` desde aquí) y versionarse en ambos repos.
3. **Evolución compatible (Expand-and-Contract):** todo cambio a tablas, vistas, columnas o RPCs compartidos debe preservar compatibilidad para ambos clientes (`Comunidad_USAC` y `PEMTREE-admin`) antes de retirar elementos anteriores.
4. **Zero-PII y contrato `profiles`:** prohibido referenciar o almacenar `profiles.full_name`, `profiles.cui`, `profiles.cui_hash`, `verification_requests.extracted_ocr_text`, `merchant_verification_requests.dpi_hash`, `dpi_front_key` o `dpi_back_key`. La columna `profiles.alias` **sí existe** desde `20261123164346` (alias único no-PII).
5. **Semántica `moderation_status`:** `0` = pendiente automático, `1` = aprobado, `2` = oculto/rechazado, `3` = revisión humana. En feeds públicos filtrar `moderation_status IS DISTINCT FROM 2` (`.neq('moderation_status', 2)`), nunca `= 0`.
6. **RPCs y permisos estrictos:** nunca hagas fallback de `UPDATE` directo cuando una operación requiera RPC ni silencies errores `42703` / `42501` / `PGRST204`.
7. **Impacto cruzado en `PEMTREE-admin`:** si modificas `workers/*`, `moderation-worker`, `send-push`, `r2-signer` o dominios/endpoints consumidos por el panel, debes actualizar o coordinar los contratos correspondientes (`SYNC_PROTOCOL.md`, `shared-ecosystem-contract.json`, CSP y `.env.example` del panel).
8. **Flujo Git y UI:**
   - Para UI Flutter, cumple estrictamente [`definition/GEMINI.md`](./definition/GEMINI.md) (sin texto redundante entre paréntesis, proporciones de imagen acotadas, estilo Discord limpio).
   - Trabaja siempre desde `develop` en ramas temáticas, haz commits atómicos, usa `git add --chmod=+x` para scripts `.sh`/`.py` y fusiona únicamente hacia `develop` con `git merge --no-ff`. No modifiques `main`, `beta/release` ni los stashes locales sin instrucción explícita.

## 3. Verificaciones Obligatorias antes de Merge o Push

```bash
python3 scripts/ci/check_sql_contracts.py
python3 scripts/ci/check_ecosystem_sync.py --require-sibling
./scripts/sync-supabase-migrations.sh --check
```
*(Si modificas Flutter, Workers o SQL: `flutter analyze`, `flutter test`, `npm test` en el worker correspondiente y `supabase test db --local`.)*
