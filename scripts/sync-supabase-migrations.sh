#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$REPO_ROOT/.." && pwd)"

if [[ -d "$REPO_ROOT/comunidad_universitaria" ]]; then
  CURRENT_ROLE="app"
  APP_ROOT="$REPO_ROOT"
  ADMIN_ROOT="${ADMIN_REPO_PATH:-$PARENT_DIR/PEMTREE-admin}"
else
  CURRENT_ROLE="admin"
  ADMIN_ROOT="$REPO_ROOT"
  APP_ROOT="${APP_REPO_PATH:-$PARENT_DIR/Comunidad_USAC}"
fi

MODE="--check"
FORCE=0

usage() {
  cat <<'EOF'
Uso: ./scripts/sync-supabase-migrations.sh [--check|--push-to-app|--pull-from-app|--bidirectional] [--admin-dir RUTA] [--app-dir RUTA] [--force]

Este script funciona de forma simétrica desde PEMTREE-admin o desde Comunidad_USAC (Zanate).

Modos:
  --check           Verifica paridad entre PEMTREE-admin y Comunidad_USAC (por defecto).
  --push-to-app     Copia migraciones faltantes desde PEMTREE-admin hacia Comunidad_USAC.
  --pull-from-app   Copia migraciones faltantes desde Comunidad_USAC hacia PEMTREE-admin.
  --bidirectional   Sincroniza migraciones faltantes en ambas direcciones.

Opciones:
  --admin-dir RUTA  Ruta al repositorio PEMTREE-admin (por defecto: detectada o ../PEMTREE-admin).
  --app-dir RUTA    Ruta al repositorio Comunidad_USAC (por defecto: detectada o ../Comunidad_USAC).
  --force           En conflicto de contenido, sobrescribe en la dirección elegida.
  -h, --help        Muestra esta ayuda.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--push-to-app|--pull-from-app|--bidirectional)
      MODE="$1"
      shift
      ;;
    --admin-dir)
      ADMIN_ROOT="$2"
      shift 2
      ;;
    --app-dir)
      APP_ROOT="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Opción desconocida: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ADMIN_MIGS="$ADMIN_ROOT/supabase/migrations"
APP_MIGS="$APP_ROOT/supabase/migrations"

if [[ ! -d "$ADMIN_MIGS" ]]; then
  echo "Error: no existe $ADMIN_MIGS" >&2
  exit 1
fi
if [[ ! -d "$APP_MIGS" ]]; then
  echo "Error: no existe $APP_MIGS" >&2
  exit 1
fi

norm_cmp() {
  if diff -q <(tr -d '\r' < "$1") <(tr -d '\r' < "$2") >/dev/null 2>&1; then
    return 0
  fi
  # Tolerar diferencias solo de comentarios o formato en migraciones importadas desde schema_migrations
  diff -q \
    <(tr -d '\r' < "$1" | sed -E 's/--.*$//' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/\( /(/g; s/ \)/)/g; s/^ //; s/ $//') \
    <(tr -d '\r' < "$2" | sed -E 's/--.*$//' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/\( /(/g; s/ \)/)/g; s/^ //; s/ $//') >/dev/null 2>&1
}

only_admin=()
only_app=()
conflicts=()
synced=0

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if [[ ! -f "$APP_MIGS/$f" ]]; then
    only_admin+=("$f")
  elif ! norm_cmp "$ADMIN_MIGS/$f" "$APP_MIGS/$f"; then
    conflicts+=("$f")
  else
    synced=$((synced + 1))
  fi
done < <(find "$ADMIN_MIGS" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort)

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if [[ ! -f "$ADMIN_MIGS/$f" ]]; then
    only_app+=("$f")
  fi
done < <(find "$APP_MIGS" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort)

echo "Executed from ($CURRENT_ROLE): $REPO_ROOT"
echo "Admin migrations: $ADMIN_MIGS"
echo "App migrations:   $APP_MIGS"
echo "Coincidentes: $synced | Solo en admin: ${#only_admin[@]} | Solo en app: ${#only_app[@]} | Diferentes: ${#conflicts[@]}"

if [[ "${#only_admin[@]}" -gt 0 ]]; then
  printf '  [solo-admin] %s\n' "${only_admin[@]}"
fi
if [[ "${#only_app[@]}" -gt 0 ]]; then
  printf '  [solo-app]   %s\n' "${only_app[@]}"
fi
if [[ "${#conflicts[@]}" -gt 0 ]]; then
  printf '  [conflicto]  %s\n' "${conflicts[@]}"
fi

if [[ "$MODE" == "--check" ]]; then
  if [[ "${#only_admin[@]}" -eq 0 && "${#only_app[@]}" -eq 0 && "${#conflicts[@]}" -eq 0 ]]; then
    echo "OK: ambos repositorios tienen el mismo historial de migraciones."
    exit 0
  fi
  exit 1
fi

if [[ "${#conflicts[@]}" -gt 0 && "$FORCE" -eq 0 ]]; then
  echo "Error: hay archivos con contenido distinto. Usa --force o resuelve manualmente." >&2
  exit 1
fi

copied=0
if [[ "$MODE" == "--push-to-app" || "$MODE" == "--bidirectional" ]]; then
  for f in "${only_admin[@]}"; do
    cp "$ADMIN_MIGS/$f" "$APP_MIGS/$f"
    echo "Copiado a app: $f"
    copied=$((copied + 1))
  done
  if [[ "$FORCE" -eq 1 && "$MODE" == "--push-to-app" ]]; then
    for f in "${conflicts[@]}"; do
      cp "$ADMIN_MIGS/$f" "$APP_MIGS/$f"
      echo "Sobrescrito en app: $f"
      copied=$((copied + 1))
    done
  fi
fi

if [[ "$MODE" == "--pull-from-app" || "$MODE" == "--bidirectional" ]]; then
  for f in "${only_app[@]}"; do
    cp "$APP_MIGS/$f" "$ADMIN_MIGS/$f"
    echo "Copiado a admin: $f"
    copied=$((copied + 1))
  done
  if [[ "$FORCE" -eq 1 && "$MODE" == "--pull-from-app" ]]; then
    for f in "${conflicts[@]}"; do
      cp "$APP_MIGS/$f" "$ADMIN_MIGS/$f"
      echo "Sobrescrito en admin: $f"
      copied=$((copied + 1))
    done
  fi
fi

echo "Sincronización completada ($copied archivo(s) copiado(s))."
