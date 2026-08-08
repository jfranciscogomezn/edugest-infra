# =============================================================================
# EduGest -- Crear instancia RDS PostgreSQL 16 (Free Tier) en AWS
# Script PowerShell (Windows)
#
# Requisitos:
#   - AWS CLI instalado y configurado (aws configure)
#   - Permisos IAM: AmazonRDSFullAccess, AmazonVPCReadOnlyAccess / AmazonEC2*
#
# Uso:
#   .\create-rds.ps1
#   .\create-rds.ps1 -Region "us-east-1" -DbPassword "MiPassword123!"
#
# Notas importantes:
#   - NO se pasa --db-name: "security" es palabra reservada en el API de RDS.
#     La base de datos 'security' se crea luego con init-rds-db.ps1 via SQL.
#   - La version de PostgreSQL 16 se detecta dinamicamente (no hardcodeada).
# =============================================================================

param(
    [string]$Region         = "us-east-1",
    [string]$DbInstanceId   = "edugest-dev",
    [string]$MasterUsername = "postgres",
    [string]$DbPassword     = "",
    [string]$AppUsername    = "security_user",
    [string]$AppPassword    = "changeme_dev"
)

$ErrorActionPreference = "Continue"

function Assert-AwsCli {
    $aws = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $aws) {
        Write-Error "AWS CLI no encontrado. Instala con: winget install Amazon.AWSCLI"
        exit 1
    }
    # Verificar credenciales
    aws sts get-caller-identity --region $Region 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Credenciales AWS invalidas. Ejecuta: aws configure"
        exit 1
    }
}

function Get-SingleText {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "" }
    return ($Raw -split '\s+' | Where-Object { $_ -and $_ -ne "None" } | Select-Object -First 1).ToString().Trim()
}

# --- Preflight ----------------------------------------------------------------
Assert-AwsCli

if ([string]::IsNullOrEmpty($DbPassword)) {
    $secure = Read-Host "Contrasena master de RDS (8-128 chars, sin / `" @)" -AsSecureString
    $DbPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

if ($DbPassword.Length -lt 8) {
    Write-Error "La contrasena master debe tener al menos 8 caracteres."
    exit 1
}
if ($DbPassword -match '[/"@]') {
    Write-Error "La contrasena master no puede contener los caracteres /, `" o @."
    exit 1
}

Write-Host ""
Write-Host "=== EduGest: Creando instancia RDS PostgreSQL 16 ===" -ForegroundColor Cyan
Write-Host "Region: $Region | Instancia: $DbInstanceId"
Write-Host "Nota: la BD 'security' se crea en init-rds-db.ps1 (no via --db-name)." -ForegroundColor DarkGray

# --- 0. Si la instancia ya existe, solo mostrar endpoint -----------------------
Write-Host ""
Write-Host "[0/6] Verificando si la instancia ya existe..." -ForegroundColor Yellow
$existingStatus = aws rds describe-db-instances `
    --db-instance-identifier $DbInstanceId `
    --query "DBInstances[0].DBInstanceStatus" `
    --output text `
    --region $Region 2>$null

$existingStatus = Get-SingleText $existingStatus
if ($existingStatus -and $existingStatus -ne "None") {
    Write-Host "  Instancia '$DbInstanceId' ya existe (estado: $existingStatus)." -ForegroundColor Yellow
    if ($existingStatus -ne "available") {
        Write-Host "  Esperando a que este available..." -ForegroundColor Yellow
        aws rds wait db-instance-available `
            --db-instance-identifier $DbInstanceId `
            --region $Region
    }
    $Endpoint = Get-SingleText (aws rds describe-db-instances `
        --db-instance-identifier $DbInstanceId `
        --query "DBInstances[0].Endpoint.Address" `
        --output text `
        --region $Region)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " INSTANCIA RDS YA EXISTE" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Endpoint : $Endpoint"
    Write-Host " Puerto   : 5432"
    Write-Host " Usuario  : $MasterUsername"
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "SIGUIENTE PASO:" -ForegroundColor Yellow
    Write-Host "  .\init-rds-db.ps1 -Endpoint `"$Endpoint`" -MasterPassword `"<tu-password>`""
    exit 0
}
Write-Host "  No existe. Continuando con la creacion..." -ForegroundColor Green

# --- 1. VPC por defecto -------------------------------------------------------
Write-Host ""
Write-Host "[1/6] Obteniendo VPC por defecto..." -ForegroundColor Yellow
$VpcId = Get-SingleText (aws ec2 describe-vpcs `
    --filters "Name=isDefault,Values=true" `
    --query "Vpcs[0].VpcId" `
    --output text `
    --region $Region)

if (-not $VpcId) {
    Write-Error "No se encontro VPC por defecto en la region $Region."
    exit 1
}
Write-Host "  VPC: $VpcId" -ForegroundColor Green

# --- 2. Subnets ---------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] Obteniendo subnets del VPC..." -ForegroundColor Yellow
$SubnetIdsRaw = aws ec2 describe-subnets `
    --filters "Name=vpc-id,Values=$VpcId" "Name=defaultForAz,Values=true" `
    --query "Subnets[*].SubnetId" `
    --output text `
    --region $Region

$SubnetIds = @(($SubnetIdsRaw -split '\s+') | Where-Object { $_ -match '^subnet-' })
if ($SubnetIds.Count -lt 2) {
    Write-Error "Se necesitan al menos 2 subnets. Encontradas: $($SubnetIds.Count)"
    exit 1
}
# RDS subnet group: minimo 2 AZs. Usamos hasta 3 para evitar listas enormes.
$SubnetIds = @($SubnetIds | Select-Object -First 3)
Write-Host "  Subnets ($($SubnetIds.Count)): $($SubnetIds -join ', ')" -ForegroundColor Green

# --- 3. DB Subnet Group -------------------------------------------------------
Write-Host ""
Write-Host "[3/6] Creando DB Subnet Group..." -ForegroundColor Yellow
$SubnetGroupName = "$DbInstanceId-subnet-group"

$sgOut = aws rds create-db-subnet-group `
    --db-subnet-group-name $SubnetGroupName `
    --db-subnet-group-description "Subnet group para EduGest dev" `
    --subnet-ids $SubnetIds `
    --region $Region `
    --output text 2>&1

if ($LASTEXITCODE -ne 0) {
    if ("$sgOut" -match "DBSubnetGroupAlreadyExists|already exists") {
        Write-Host "  Subnet group ya existe: $SubnetGroupName" -ForegroundColor Yellow
    } else {
        Write-Host $sgOut -ForegroundColor Red
        Write-Error "Error creando DB Subnet Group."
        exit 1
    }
} else {
    Write-Host "  Subnet group creado: $SubnetGroupName" -ForegroundColor Green
}

# --- 4. Security Group --------------------------------------------------------
Write-Host ""
Write-Host "[4/6] Creando Security Group..." -ForegroundColor Yellow
$SgName = "$DbInstanceId-sg"

$createSgOut = aws ec2 create-security-group `
    --group-name $SgName `
    --description "EduGest RDS dev - PostgreSQL 5432" `
    --vpc-id $VpcId `
    --query "GroupId" `
    --output text `
    --region $Region 2>&1

if ($LASTEXITCODE -ne 0) {
    $SgId = Get-SingleText (aws ec2 describe-security-groups `
        --filters "Name=group-name,Values=$SgName" "Name=vpc-id,Values=$VpcId" `
        --query "SecurityGroups[0].GroupId" `
        --output text `
        --region $Region)
    if (-not $SgId) {
        Write-Host $createSgOut -ForegroundColor Red
        Write-Error "No se pudo crear ni encontrar el Security Group."
        exit 1
    }
    Write-Host "  Security group ya existe: $SgId" -ForegroundColor Yellow
} else {
    $SgId = Get-SingleText "$createSgOut"
    aws ec2 authorize-security-group-ingress `
        --group-id $SgId `
        --protocol tcp `
        --port 5432 `
        --cidr "0.0.0.0/0" `
        --region $Region 2>&1 | Out-Null
    Write-Host "  Security group creado: $SgId" -ForegroundColor Green
    Write-Host "  ADVERTENCIA: Puerto 5432 abierto a 0.0.0.0/0 (solo desarrollo)." -ForegroundColor Red
}

# --- 5. Version PostgreSQL 16 + create ----------------------------------------
Write-Host ""
Write-Host "[5/6] Consultando versiones de PostgreSQL 16..." -ForegroundColor Yellow
$versionsRaw = aws rds describe-db-engine-versions `
    --engine postgres `
    --query "DBEngineVersions[?starts_with(EngineVersion,'16.')].EngineVersion" `
    --output text `
    --region $Region

$versions = @(($versionsRaw -split '\s+') | Where-Object { $_ -match '^16\.\d+$' })
if ($versions.Count -eq 0) {
    Write-Error "No hay versiones PostgreSQL 16 disponibles en $Region."
    exit 1
}
$EngineVersion = ($versions | Sort-Object { [version]$_ } | Select-Object -Last 1).ToString().Trim()
Write-Host "  Versiones encontradas: $($versions -join ', ')" -ForegroundColor DarkGray
Write-Host "  Version seleccionada: $EngineVersion" -ForegroundColor Green

Write-Host ""
Write-Host "[5/6] Creando instancia RDS (puede tardar 5-10 minutos)..." -ForegroundColor Yellow
Write-Host "  Clase: db.t3.micro | Storage: 20GB gp2 | Public: yes" -ForegroundColor DarkGray

# IMPORTANTE: NO usar --db-name. "security" es reservado en CreateDBInstance.
# La BD 'security' se crea con SQL en init-rds-db.ps1.
$createOut = aws rds create-db-instance `
    --db-instance-identifier $DbInstanceId `
    --db-instance-class db.t3.micro `
    --engine postgres `
    --engine-version $EngineVersion `
    --master-username $MasterUsername `
    --master-user-password $DbPassword `
    --allocated-storage 20 `
    --storage-type gp2 `
    --no-multi-az `
    --publicly-accessible `
    --db-subnet-group-name $SubnetGroupName `
    --vpc-security-group-ids $SgId `
    --backup-retention-period 7 `
    --no-deletion-protection `
    --auto-minor-version-upgrade `
    --tags "Key=Project,Value=EduGest" "Key=Environment,Value=dev" `
    --region $Region `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR de AWS al crear la instancia:" -ForegroundColor Red
    Write-Host $createOut -ForegroundColor Red
    Write-Host ""
    Write-Error "Error creando la instancia RDS."
    exit 1
}

Write-Host "  Solicitud aceptada. Esperando estado 'available' (~8 min)..." -ForegroundColor Yellow
aws rds wait db-instance-available `
    --db-instance-identifier $DbInstanceId `
    --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Error "Timeout o error esperando disponibilidad de RDS."
    exit 1
}

# --- 6. Endpoint --------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] Obteniendo endpoint..." -ForegroundColor Yellow
$Endpoint = Get-SingleText (aws rds describe-db-instances `
    --db-instance-identifier $DbInstanceId `
    --query "DBInstances[0].Endpoint.Address" `
    --output text `
    --region $Region)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " INSTANCIA RDS LISTA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Endpoint : $Endpoint"
Write-Host " Puerto   : 5432"
Write-Host " Usuario  : $MasterUsername"
Write-Host " Engine   : PostgreSQL $EngineVersion"
Write-Host " Region   : $Region"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "SIGUIENTE PASO - Crear la BD 'security' y el usuario de app:" -ForegroundColor Yellow
Write-Host "  .\init-rds-db.ps1 -Endpoint `"$Endpoint`" -MasterPassword `"<tu-password>`""
Write-Host ""
Write-Host "Guarda el endpoint. Lo necesitaras como DB_HOST en ms-security." -ForegroundColor Yellow
