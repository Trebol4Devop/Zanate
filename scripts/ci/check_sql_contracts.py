#!/usr/bin/env python3
"""
Zanate - Guardrail de Contratos SQL vs Dart.

Verifica estáticamente que todas las tablas, vistas y funciones RPC referenciadas
en el código de la aplicación Flutter (`comunidad_universitaria/lib/**/*.dart`)
mediante `.from('...')` y `.rpc('...')` existan y estén definidas en las
migraciones SQL de Supabase (`supabase/migrations/**/*.sql`).

Garantiza determinismo, ejecución sin conexión de red y prevención de rotura
de contratos entre el frontend y el backend PostgreSQL.
"""

import os
import re
import sys
from pathlib import Path

# ==============================================================================
# EXCLUSIONES JUSTIFICADAS (Objetos gestionados por la plataforma Supabase)
# ==============================================================================
# Objetos del sistema que no se definen manualmente en `supabase/migrations/*.sql`
# porque son aprovisionados, gestionados o mantenidos por los servicios internos
# de Supabase (GoTrue/Auth, Storage API, realtime, extensiones estándar).
JUSTIFIED_EXCLUSIONS = {
    # Esquema auth (GoTrue - gestión de identidades y usuarios):
    "auth.users",
    "auth.identities",
    "auth.sessions",
    "auth.mfa_factors",
    "auth.refresh_tokens",
    "users",  # Referencia genérica a auth.users si se usase sin namespace
    # Esquema storage (Supabase Storage Engine - buckets y objetos binarios):
    "storage.objects",
    "storage.buckets",
    # Extensiones estándar habilitadas en Postgres:
    "extensions.uuid_generate_v4",
}


def strip_sql_comments(sql_content: str) -> str:
    """Elimina comentarios de una línea (-- ...) y multilínea (/* ... */) de SQL."""
    # Eliminar comentarios de una línea
    sql_clean = re.sub(r"--.*$", "", sql_content, flags=re.MULTILINE)
    # Eliminar comentarios multilínea
    sql_clean = re.sub(r"/\*.*?\*/", "", sql_clean, flags=re.DOTALL)
    return sql_clean


def parse_sql_migrations(migrations_dir: Path):
    """
    Escanea recursivamente las migraciones en `migrations_dir` y extrae todos
    los nombres de tablas, vistas y funciones declaradas o modificadas.
    """
    tables = set()
    views = set()
    functions = set()

    # Regex para sentencias DDL comunes
    re_table = re.compile(
        r"CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+([a-zA-Z0-9_\.\"]+)",
        re.IGNORECASE,
    )
    re_alter = re.compile(
        r"ALTER\s+TABLE(?:\s+IF\s+EXISTS)?\s+([a-zA-Z0-9_\.\"]+)",
        re.IGNORECASE,
    )
    re_view = re.compile(
        r"CREATE(?:\s+OR\s+REPLACE)?(?:\s+RECURSIVE)?(?:\s+MATERIALIZED)?\s+VIEW(?:\s+IF\s+NOT\s+EXISTS)?\s+([a-zA-Z0-9_\.\"]+)",
        re.IGNORECASE,
    )
    re_func = re.compile(
        r"CREATE(?:\s+OR\s+REPLACE)?\s+FUNCTION\s+([a-zA-Z0-9_\.\"]+)",
        re.IGNORECASE,
    )

    def register_identifier(target_set, raw_ident):
        clean = raw_ident.replace('"', "").strip().lower()
        if "." in clean:
            schema, name = clean.split(".", 1)
            target_set.add(clean)
            target_set.add(name)
        else:
            target_set.add(clean)
            target_set.add(f"public.{clean}")

    if not migrations_dir.exists():
        print(
            f"[ERROR] Directorio de migraciones no encontrado: {migrations_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    sql_files = sorted(migrations_dir.glob("**/*.sql"))
    for sf in sql_files:
        try:
            with open(sf, "r", encoding="utf-8", errors="ignore") as f:
                content = strip_sql_comments(f.read())
                for m in re_table.finditer(content):
                    register_identifier(tables, m.group(1))
                for m in re_alter.finditer(content):
                    register_identifier(tables, m.group(1))
                for m in re_view.finditer(content):
                    register_identifier(views, m.group(1))
                for m in re_func.finditer(content):
                    register_identifier(functions, m.group(1))
        except Exception as e:
            print(f"[ERROR] No se pudo leer {sf}: {e}", file=sys.stderr)
            sys.exit(1)

    return tables, views, functions, len(sql_files)


def scan_dart_contracts(lib_dir: Path):
    """
    Escanea recursivamente los archivos Dart en `lib_dir` buscando llamadas
    `.from('...')` y `.rpc('...')` con comillas simples o dobles.
    Retorna una lista de tuplas: (tipo, target, path_archivo, linea).
    """
    call_pattern = re.compile(
        r"\.(from|rpc)\s*\(\s*['\"]([a-zA-Z0-9_\.]+)['\"]",
        re.MULTILINE,
    )

    calls = []
    if not lib_dir.exists():
        print(
            f"[ERROR] Directorio Flutter lib no encontrado: {lib_dir}",
            file=sys.stderr,
        )
        sys.exit(1)

    dart_files = sorted(lib_dir.glob("**/*.dart"))
    for df in dart_files:
        try:
            with open(df, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
                for m in call_pattern.finditer(content):
                    call_type = m.group(1)  # 'from' o 'rpc'
                    target = m.group(2)
                    line_no = content[: m.start()].count("\n") + 1
                    calls.append((call_type, target, df, line_no))
        except Exception as e:
            print(f"[ERROR] No se pudo leer {df}: {e}", file=sys.stderr)
            sys.exit(1)

    return calls, len(dart_files)


def main():
    # Resolver la raíz del repositorio de forma determinista
    script_path = Path(__file__).resolve()
    repo_root = script_path.parent.parent.parent

    migrations_dir = repo_root / "supabase" / "migrations"
    lib_dir = repo_root / "comunidad_universitaria" / "lib"

    tables, views, functions, num_migrations = parse_sql_migrations(migrations_dir)
    relations = tables.union(views)

    dart_calls, num_dart_files = scan_dart_contracts(lib_dir)

    errors = []
    from_count = 0
    rpc_count = 0

    for call_type, target, path, line_no in dart_calls:
        target_lower = target.lower()
        rel_path = path.relative_to(repo_root)

        if target_lower in JUSTIFIED_EXCLUSIONS:
            continue

        if call_type == "from":
            from_count += 1
            if target_lower not in relations:
                errors.append(
                    f"{rel_path}:{line_no} -> .from('{target}'): Tabla o vista no encontrada en supabase/migrations/*.sql"
                )
        elif call_type == "rpc":
            rpc_count += 1
            if target_lower not in functions:
                errors.append(
                    f"{rel_path}:{line_no} -> .rpc('{target}'): Función RPC no encontrada en supabase/migrations/*.sql"
                )

    if errors:
        print(
            "[FAIL] Se detectaron violaciones en los contratos SQL vs Dart:\n",
            file=sys.stderr,
        )
        for err in errors:
            print(f"  [MISSING] {err}", file=sys.stderr)
        print(f"\nTotal de contratos rotos: {len(errors)}", file=sys.stderr)
        sys.exit(1)

    print("==================================================================")
    print(" Zanate - Verificación de Contratos SQL vs Dart (CI Guardrail)")
    print("==================================================================")
    print(f"  [OK] Archivos SQL de migración inspeccionados: {num_migrations}")
    print(f"  [OK] Tablas/vistas identificadas en DB:         {len(relations)}")
    print(f"  [OK] Funciones RPC identificadas en DB:        {len(functions)}")
    print(f"  [OK] Archivos Dart escaneados en lib/:         {num_dart_files}")
    print(f"  [OK] Consultas de tabla/vista (.from):         {from_count}")
    print(f"  [OK] Llamadas a procedimientos (.rpc):         {rpc_count}")
    print(f"  [OK] Exclusiones justificadas del sistema:     {len(JUSTIFIED_EXCLUSIONS)}")
    print("------------------------------------------------------------------")
    print("  RESULTADO: Todos los contratos SQL son consistentes. Salida 0.")
    print("==================================================================")
    sys.exit(0)


if __name__ == "__main__":
    main()
