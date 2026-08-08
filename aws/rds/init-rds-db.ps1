# =============================================================================
# EduGest -- Inicializar base de datos en RDS PostgreSQL
# Ejecutar DESPUES de create-rds.ps1
#
# Crea:
#   - Base de datos 'db_security' (convencion: db_<servicio>)
#   - Usuario 'security_user'
#   - Extensiones: uuid-ossp, citext, pgcrypto
#   - Permisos schema public
#   - GUC app.current_tenant para RLS
#
# Requisitos:
#   - psql  O  Docker corriendo
#
# Uso:
#   .\init-rds-db.ps1 -Endpoint "xxxx.rds.amazonaws.com" -MasterPassword "TuPassword"
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Endpoint,

    [Parameter(Mandatory = $true)]
    [string]$MasterPassword,

    [string]$MasterUsername = "postgres",
    [string]$AppDb          = "db_security",
    [string]$AppUsername    = "security_user",
    [string]$AppPassword    = "changeme_dev"
)

$ErrorActionPreference = "Continue"
$env:PGPASSWORD = $MasterPassword

Write-Host ""
Write-Host "=== EduGest: Inicializando base de datos en RDS ===" -ForegroundColor Cyan
Write-Host "Endpoint: $Endpoint"
Write-Host "Database: $AppDb | App user: $AppUsername"

# --- Detectar cliente SQL -----------------------------------------------------
$psqlCmd = Get-Command psql -ErrorAction SilentlyContinue
$UseDocker = $false
if (-not $psqlCmd) {
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Error "Necesitas 'psql' o Docker instalado para inicializar la BD."
        exit 1
    }
    Write-Host "psql no encontrado. Usando Docker (postgres:16)..." -ForegroundColor Yellow
    $UseDocker = $true
} else {
    Write-Host "psql encontrado: $($psqlCmd.Source)" -ForegroundColor Green
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Sql,
        [string]$Description = "SQL"
    )
    Write-Host "  $Description..." -ForegroundColor Yellow

    if ($UseDocker) {
        $output = $Sql | docker run --rm -i `
            -e "PGPASSWORD=$MasterPassword" `
            postgres:16 `
            psql -v ON_ERROR_STOP=1 -h $Endpoint -p 5432 -U $MasterUsername -d $Database 2>&1
        $code = $LASTEXITCODE
    } else {
        $output = $Sql | psql -v ON_ERROR_STOP=1 -h $Endpoint -p 5432 -U $MasterUsername -d $Database 2>&1
        $code = $LASTEXITCODE
    }

    if ($code -ne 0) {
        Write-Host $output -ForegroundColor Red
        return $false
    }
    if ($output) {
        Write-Host $output -ForegroundColor DarkGray
    }
    return $true
}

function Get-PsqlScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$Sql
    )
    if ($UseDocker) {
        $out = $Sql | docker run --rm -i `
            -e "PGPASSWORD=$MasterPassword" `
            postgres:16 `
            psql -t -A -h $Endpoint -p 5432 -U $MasterUsername -d $Database 2>&1
    } else {
        $out = $Sql | psql -t -A -h $Endpoint -p 5432 -U $MasterUsername -d $Database 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host $out -ForegroundColor Red
        return $null
    }
    return ("$out").Trim()
}

# --- Test de conectividad -----------------------------------------------------
Write-Host ""
Write-Host "[0/5] Probando conexion a RDS..." -ForegroundColor Yellow
$ping = Get-PsqlScalar -Database "postgres" -Sql "SELECT 1;"
if ($ping -ne "1") {
    Write-Error @"
No se pudo conectar a $Endpoint:5432
Verifica:
  1) La instancia esta 'available'
  2) El Security Group permite tu IP en el puerto 5432
  3) La contrasena master es correcta
  4) PubliclyAccessible = true
"@
    exit 1
}
Write-Host "  Conexion OK" -ForegroundColor Green

# --- [1/5] Crear base de datos ------------------------------------------------
Write-Host ""
Write-Host "[1/5] Creando base de datos '$AppDb'..." -ForegroundColor Yellow
$dbExists = Get-PsqlScalar -Database "postgres" -Sql "SELECT 1 FROM pg_database WHERE datname = '$AppDb';"
if ($dbExists -eq "1") {
    Write-Host "  La base '$AppDb' ya existe." -ForegroundColor Yellow
} else {
    $ok = Invoke-Psql -Database "postgres" -Description "CREATE DATABASE $AppDb" -Sql "CREATE DATABASE $AppDb OWNER $MasterUsername;"
    if (-not $ok) {
        Write-Error "No se pudo crear la base de datos '$AppDb'."
        exit 1
    }
    Write-Host "  Base '$AppDb' creada." -ForegroundColor Green
}

# --- [2/5] Usuario de aplicacion ----------------------------------------------
Write-Host ""
Write-Host "[2/5] Creando usuario '$AppUsername'..." -ForegroundColor Yellow
$ok = Invoke-Psql -Database "postgres" -Description "CREATE/GRANT user" -Sql @"
DO `$`$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$AppUsername') THEN
    CREATE USER $AppUsername WITH PASSWORD '$AppPassword';
  ELSE
    ALTER USER $AppUsername WITH PASSWORD '$AppPassword';
  END IF;
END
`$`$;
GRANT ALL PRIVILEGES ON DATABASE $AppDb TO $AppUsername;
"@
if (-not $ok) {
    Write-Error "No se pudo crear/actualizar el usuario '$AppUsername'."
    exit 1
}
Write-Host "  Usuario listo." -ForegroundColor Green

# --- [3/5] Extensiones --------------------------------------------------------
Write-Host ""
Write-Host "[3/5] Activando extensiones..." -ForegroundColor Yellow
$ok = Invoke-Psql -Database $AppDb -Description "uuid-ossp, citext, pgcrypto" -Sql @"
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
"@
if (-not $ok) {
    Write-Error "No se pudieron crear las extensiones."
    exit 1
}
Write-Host "  Extensiones OK." -ForegroundColor Green

# --- [4/5] Permisos schema public ---------------------------------------------
Write-Host ""
Write-Host "[4/5] Configurando permisos del schema public..." -ForegroundColor Yellow
$ok = Invoke-Psql -Database $AppDb -Description "GRANT schema public" -Sql @"
GRANT ALL ON SCHEMA public TO $AppUsername;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $AppUsername;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $AppUsername;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $AppUsername;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $AppUsername;
"@
if (-not $ok) {
    Write-Warning "Hubo advertencias al configurar permisos."
} else {
    Write-Host "  Permisos OK." -ForegroundColor Green
}

# --- [5/5] GUC RLS ------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Configurando GUC app.current_tenant..." -ForegroundColor Yellow
$ok = Invoke-Psql -Database $AppDb -Description "ALTER DATABASE SET GUC" -Sql @"
ALTER DATABASE $AppDb SET app.current_tenant = '';
"@
if (-not $ok) {
    Write-Warning "No se pudo configurar el GUC (puede requerir permisos especiales)."
} else {
    Write-Host "  GUC OK." -ForegroundColor Green
}

# --- Verificacion -------------------------------------------------------------
Write-Host ""
Write-Host "=== Verificacion ===" -ForegroundColor Cyan
Invoke-Psql -Database $AppDb -Description "Extensiones instaladas" -Sql @"
SELECT name, installed_version
FROM pg_available_extensions
WHERE name IN ('uuid-ossp','citext','pgcrypto')
  AND installed_version IS NOT NULL
ORDER BY name;
"@ | Out-Null

$env:PGPASSWORD = ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " BASE DE DATOS INICIALIZADA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Endpoint      : $Endpoint"
Write-Host " Base de datos : $AppDb"
Write-Host " Usuario app   : $AppUsername"
Write-Host " Password app  : $AppPassword"
Write-Host ""
Write-Host "ARRANCAR ms-security:" -ForegroundColor Yellow
Write-Host ('  $env:SPRING_PROFILES_ACTIVE = "cloud-dev"')
Write-Host ("  " + '$env:DB_HOST     = "' + $Endpoint + '"')
Write-Host ("  " + '$env:DB_PASSWORD = "' + $AppPassword + '"')
Write-Host "  mvn spring-boot:run"
Write-Host "============================================================" -ForegroundColor Cyan
