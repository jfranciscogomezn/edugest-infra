# =============================================================================
# EduGest — Actualizar IPs permitidas en el Security Group de RDS
# Ejecutar cuando la IP de un developer cambia
#
# Uso:
#   .\restrict-ip.ps1 -Region "us-east-1" -DbInstanceId "edugest-dev"
#   .\restrict-ip.ps1 -Region "us-east-1" -DbInstanceId "edugest-dev" -AddIp "190.10.20.30"
# =============================================================================

param(
    [string]$Region       = "us-east-1",
    [string]$DbInstanceId = "edugest-dev",
    [string]$AddIp        = "",    # Si vacío, detecta la IP pública actual
    [switch]$RemoveAll            # Quitar acceso 0.0.0.0/0 si existe
)

# ─── Obtener SG del RDS ───────────────────────────────────────────────────────
$SgId = (aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=$DbInstanceId-sg" `
    --query "SecurityGroups[0].GroupId" `
    --output text `
    --region $Region)

if ([string]::IsNullOrEmpty($SgId) -or $SgId -eq "None") {
    Write-Error "No se encontró el security group '$DbInstanceId-sg' en la región $Region"
    exit 1
}
Write-Host "Security Group: $SgId" -ForegroundColor Cyan

# ─── Detectar IP pública si no se pasó ────────────────────────────────────────
if ([string]::IsNullOrEmpty($AddIp)) {
    $AddIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=text").Trim()
    Write-Host "IP pública detectada: $AddIp" -ForegroundColor Yellow
}

# ─── Agregar IP al Security Group ─────────────────────────────────────────────
Write-Host "Agregando $AddIp/32 al puerto 5432..." -ForegroundColor Yellow
aws ec2 authorize-security-group-ingress `
    --group-id $SgId `
    --protocol tcp `
    --port 5432 `
    --cidr "$AddIp/32" `
    --region $Region 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "IP $AddIp agregada correctamente." -ForegroundColor Green
} else {
    Write-Host "La IP ya estaba en la lista (puede ser normal)." -ForegroundColor Yellow
}

# ─── Eliminar acceso 0.0.0.0/0 si existe ──────────────────────────────────────
if ($RemoveAll) {
    Write-Host "Eliminando acceso abierto 0.0.0.0/0..." -ForegroundColor Red
    aws ec2 revoke-security-group-ingress `
        --group-id $SgId `
        --protocol tcp `
        --port 5432 `
        --cidr "0.0.0.0/0" `
        --region $Region 2>&1 | Out-Null
    Write-Host "Acceso 0.0.0.0/0 eliminado." -ForegroundColor Green
}

# ─── Mostrar reglas actuales ──────────────────────────────────────────────────
Write-Host "`nReglas actuales del Security Group:" -ForegroundColor Cyan
aws ec2 describe-security-groups `
    --group-ids $SgId `
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\`].IpRanges[*].CidrIp" `
    --output table `
    --region $Region
