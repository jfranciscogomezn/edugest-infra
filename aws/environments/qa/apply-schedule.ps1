# =============================================================================
# QA: EventBridge Scheduler 09:00-01:00 America/Bogota para RDS y EC2.
# RDS arranca 08:55 / para 01:05. EC2 arranca 09:00 / para 01:00.
# =============================================================================
param(
    [string]$InstanceId = "",
    [string]$Region = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\config.ps1"
if ($Region) { $script:Region = $Region }

function Get-SingleText([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "" }
    return ($Raw -split '\s+' | Where-Object { $_ -and $_ -ne "None" } | Select-Object -First 1).ToString().Trim()
}

function Assert-Aws {
    aws sts get-caller-identity --region $script:Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Credenciales AWS invalidas." }
}

function Resolve-QaEc2Id {
    param([string]$Given)
    if ($Given) { return $Given }
    $id = Get-SingleText (aws ec2 describe-instances `
        --filters "Name=tag:Name,Values=$script:Ec2Name" `
                  "Name=tag:Environment,Values=$script:EnvName" `
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[0].Instances[0].InstanceId" `
        --output text `
        --region $script:Region)
    return $id
}

function Set-QaSchedule {
    param(
        [string]$Name,
        [string]$Expression,
        [string]$TargetArn,
        [string]$InputJson,
        [string]$RoleArn
    )
    $body = @{
        Name                       = $Name
        GroupName                  = $script:ScheduleGroup
        ScheduleExpression         = $Expression
        ScheduleExpressionTimezone = $script:Timezone
        State                      = "ENABLED"
        FlexibleTimeWindow         = @{ Mode = "OFF" }
        Target                     = @{
            Arn     = $TargetArn
            RoleArn = $RoleArn
            Input   = $InputJson
        }
    }
    $tmp = Join-Path $env:TEMP "$Name.json"
    $json = $body | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))

    aws scheduler get-schedule --name $Name --group-name $script:ScheduleGroup --region $script:Region 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        aws scheduler update-schedule --cli-input-json "file://$tmp" --region $script:Region | Out-Null
        Write-Host "  Actualizado: $Name" -ForegroundColor Yellow
    } else {
        aws scheduler create-schedule --cli-input-json "file://$tmp" --region $script:Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el schedule $Name" }
        Write-Host "  Creado: $Name" -ForegroundColor Green
    }
}

Assert-Aws
$account = Get-SingleText (aws sts get-caller-identity --query Account --output text --region $script:Region)
$roleArn = "arn:aws:iam::${account}:role/$script:SchedulerRoleName"
$trust = Join-Path $PSScriptRoot "iam\scheduler-trust.json"
$policy = Join-Path $PSScriptRoot "iam\scheduler-policy.json"

Write-Host "=== QA scheduler $script:Timezone ===" -ForegroundColor Cyan

aws scheduler create-schedule-group --name $script:ScheduleGroup --region $script:Region 2>$null | Out-Null

aws iam get-role --role-name $script:SchedulerRoleName 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws iam create-role `
        --role-name $script:SchedulerRoleName `
        --assume-role-policy-document "file://$trust" | Out-Null
    Write-Host "  Rol IAM creado: $script:SchedulerRoleName" -ForegroundColor Green
    Start-Sleep -Seconds 12
} else {
    Write-Host "  Rol IAM ya existe." -ForegroundColor Yellow
}

aws iam put-role-policy `
    --role-name $script:SchedulerRoleName `
    --policy-name "edugest-qa-start-stop" `
    --policy-document "file://$policy" | Out-Null

Set-QaSchedule `
    -Name "edugest-qa-rds-start" `
    -Expression "cron(55 8 * * ? *)" `
    -TargetArn "arn:aws:scheduler:::aws-sdk:rds:startDBInstance" `
    -InputJson (@{ DbInstanceIdentifier = $script:RdsInstanceId } | ConvertTo-Json -Compress) `
    -RoleArn $roleArn

Set-QaSchedule `
    -Name "edugest-qa-rds-stop" `
    -Expression "cron(5 1 * * ? *)" `
    -TargetArn "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance" `
    -InputJson (@{ DbInstanceIdentifier = $script:RdsInstanceId } | ConvertTo-Json -Compress) `
    -RoleArn $roleArn

$ec2Id = Resolve-QaEc2Id $InstanceId
if ($ec2Id) {
    $ec2Input = (@{ InstanceIds = @($ec2Id) } | ConvertTo-Json -Compress)
    Set-QaSchedule `
        -Name "edugest-qa-ec2-start" `
        -Expression $script:StartCron `
        -TargetArn "arn:aws:scheduler:::aws-sdk:ec2:startInstances" `
        -InputJson $ec2Input `
        -RoleArn $roleArn
    Set-QaSchedule `
        -Name "edugest-qa-ec2-stop" `
        -Expression $script:StopCron `
        -TargetArn "arn:aws:scheduler:::aws-sdk:ec2:stopInstances" `
        -InputJson $ec2Input `
        -RoleArn $roleArn
    Write-Host "EC2 programada: $ec2Id" -ForegroundColor Green
} else {
    Write-Host "No hay EC2 qa ($script:Ec2Name). Solo RDS quedo programado. Corre deploy-ec2.ps1 y vuelve a aplicar este script." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Ventana QA: 09:00-01:00 $script:Timezone (RDS 08:55-01:05)." -ForegroundColor Cyan
Write-Host "Amplify y SES no se apagan." -ForegroundColor DarkGray
