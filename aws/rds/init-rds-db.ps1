# =============================================================================
# EduGest -- Inicializar base de datos en RDS PostgreSQL
# Ejecutar DESPUES de create-rds.ps1
#
# Requisitos:
#   - psql instalado  https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
#   - O Docker corriendo localmente (el script lo detecta automaticamente)
#
# Uso:
#   .\init-rds-db.ps1 -Endpoint "xxxx.rds.amazonaws.com" -MasterPassword "TuPassword"
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$Endpoint,

    [Parameter(Mandatory=$true)]
    [string]$MasterPassword,

    [string]$MasterUsername = "postgres",
    [string]$AppDb          = "security",
    [string]$AppUsername    = "security_user",
    [string]$AppPassword    = "changeme_dev"
)

$env:PGPASSWORD = $MasterPassword

Write-Host ""
Write-Host "=== EduGest: Inicializando base de datos en RDS ===" -ForegroundColor Cyan
Write-Host "Endpoint: $Endpoint"

# --- Verificar psql disponible ------------------------------------------------
$psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
if (-not $psqlCmd) {
    Write-Host ""
    Write-Host "psql no encontrado. Usando Docker (asegurate de que Docker este corriendo)..." -ForegroundColor Yellow
    $UseDocker = $true
} else {
    $UseDocker = $false
    Write-Host "psql encontrado: $($psqlCmd.Source)" -ForegroundColor Green
}

# --- Helpers para ejecutar SQL ------------------------------------------------
function Run-Sql {
    param([string]$Sql, [string]$Db, [string]$Description)
    Write-Host "  $Description..." -ForegroundColor Yellow
    if ($UseDocker) {
        $Sql | docker run --rm -i `
            -e "PGPASSWORD=$MasterPassword" `
            postgres:16 psql -h $Endpoint -p 5432 -U $MasterUsername -d $Db
    } else {
        $Sql | psql -h $Endpoint -p 5432 -U $MasterUsername -d $Db
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Advertencia en '$Description' (puede ser normal si ya existe)"
    }
}

# --- [1/5] Crear base de datos 'security' -------------------------------------
# Debe ir primero: el --db-name del API de RDS no acepta "security" (reservado).
Write-Host ""
Write-Host "[1/5] Creando base de datos '$AppDb'..." -ForegroundColor Yellow
Run-Sql -Db "postgres" -Description "CREATE DATABASE $AppDb" -Sql @"
SELECT 'CREATE DATABASE $AppDb OWNER $MasterUsername'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$AppDb')\gexec
"@

# --- [2/5] Crear usuario de aplicacion ----------------------------------------
Write-Host ""
Write-Host "[2/5] Creando usuario '$AppUsername'..." -ForegroundColor Yellow
Run-Sql -Db "postgres" -Description "CREATE USER $AppUsername" -Sql @"
DO `$`$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$AppUsername') THEN
    CREATE USER $AppUsername WITH PASSWORD '$AppPassword';
  END IF;
END
`$`$;
GRANT ALL PRIVILEGES ON DATABASE $AppDb TO $AppUsername;
"@

# --- [3/5] Activar extensiones ------------------------------------------------
Write-Host ""
Write-Host "[3/5] Activando extensiones PostgreSQL..." -ForegroundColor Yellow
Run-Sql -Db $AppDb -Description "uuid-ossp, citext, pgcrypto" -Sql @"
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
"@

# --- [4/5] Permisos schema public ---------------------------------------------
Write-Host ""
Write-Host "[4/5] Configurando permisos del schema public..." -ForegroundColor Yellow
Run-Sql -Db $AppDb -Description "Permisos para $AppUsername" -Sql @"
GRANT ALL ON SCHEMA public TO $AppUsername;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $AppUsername;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $AppUsername;
"@

# --- [5/5] GUC parameter para RLS ---------------------------------------------
Write-Host ""
Write-Host "[5/5] Configurando GUC parameter para Row-Level Security..." -ForegroundColor Yellow
Run-Sql -Db $AppDb -Description "GUC app.current_tenant" -Sql @"
ALTER DATABASE $AppDb SET app.current_tenant = '';
"@

# --- Verificacion final -------------------------------------------------------
Write-Host ""
Write-Host "=== Verificando configuracion ===" -ForegroundColor Cyan
Run-Sql -Db $AppDb -Description "Extensiones instaladas" -Sql @"
SELECT name, installed_version
FROM pg_available_extensions
WHERE name IN ('uuid-ossp','citext','pgcrypto')
AND installed_version IS NOT NULL;
"@

$env:PGPASSWORD = ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " BASE DE DATOS INICIALIZADA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Base de datos : $AppDb"
Write-Host " Usuario app   : $AppUsername"
Write-Host " Las migraciones Flyway se aplican al arrancar ms-security."
Write-Host ""
Write-Host "ARRANCAR ms-security apuntando a RDS:" -ForegroundColor Yellow
Write-Host ('  $env:SPRING_PROFILES_ACTIVE = "cloud-dev"')
Write-Host ("  " + '$env:DB_HOST     = "' + $Endpoint + '"')
Write-Host ('  $env:DB_PASSWORD = "changeme_dev"')
Write-Host "  mvn spring-boot:run"
Write-Host "============================================================" -ForegroundColor Cyan
