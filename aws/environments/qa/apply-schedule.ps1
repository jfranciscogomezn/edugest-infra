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
. "$PSScriptRoot\common.ps1"
if ($Region) { $script:Region = $Region }

function Resolve-QaEc2Id {
    param([string]$Given)
    if ($Given) { return $Given }
    return (Invoke-AwsCli ec2 describe-instances `
        --filters "Name=tag:Name,Values=$($script:Ec2Name)" "Name=tag:Environment,Values=$($script:EnvName)" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[0].Instances[0].InstanceId" `
        --output text `
        --region $script:Region).Out
}

function Set-QaSchedule {
    param(
        [string]$Name,
        [string]$Expression,
        [string]$TargetArn,
        [string]$InputJson,
        [string]$RoleArn
    )
    $inputEsc = $InputJson.Replace("\", "\\").Replace('"', '\"')
    $json = '{' +
        '"Name":"' + $Name + '",' +
        '"GroupName":"' + $script:ScheduleGroup + '",' +
        '"ScheduleExpression":"' + $Expression + '",' +
        '"ScheduleExpressionTimezone":"' + $script:Timezone + '",' +
        '"State":"ENABLED",' +
        '"FlexibleTimeWindow":{"Mode":"OFF"},' +
        '"Target":{"Arn":"' + $TargetArn + '","RoleArn":"' + $RoleArn + '","Input":"' + $inputEsc + '"}' +
        '}'
    $tmp = Join-Path $env:TEMP "$Name.json"
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    $uri = ConvertTo-AwsFileUri $tmp

    $exists = Invoke-AwsCli scheduler get-schedule --name $Name --group-name $script:ScheduleGroup --region $script:Region
    if ($exists.Code -eq 0) {
        $upd = Invoke-AwsCli scheduler update-schedule --cli-input-json $uri --region $script:Region
        if ($upd.Code -ne 0) { throw "No se pudo actualizar el schedule $Name. $($upd.Text)" }
        Write-Host "  Actualizado: $Name" -ForegroundColor Yellow
    } else {
        $cr = Invoke-AwsCli scheduler create-schedule --cli-input-json $uri --region $script:Region
        if ($cr.Code -ne 0) { throw "No se pudo crear el schedule $Name. $($cr.Text)" }
        Write-Host "  Creado: $Name" -ForegroundColor Green
    }
}

$account = Assert-AwsCli
$roleArn = "arn:aws:iam::${account}:role/$($script:SchedulerRoleName)"
$trustUri = ConvertTo-AwsFileUri (Join-Path $PSScriptRoot "iam\scheduler-trust.json")
$policyUri = ConvertTo-AwsFileUri (Join-Path $PSScriptRoot "iam\scheduler-policy.json")

Write-Host "=== QA scheduler $($script:Timezone) ===" -ForegroundColor Cyan

Invoke-AwsCli scheduler create-schedule-group --name $script:ScheduleGroup --region $script:Region | Out-Null

$role = Invoke-AwsCli iam get-role --role-name $script:SchedulerRoleName
if ($role.Code -ne 0) {
    $cr = Invoke-AwsCli iam create-role --role-name $script:SchedulerRoleName --assume-role-policy-document $trustUri
    if ($cr.Code -ne 0) { throw "No se creo el rol $($script:SchedulerRoleName). $($cr.Text)" }
    Write-Host "  Rol IAM creado: $($script:SchedulerRoleName)" -ForegroundColor Green
    Start-Sleep -Seconds 12
} else {
    Write-Host "  Rol IAM ya existe." -ForegroundColor Yellow
}

$pol = Invoke-AwsCli iam put-role-policy `
    --role-name $script:SchedulerRoleName `
    --policy-name edugest-qa-start-stop `
    --policy-document $policyUri
if ($pol.Code -ne 0) { throw "put-role-policy fallo. $($pol.Text)" }

$rdsInput = '{"DbInstanceIdentifier":"' + $script:RdsInstanceId + '"}'

Set-QaSchedule `
    -Name "edugest-qa-rds-start" `
    -Expression "cron(55 8 * * ? *)" `
    -TargetArn "arn:aws:scheduler:::aws-sdk:rds:startDBInstance" `
    -InputJson $rdsInput `
    -RoleArn $roleArn

Set-QaSchedule `
    -Name "edugest-qa-rds-stop" `
    -Expression "cron(5 1 * * ? *)" `
    -TargetArn "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance" `
    -InputJson $rdsInput `
    -RoleArn $roleArn

$ec2Id = Resolve-QaEc2Id $InstanceId
if ($ec2Id) {
    $ec2Input = '{"InstanceIds":["' + $ec2Id + '"]}'
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
    Write-Host "No hay EC2 qa ($($script:Ec2Name)). Solo RDS quedo programado. Corre deploy-ec2.ps1 y vuelve a aplicar este script." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Ventana QA: 09:00-01:00 $($script:Timezone) (RDS 08:55-01:05)." -ForegroundColor Cyan
Write-Host "Amplify y SES no se apagan." -ForegroundColor DarkGray
