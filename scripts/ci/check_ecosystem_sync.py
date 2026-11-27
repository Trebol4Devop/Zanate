#!/usr/bin/env python3
"""
Guardrail de Sincronización del Ecosistema Zanate / PEMTREE-admin.

Valida invariantes compartidos definidos en `docs/contracts/shared-ecosystem-contract.json`:
1. Esquema del manifiesto de contrato.
2. Presencia de contratos, reglas para IAs, skill y scripts exigidos en el repo actual.
3. Nomenclatura, unicidad de timestamps e inventario de `supabase/migrations/*.sql`.
4. Declaración de todos los `critical_shared_rpcs` en `supabase/migrations/`.
5. Propiedad de Edge Functions (`supabase/functions/<nombre>/`).
6. Ausencia total de `project_ref` deprecados (`jsdshvnkbrkwobfhdysh`) en código y config activos.
7. Higiene Git: cero archivos `.env`, `.env.local`, `supabase/.env` o `.temp/` versionados.
8. En `PEMTREE-admin`: validación de CSP `connect-src` en `index.html`, variables en `.env.example` y whitelist de `r2-signer`.
9. Paridad real con el repositorio hermano (cuando existe en disco o con `--require-sibling`):
   - Paridad 1:1 de migraciones vía `scripts/sync-supabase-migrations.sh --check`.
   - Paridad exacta (LF-normalizada) de `mirrored_contract_files`.
"""

import argparse
from html.parser import HTMLParser
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REQUIRED_MANIFEST_KEYS = [
    "schema_version",
    "supabase",
    "repositories",
    "edge_functions_ownership",
    "required_env_vars",
    "required_csp_connect_src",
    "critical_shared_rpcs",
    "mirrored_contract_files",
]

REQUIRED_REPO_FILES = [
    "AGENTS.md",
    "CLAUDE.md",
    ".github/copilot-instructions.md",
    ".agents/skills/zanate-repo-sync/SKILL.md",
    "docs/contracts/SYNC_PROTOCOL.md",
    "docs/contracts/shared-ecosystem-contract.json",
    "scripts/sync-supabase-migrations.sh",
    "scripts/ci/check_sql_contracts.py",
    "scripts/ci/check_ecosystem_sync.py",
    ".github/pull_request_template.md",
]

MIGRATION_NAME_RE = re.compile(r"^\d{14}_[a-z0-9_]+\.sql$")
SKIP_SCAN_DIRS = {
    ".git",
    "node_modules",
    "dist",
    "build",
    ".dart_tool",
    ".wrangler",
    ".temp",
}


def detect_repo_identity(repo_root: Path):
    """Identifica si repo_root corresponde a Comunidad_USAC (app) o PEMTREE-admin (admin)."""
    if (repo_root / "comunidad_universitaria").is_dir():
        return "Comunidad_USAC", "app", "PEMTREE-admin"
    if (repo_root / "package.json").is_file() and (repo_root / "src" / "lib" / "adminApi.js").is_file():
        return "PEMTREE-admin", "admin", "Comunidad_USAC"
    raise RuntimeError(
        f"No se pudo detectar la identidad del repositorio en {repo_root}"
    )


def load_manifest(repo_root: Path, errors: list):
    """Carga y valida el manifiesto JSON del ecosistema."""
    manifest_path = repo_root / "docs" / "contracts" / "shared-ecosystem-contract.json"
    if not manifest_path.is_file():
        errors.append(f"Falta el manifiesto: {manifest_path.relative_to(repo_root)}")
        return None
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        errors.append(f"JSON inválido en {manifest_path.relative_to(repo_root)}: {exc}")
        return None

    for key in REQUIRED_MANIFEST_KEYS:
        if key not in data:
            errors.append(f"Falta la clave obligatoria '{key}' en shared-ecosystem-contract.json")
    return data


def check_required_files(repo_root: Path, errors: list):
    """Comprueba la presencia de contratos, archivos de agentes, scripts y templates."""
    for rel in REQUIRED_REPO_FILES:
        if not (repo_root / rel).is_file():
            errors.append(f"Archivo obligatorio faltante: {rel}")


def check_migrations(repo_root: Path, critical_rpcs: list, errors: list):
    """Valida nombres/unicidad de migraciones SQL y presencia de RPCs críticos compartidos."""
    mig_dir = repo_root / "supabase" / "migrations"
    if not mig_dir.is_dir():
        errors.append("No existe el directorio supabase/migrations/")
        return 0

    sql_files = sorted(mig_dir.glob("*.sql"))
    if not sql_files:
        errors.append("No hay migraciones .sql en supabase/migrations/")
        return 0

    timestamps = {}
    combined_sql = []
    for sf in sql_files:
        if not MIGRATION_NAME_RE.match(sf.name):
            errors.append(
                f"Nombre de migración fuera del estándar YYYYMMDDHHMMSS_snake_case.sql: {sf.name}"
            )
        ts = sf.name[:14]
        timestamps.setdefault(ts, []).append(sf.name)
        combined_sql.append(sf.read_text(encoding="utf-8", errors="ignore"))

    for ts, names in timestamps.items():
        if len(names) > 1:
            errors.append(f"Timestamp de migración duplicado ({ts}): {', '.join(names)}")

    full_sql = re.sub(r"--.*$", "", "\n".join(combined_sql), flags=re.MULTILINE)
    full_sql = re.sub(r"/\*.*?\*/", "", full_sql, flags=re.DOTALL)

    for rpc in critical_rpcs:
        pat = re.compile(
            rf"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?{re.escape(rpc)}\b",
            re.IGNORECASE,
        )
        if not pat.search(full_sql):
            errors.append(
                f"RPC crítico compartido '{rpc}' no está declarado en supabase/migrations/*.sql"
            )
    return len(sql_files)


def check_edge_functions(repo_root: Path, repo_key: str, ownership: dict, errors: list):
    """Verifica que las Edge Functions bajo propiedad de este repo existan en supabase/functions/."""
    expected = ownership.get(repo_key, [])
    for fn in expected:
        fn_dir = repo_root / "supabase" / "functions" / fn
        if not fn_dir.is_dir() or not (fn_dir / "index.ts").is_file():
            errors.append(
                f"Edge Function declarada para {repo_key} ausente o sin index.ts: supabase/functions/{fn}"
            )


def check_deprecated_refs(repo_root: Path, repo_key: str, deprecated_refs: list, errors: list):
    """Garantiza que no existan project_ref deprecados en código ni configuración activa."""
    if not deprecated_refs:
        return
    if repo_key == "PEMTREE-admin":
        scan_targets = [
            repo_root / "src",
            repo_root / "index.html",
            repo_root / "supabase" / "config.toml",
            repo_root / "supabase" / "functions",
        ]
    else:
        scan_targets = [
            repo_root / "comunidad_universitaria" / "lib",
            repo_root / "supabase" / "config.toml",
            repo_root / "supabase" / "functions",
            repo_root / "workers",
        ]

    for target in scan_targets:
        if not target.exists():
            continue
        files = [target] if target.is_file() else []
        if target.is_dir():
            for root, dirs, filenames in os.walk(target):
                dirs[:] = [d for d in dirs if d not in SKIP_SCAN_DIRS]
                for fn in filenames:
                    files.append(Path(root) / fn)
        for fp in files:
            try:
                content = fp.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for ref in deprecated_refs:
                if ref in content:
                    errors.append(
                        f"Referencia deprecada '{ref}' encontrada en {fp.relative_to(repo_root)}"
                    )


def check_git_secret_hygiene(repo_root: Path, errors: list):
    """Verifica que Git no tenga versionados archivos .env secretos ni carpetas .temp/."""
    if not (repo_root / ".git").exists():
        return
    res = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        errors.append(f"No se pudo inspeccionar git ls-files en {repo_root}: {res.stderr.strip()}")
        return

    forbidden_basenames = {".env", ".env.local", ".env.production", ".dev.vars"}
    for line in res.stdout.splitlines():
        if not line:
            continue
        parts = Path(line).parts
        base = os.path.basename(line)
        if base in forbidden_basenames or ".temp" in parts:
            errors.append(f"Archivo sensible o temporal versionado en Git: {line}")


class _CspMetaParser(HTMLParser):
    """Extrae el atributo content de <meta http-equiv="Content-Security-Policy">."""

    def __init__(self):
        super().__init__()
        self.csp_values = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "meta":
            return
        attr_map = {k.lower(): v for k, v in attrs if k}
        if (attr_map.get("http-equiv") or "").lower() == "content-security-policy":
            if attr_map.get("content"):
                self.csp_values.append(attr_map["content"])


def check_admin_specific_contracts(repo_root: Path, manifest: dict, errors: list):
    """Valida CSP en index.html, .env.example y ALLOWED_FILENAMES de r2-signer en PEMTREE-admin."""
    index_path = repo_root / "index.html"
    if not index_path.is_file():
        errors.append("Falta index.html en PEMTREE-admin")
    else:
        html = index_path.read_text(encoding="utf-8", errors="ignore")
        parser = _CspMetaParser()
        parser.feed(html)
        if not parser.csp_values:
            errors.append("No se encontró etiqueta meta Content-Security-Policy en index.html")
        else:
            csp_val = " ; ".join(parser.csp_values)
            directives = {}
            for part in csp_val.split(";"):
                tokens = part.strip().split()
                if tokens:
                    directives[tokens[0].lower()] = tokens[1:]
            connect_src = directives.get("connect-src", [])
            for origin in manifest.get("required_csp_connect_src", {}).get("PEMTREE-admin", []):
                if origin not in connect_src:
                    errors.append(
                        f"Origen requerido ausente en connect-src de CSP en index.html: {origin}"
                    )

    env_example = repo_root / ".env.example"
    if not env_example.is_file():
        errors.append("Falta .env.example en PEMTREE-admin")
    else:
        env_lines = env_example.read_text(encoding="utf-8", errors="ignore")
        declared_vars = set()
        for raw_line in env_lines.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            declared_vars.add(line.split("=", 1)[0].strip())
        for var_name in manifest.get("required_env_vars", {}).get("PEMTREE-admin", {}).get("public_vite", []):
            if var_name not in declared_vars:
                errors.append(
                    f"Variable pública requerida ausente en .env.example: {var_name}"
                )

    r2_signer = repo_root / "supabase" / "functions" / "r2-signer" / "index.ts"
    if not r2_signer.is_file():
        errors.append("Falta supabase/functions/r2-signer/index.ts")
    else:
        r2_src = r2_signer.read_text(encoding="utf-8", errors="ignore")
        for fname in manifest.get("r2_signer_allowed_filenames", []):
            if f"'{fname}'" not in r2_src and f'"{fname}"' not in r2_src:
                errors.append(
                    f"Archivo '{fname}' ausente en whitelist ALLOWED_FILENAMES de r2-signer"
                )


def check_sibling_parity(
    repo_root: Path,
    repo_key: str,
    sibling_dir: Path,
    manifest: dict,
    errors: list,
):
    """Comprueba paridad de migraciones y archivos espejo de contrato contra el repositorio hermano."""
    if repo_key == "PEMTREE-admin":
        admin_dir, app_dir = repo_root, sibling_dir
    else:
        admin_dir, app_dir = sibling_dir, repo_root

    sync_script = repo_root / "scripts" / "sync-supabase-migrations.sh"
    res = subprocess.run(
        [
            "bash",
            str(sync_script),
            "--check",
            "--admin-dir",
            str(admin_dir),
            "--app-dir",
            str(app_dir),
        ],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        detail = (res.stdout + "\n" + res.stderr).strip()
        errors.append(f"Desfase de migraciones entre repositorios:\n{detail}")

    for rel in manifest.get("mirrored_contract_files", []):
        local_f = repo_root / rel
        sib_f = sibling_dir / rel
        if not local_f.is_file():
            errors.append(f"Archivo espejo faltante localmente: {rel}")
            continue
        if not sib_f.is_file():
            errors.append(f"Archivo espejo faltante en hermano ({sibling_dir.name}): {rel}")
            continue
        local_norm = local_f.read_bytes().replace(b"\r\n", b"\n")
        sib_norm = sib_f.read_bytes().replace(b"\r\n", b"\n")
        if local_norm != sib_norm:
            errors.append(
                f"Divergencia en archivo espejo de contrato entre repos: {rel}"
            )


def main():
    parser = argparse.ArgumentParser(
        description="Valida el contrato de sincronización del ecosistema Zanate / PEMTREE-admin."
    )
    parser.add_argument(
        "--sibling-dir",
        help="Ruta al repositorio hermano (Comunidad_USAC o PEMTREE-admin).",
    )
    parser.add_argument(
        "--require-sibling",
        action="store_true",
        help="Falla si el repositorio hermano no existe en disco.",
    )
    args = parser.parse_args()

    script_path = Path(__file__).resolve()
    repo_root = script_path.parent.parent.parent

    repo_key, role_label, default_sibling_name = detect_repo_identity(repo_root)
    errors = []

    check_required_files(repo_root, errors)
    manifest = load_manifest(repo_root, errors)

    mig_count = 0
    if manifest is not None:
        mig_count = check_migrations(
            repo_root, manifest.get("critical_shared_rpcs", []), errors
        )
        check_edge_functions(
            repo_root, repo_key, manifest.get("edge_functions_ownership", {}), errors
        )
        check_deprecated_refs(
            repo_root,
            repo_key,
            manifest.get("supabase", {}).get("deprecated_refs", []),
            errors,
        )
        if repo_key == "PEMTREE-admin":
            check_admin_specific_contracts(repo_root, manifest, errors)

    check_git_secret_hygiene(repo_root, errors)

    sibling_env_var = "APP_REPO_PATH" if repo_key == "PEMTREE-admin" else "ADMIN_REPO_PATH"
    if args.sibling_dir:
        sibling_dir = Path(args.sibling_dir).resolve()
    elif os.environ.get(sibling_env_var):
        sibling_dir = Path(os.environ[sibling_env_var]).resolve()
    else:
        sibling_dir = (repo_root.parent / default_sibling_name).resolve()

    sibling_status = "SKIP-CI (hermano no presente)"
    if sibling_dir.is_dir() and (sibling_dir / "supabase" / "migrations").is_dir():
        if manifest is not None:
            check_sibling_parity(repo_root, repo_key, sibling_dir, manifest, errors)
            sibling_status = f"OK ({sibling_dir})"
    elif args.require_sibling:
        errors.append(
            f"Se requirió validación cruzada (--require-sibling), pero no existe el hermano en {sibling_dir}"
        )

    if errors:
        print(
            f"[FAIL] Violaciones de contrato de ecosistema en {repo_key} ({role_label}):\n",
            file=sys.stderr,
        )
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)

    print("==================================================================")
    print(f" Contrato de Ecosistema — {repo_key} ({role_label})")
    print("==================================================================")
    print(f"  [OK] Manifiesto validado:              schema {manifest['schema_version']}")
    print(f"  [OK] Archivos de contrato y AI:        {len(REQUIRED_REPO_FILES)}")
    print(f"  [OK] Migraciones SQL válidas:          {mig_count}")
    print(f"  [OK] RPCs críticos compartidos:        {len(manifest.get('critical_shared_rpcs', []))}")
    print(f"  [OK] Paridad con repositorio hermano:  {sibling_status}")
    print("------------------------------------------------------------------")
    print("  RESULTADO: Contrato de sincronización cumplido. Salida 0.")
    print("==================================================================")
    sys.exit(0)


if __name__ == "__main__":
    main()
