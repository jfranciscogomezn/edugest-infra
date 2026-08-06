# =============================================================================
# EduGest — Inicializar bases de datos en RDS PostgreSQL
# Ejecutar DESPUÉS de create-rds.ps1
#
# Requisitos:
#   - psql instalado (viene con PostgreSQL local o instalar independiente)
#     Descargar: https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
#   - O usar Docker localmente: docker run --rm -it postgres:16 psql ...
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
    [string]$MasterDb       = "security",
    [string]$AppUsername    = "security_user",
    [string]$AppPassword    = "changeme_dev"
)

$env:PGPASSWORD = $MasterPassword

Write-Host "`n=== EduGest: Inicializando base de datos en RDS ===" -ForegroundColor Cyan
Write-Host "Endpoint: $Endpoint"

# ─── Verificar psql disponible ────────────────────────────────────────────────
$psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
if (-not $psqlCmd) {
    Write-Host ""
    Write-Host "psql no encontrado. Usando Docker para ejecutar el script..." -ForegroundColor Yellow
    Write-Host "(requiere Docker corriendo localmente)"
    $UseDocker = $true
} else {
    $UseDocker = $false
    Write-Host "psql encontrado: $($psqlCmd.Source)" -ForegroundColor Green
}

# ─── Función para ejecutar SQL ───────────────────────────────────────────────
function Invoke-Sql {
    param([string]$Sql, [string]$Description)
    Write-Host "  $Description..." -ForegroundColor Yellow
    if ($UseDocker) {
        echo $Sql | docker run --rm -i `
            -e PGPASSWORD=$MasterPassword `
            postgres:16 psql `
            -h $Endpoint -p 5432 -U $MasterUsername -d postgres
    } else {
        echo $Sql | psql -h $Endpoint -p 5432 -U $MasterUsername -d postgres
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error ejecutando: $Description"
    }
}

function Invoke-SqlOnDb {
    param([string]$Sql, [string]$Db, [string]$Description)
    Write-Host "  $Description..." -ForegroundColor Yellow
    if ($UseDocker) {
        echo $Sql | docker run --rm -i `
            -e PGPASSWORD=$MasterPassword `
            postgres:16 psql `
            -h $Endpoint -p 5432 -U $MasterUsername -d $Db
    } else {
        echo $Sql | psql -h $Endpoint -p 5432 -U $MasterUsername -d $Db
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Posible error en: $Description (puede ser normal si ya existe)"
    }
}

# ─── Crear usuario de aplicación ──────────────────────────────────────────────
Write-Host "`n[1/4] Creando usuario de aplicacion..." -ForegroundColor Yellow
Invoke-Sql -Description "Crear security_user" -Sql @"
DO `$`$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$AppUsername') THEN
    CREATE USER $AppUsername WITH PASSWORD '$AppPassword';
  END IF;
END
`$`$;
GRANT ALL PRIVILEGES ON DATABASE $MasterDb TO $AppUsername;
"@

# ─── Activar extensiones ──────────────────────────────────────────────────────
Write-Host "`n[2/4] Activando extensiones PostgreSQL..." -ForegroundColor Yellow
Invoke-SqlOnDb -Db $MasterDb -Description "Extensiones uuid-ossp, citext, pgcrypto" -Sql @"
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
"@

# ─── Permisos schema public ───────────────────────────────────────────────────
Write-Host "`n[3/4] Configurando permisos del schema public..." -ForegroundColor Yellow
Invoke-SqlOnDb -Db $MasterDb -Description "Permisos para security_user" -Sql @"
GRANT ALL ON SCHEMA public TO $AppUsername;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $AppUsername;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $AppUsername;
"@

# ─── GUC parameter para RLS ───────────────────────────────────────────────────
Write-Host "`n[4/4] Configurando GUC parameter para Row-Level Security..." -ForegroundColor Yellow
Invoke-SqlOnDb -Db $MasterDb -Description "GUC app.current_tenant" -Sql @"
ALTER DATABASE $MasterDb SET app.current_tenant = '';
"@

# ─── Verificacion final ───────────────────────────────────────────────────────
Write-Host "`n=== Verificando configuracion ===" -ForegroundColor Cyan
Invoke-SqlOnDb -Db $MasterDb -Description "Listar extensiones instaladas" -Sql @"
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('uuid-ossp','citext','pgcrypto')
AND installed_version IS NOT NULL;
"@

$env:PGPASSWORD = ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " BASE DE DATOS INICIALIZADA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Las migraciones Flyway (V1, V2) se aplican automaticamente"
Write-Host " cuando arranques ms-security con perfil cloud-dev."
Write-Host ""
Write-Host "ARRANCAR ms-security apuntando a RDS:" -ForegroundColor Yellow
Write-Host '  $env:SPRING_PROFILES_ACTIVE = "cloud-dev"'
Write-Host '  $env:DB_HOST    = "' + $Endpoint + '"'
Write-Host '  $env:DB_PASSWORD = "' + $AppPassword + '"'
Write-Host "  mvn spring-boot:run"
Write-Host "============================================================" -ForegroundColor Cyan
