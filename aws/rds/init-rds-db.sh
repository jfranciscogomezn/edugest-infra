#!/usr/bin/env bash
# =============================================================================
# EduGest — Inicializar bases de datos en RDS PostgreSQL
# Ejecutar DESPUÉS de create-rds.sh
#
# Uso:
#   chmod +x init-rds-db.sh
#   ./init-rds-db.sh --endpoint "xxxx.rds.amazonaws.com" --master-password "TuPassword"
# =============================================================================
set -euo pipefail

ENDPOINT=""; MASTER_PASSWORD=""
MASTER_USERNAME="${MASTER_USERNAME:-postgres}"
MASTER_DB="${MASTER_DB:-security}"
APP_USERNAME="${APP_USERNAME:-security_user}"
APP_PASSWORD="${APP_PASSWORD:-changeme_dev}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint)         ENDPOINT="$2";         shift 2 ;;
        --master-password)  MASTER_PASSWORD="$2";  shift 2 ;;
        --master-username)  MASTER_USERNAME="$2";  shift 2 ;;
        --app-password)     APP_PASSWORD="$2";     shift 2 ;;
        *) echo "Argumento desconocido: $1"; exit 1 ;;
    esac
done

[[ -z "$ENDPOINT" ]]        && { read -rp "Endpoint RDS: " ENDPOINT; }
[[ -z "$MASTER_PASSWORD" ]] && { read -rs -p "Contraseña master: " MASTER_PASSWORD; echo; }

export PGPASSWORD="$MASTER_PASSWORD"

psql_cmd() {
    local db="$1"; shift
    if command -v psql &>/dev/null; then
        psql -h "$ENDPOINT" -p 5432 -U "$MASTER_USERNAME" -d "$db" "$@"
    else
        echo "psql no encontrado. Usando Docker..."
        docker run --rm -i \
            -e PGPASSWORD="$MASTER_PASSWORD" \
            postgres:16 psql \
            -h "$ENDPOINT" -p 5432 -U "$MASTER_USERNAME" -d "$db" "$@"
    fi
}

echo "=== Inicializando base de datos en RDS: $ENDPOINT ==="

echo "[1/4] Creando usuario de aplicación..."
psql_cmd postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$APP_USERNAME') THEN
    CREATE USER $APP_USERNAME WITH PASSWORD '$APP_PASSWORD';
  END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE $MASTER_DB TO $APP_USERNAME;
SQL

echo "[2/4] Activando extensiones..."
psql_cmd "$MASTER_DB" <<SQL
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
SQL

echo "[3/4] Configurando permisos del schema public..."
psql_cmd "$MASTER_DB" <<SQL
GRANT ALL ON SCHEMA public TO $APP_USERNAME;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $APP_USERNAME;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $APP_USERNAME;
SQL

echo "[4/4] Configurando GUC parameter para RLS..."
psql_cmd "$MASTER_DB" <<SQL
ALTER DATABASE $MASTER_DB SET app.current_tenant = '';
SQL

echo ""
echo "✓ Base de datos inicializada."
echo ""
echo "Variables de entorno para arrancar ms-security:"
echo "  export DB_HOST='$ENDPOINT'"
echo "  export DB_PASSWORD='$APP_PASSWORD'"
echo "  export SPRING_PROFILES_ACTIVE='cloud-dev'"
echo "  mvn spring-boot:run"

unset PGPASSWORD
