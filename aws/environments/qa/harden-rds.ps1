# =============================================================================
# QA: backup retention = 0 y tags Environment=qa en RDS edugest-dev.
# No crea la instancia. Origen: aws/rds/create-rds.ps1
# =============================================================================
param(
    [string]$Region = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\config.ps1"
if ($Region) { $script:Region = $Region }

function Get-SingleText([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "" }
    return ($Raw -split '\s+' | Where-Object { $_ -and $_ -ne "None" } | Select-Object -First 1).ToString().Trim()
}

aws sts get-caller-identity --region $script:Region | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Credenciales AWS invalidas." }

$status = Get-SingleText (aws rds describe-db-instances `
    --db-instance-identifier $script:RdsInstanceId `
    --query "DBInstances[0].DBInstanceStatus" `
    --output text `
    --region $script:Region 2>$null)

if (-not $status) {
    throw "No existe RDS '$($script:RdsInstanceId)'. Crea primero con aws/rds/create-rds.ps1"
}

Write-Host "RDS $script:RdsInstanceId estado=$status" -ForegroundColor Cyan

$arn = Get-SingleText (aws rds describe-db-instances `
    --db-instance-identifier $script:RdsInstanceId `
    --query "DBInstances[0].DBInstanceArn" `
    --output text `
    --region $script:Region)

aws rds add-tags-to-resource `
    --resource-name $arn `
    --tags "Key=Project,Value=$script:Project" `
           "Key=Environment,Value=$script:EnvName" `
           "Key=Schedule,Value=office-hours" `
    --region $script:Region | Out-Null

if ($status -eq "available") {
    Write-Host "Poniendo backup retention = 0 (borra backups automaticos de QA)..." -ForegroundColor Yellow
    aws rds modify-db-instance `
        --db-instance-identifier $script:RdsInstanceId `
        --backup-retention-period 0 `
        --no-deletion-protection `
        --apply-immediately `
        --region $script:Region | Out-Null
} else {
    Write-Host "Instancia no available ($status). Tags listos; corre de nuevo este script cuando este available para retention=0." -ForegroundColor Yellow
}

Write-Host "Listo. Tags Environment=qa, Schedule=office-hours." -ForegroundColor Green
