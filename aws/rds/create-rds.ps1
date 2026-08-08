# =============================================================================
# EduGest -- Crear instancia RDS PostgreSQL 16 (Free Tier) en AWS
# Script PowerShell (Windows)
#
# Requisitos:
#   - AWS CLI instalado: https://aws.amazon.com/cli/
#   - Credenciales configuradas: aws configure
#   - Permisos IAM: AmazonRDSFullAccess, AmazonVPCReadOnlyAccess
#
# Uso:
#   .\create-rds.ps1
#   .\create-rds.ps1 -Region "us-west-2" -DbPassword "MiPassword123!"
# =============================================================================

param(
    [string]$Region         = "us-east-1",
    [string]$DbInstanceId   = "edugest-dev",
    [string]$DbName         = "security",
    [string]$MasterUsername = "postgres",
    [string]$DbPassword     = "",
    [string]$AppUsername    = "security_user",
    [string]$AppPassword    = "changeme_dev"
)

# --- Pedir contrasena si no se paso -------------------------------------------
if ([string]::IsNullOrEmpty($DbPassword)) {
    $secure = Read-Host "Contrasena para el usuario master de RDS (minimo 8 caracteres)" -AsSecureString
    $DbPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

Write-Host ""
Write-Host "=== EduGest: Creando instancia RDS PostgreSQL 16 ===" -ForegroundColor Cyan
Write-Host "Region: $Region | Instancia: $DbInstanceId | DB: $DbName"

# --- 1. Obtener el VPC por defecto --------------------------------------------
Write-Host ""
Write-Host "[1/6] Obteniendo VPC por defecto..." -ForegroundColor Yellow
$VpcId = (aws ec2 describe-vpcs `
    --filters "Name=isDefault,Values=true" `
    --query "Vpcs[0].VpcId" `
    --output text `
    --region $Region)

if ($VpcId -eq "None" -or [string]::IsNullOrEmpty($VpcId)) {
    Write-Error "No se encontro VPC por defecto en la region $Region."
    exit 1
}
Write-Host "  VPC: $VpcId" -ForegroundColor Green

# --- 2. Obtener subnets del VPC -----------------------------------------------
Write-Host ""
Write-Host "[2/6] Obteniendo subnets del VPC por defecto..." -ForegroundColor Yellow
$SubnetIds = (aws ec2 describe-subnets `
    --filters "Name=vpc-id,Values=$VpcId" "Name=defaultForAz,Values=true" `
    --query "Subnets[*].SubnetId" `
    --output text `
    --region $Region) -split "`t"

if ($SubnetIds.Count -lt 2) {
    Write-Error "Se necesitan al menos 2 subnets. Encontradas: $($SubnetIds.Count)"
    exit 1
}
Write-Host "  Subnets: $($SubnetIds -join ', ')" -ForegroundColor Green

# --- 3. Crear DB Subnet Group -------------------------------------------------
Write-Host ""
Write-Host "[3/6] Creando DB Subnet Group..." -ForegroundColor Yellow
$SubnetGroupName = "$DbInstanceId-subnet-group"
aws rds create-db-subnet-group `
    --db-subnet-group-name $SubnetGroupName `
    --db-subnet-group-description "Subnet group para EduGest dev" `
    --subnet-ids $SubnetIds `
    --region $Region `
    --output text 2>&1 | Out-Null

Write-Host "  Subnet group: $SubnetGroupName" -ForegroundColor Green

# --- 4. Crear Security Group con acceso en puerto 5432 -----------------------
Write-Host ""
Write-Host "[4/6] Creando Security Group para PostgreSQL..." -ForegroundColor Yellow
$SgId = (aws ec2 create-security-group `
    --group-name "$DbInstanceId-sg" `
    --description "EduGest RDS dev - PostgreSQL 5432" `
    --vpc-id $VpcId `
    --query "GroupId" `
    --output text `
    --region $Region 2>&1)

if ($LASTEXITCODE -ne 0) {
    $SgId = (aws ec2 describe-security-groups `
        --filters "Name=group-name,Values=$DbInstanceId-sg" "Name=vpc-id,Values=$VpcId" `
        --query "SecurityGroups[0].GroupId" `
        --output text `
        --region $Region)
    Write-Host "  Security group ya existe: $SgId" -ForegroundColor Yellow
} else {
    Write-Host "  Abriendo puerto 5432 (solo para desarrollo)..." -ForegroundColor Yellow
    aws ec2 authorize-security-group-ingress `
        --group-id $SgId `
        --protocol tcp `
        --port 5432 `
        --cidr "0.0.0.0/0" `
        --region $Region | Out-Null
    Write-Host "  Security group creado: $SgId" -ForegroundColor Green
    Write-Host "  ADVERTENCIA: Puerto 5432 abierto a 0.0.0.0/0 - solo para desarrollo." -ForegroundColor Red
}

# --- 5. Crear la instancia RDS ------------------------------------------------
Write-Host ""
Write-Host "[5/6] Creando instancia RDS (puede tardar 5-10 minutos)..." -ForegroundColor Yellow
aws rds create-db-instance `
    --db-instance-identifier $DbInstanceId `
    --db-instance-class db.t3.micro `
    --engine postgres `
    --engine-version "16.8" `
    --master-username $MasterUsername `
    --master-user-password $DbPassword `
    --db-name $DbName `
    --allocated-storage 20 `
    --storage-type gp2 `
    --no-multi-az `
    --publicly-accessible `
    --db-subnet-group-name $SubnetGroupName `
    --vpc-security-group-ids $SgId `
    --backup-retention-period 7 `
    --no-deletion-protection `
    --tags "Key=Project,Value=EduGest" "Key=Environment,Value=dev" `
    --region $Region `
    --output table 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Error creando la instancia RDS."
    exit 1
}

Write-Host ""
Write-Host "[5/6] Esperando que la instancia este disponible (~8 min)..." -ForegroundColor Yellow
aws rds wait db-instance-available `
    --db-instance-identifier $DbInstanceId `
    --region $Region

# --- 6. Mostrar informacion de conexion ---------------------------------------
Write-Host ""
Write-Host "[6/6] Obteniendo endpoint..." -ForegroundColor Yellow
$Endpoint = (aws rds describe-db-instances `
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
Write-Host " DB Name  : $DbName"
Write-Host " Usuario  : $MasterUsername"
Write-Host " Region   : $Region"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "SIGUIENTE PASO - Inicializar la base de datos:" -ForegroundColor Yellow
Write-Host "  .\init-rds-db.ps1 -Endpoint `"$Endpoint`" -MasterPassword `"<tu-password>`""
Write-Host ""
Write-Host "Cadena de conexion para ms-security (perfil cloud-dev):" -ForegroundColor Yellow
Write-Host "  spring.datasource.url: jdbc:postgresql://${Endpoint}:5432/$DbName"
Write-Host "  spring.datasource.username: $AppUsername"
Write-Host "  spring.datasource.password: $AppPassword"
