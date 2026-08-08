#!/usr/bin/env bash
# =============================================================================
# EduGest -- Inicializar base de datos en RDS PostgreSQL
# Ejecutar DESPUES de create-rds.sh
#
# Uso:
#   chmod +x init-rds-db.sh
#   ./init-rds-db.sh --endpoint "xxxx.rds.amazonaws.com" --master-password "TuPassword"
# =============================================================================
set -euo pipefail

ENDPOINT=""
MASTER_PASSWORD=""
MASTER_USERNAME="${MASTER_USERNAME:-postgres}"
APP_DB="${APP_DB:-db_security}"
APP_USERNAME="${APP_USERNAME:-security_user}"
APP_PASSWORD="${APP_PASSWORD:-changeme_dev}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint)         ENDPOINT="$2"; shift 2 ;;
        --master-password)  MASTER_PASSWORD="$2"; shift 2 ;;
        --master-username)  MASTER_USERNAME="$2"; shift 2 ;;
        --app-password)     APP_PASSWORD="$2"; shift 2 ;;
        *) echo "Argumento desconocido: $1"; exit 1 ;;
    esac
done

[[ -z "$ENDPOINT" ]]        && { read -rp "Endpoint RDS: " ENDPOINT; }
[[ -z "$MASTER_PASSWORD" ]] && { read -rs -p "Contrasena master: " MASTER_PASSWORD; echo; }

export PGPASSWORD="$MASTER_PASSWORD"

psql_exec() {
    local db="$1"; shift
    if command -v psql >/dev/null 2>&1; then
        psql -v ON_ERROR_STOP=1 -h "$ENDPOINT" -p 5432 -U "$MASTER_USERNAME" -d "$db" "$@"
    else
        echo "psql no encontrado. Usando Docker..."
        docker run --rm -i \
            -e PGPASSWORD="$MASTER_PASSWORD" \
            postgres:16 \
            psql -v ON_ERROR_STOP=1 -h "$ENDPOINT" -p 5432 -U "$MASTER_USERNAME" -d "$db" "$@"
    fi
}

psql_scalar() {
    local db="$1"; shift
    if command -v psql >/dev/null 2>&1; then
        psql -t -A -h "$ENDPOINT" -p 5432 -U "$MASTER_USERNAME" -d "$db" -c "$1"
    else
        echo "$1" | docker run --rm -i \
            -e PGPASSWORD="$MASTER_PASSWORD" \
            postgres:16 \
            psql -t -A -h "$ENDPOINT" -p 5432 -U "$MASTER_USERNAME" -d "$db"
    fi
}

echo "=== Inicializando base de datos en RDS: $ENDPOINT ==="

echo "[0/5] Probando conexion..."
PING=$(psql_scalar postgres "SELECT 1;")
[[ "$PING" == "1" ]] || { echo "ERROR: no se pudo conectar a $ENDPOINT"; exit 1; }
echo "  Conexion OK"

echo "[1/5] Creando base de datos '$APP_DB'..."
EXISTS=$(psql_scalar postgres "SELECT 1 FROM pg_database WHERE datname = '$APP_DB';" || true)
if [[ "$EXISTS" == "1" ]]; then
    echo "  Ya existe."
else
    psql_exec postgres -c "CREATE DATABASE $APP_DB OWNER $MASTER_USERNAME;"
    echo "  Creada."
fi

echo "[2/5] Creando usuario '$APP_USERNAME'..."
psql_exec postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$APP_USERNAME') THEN
    CREATE USER $APP_USERNAME WITH PASSWORD '$APP_PASSWORD';
  ELSE
    ALTER USER $APP_USERNAME WITH PASSWORD '$APP_PASSWORD';
  END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE $APP_DB TO $APP_USERNAME;
SQL

echo "[3/5] Activando extensiones..."
psql_exec "$APP_DB" <<SQL
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
SQL

echo "[4/5] Configurando permisos..."
psql_exec "$APP_DB" <<SQL
GRANT ALL ON SCHEMA public TO $APP_USERNAME;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $APP_USERNAME;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $APP_USERNAME;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $APP_USERNAME;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $APP_USERNAME;
SQL

echo "[5/5] Configurando GUC app.current_tenant..."
psql_exec "$APP_DB" <<SQL
ALTER DATABASE $APP_DB SET app.current_tenant = '';
SQL

echo ""
echo "Base de datos inicializada."
echo ""
echo "Variables para ms-security:"
echo "  export SPRING_PROFILES_ACTIVE='cloud-dev'"
echo "  export DB_HOST='$ENDPOINT'"
echo "  export DB_PASSWORD='$APP_PASSWORD'"
echo "  mvn spring-boot:run"

unset PGPASSWORD
