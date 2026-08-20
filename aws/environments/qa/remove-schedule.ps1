# Quita los schedules QA. No borra RDS ni EC2.
param([string]$Region = "")

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\config.ps1"
if ($Region) { $script:Region = $Region }

$names = @(
    "edugest-qa-rds-start",
    "edugest-qa-rds-stop",
    "edugest-qa-ec2-start",
    "edugest-qa-ec2-stop"
)

foreach ($n in $names) {
    aws scheduler delete-schedule --name $n --group-name $script:ScheduleGroup --region $script:Region 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Eliminado: $n" -ForegroundColor Green
    } else {
        Write-Host "No existia: $n" -ForegroundColor DarkGray
    }
}

aws scheduler delete-schedule-group --name $script:ScheduleGroup --region $script:Region 2>$null | Out-Null
Write-Host "Grupo $script:ScheduleGroup procesado. El rol IAM $script:SchedulerRoleName se deja (reutilizable)." -ForegroundColor Yellow
