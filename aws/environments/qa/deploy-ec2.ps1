# =============================================================================
# QA: una EC2 t3.micro en la VPC por defecto + SSM. Sin ALB, sin NAT, sin EIP extra.
# Despues: apply-schedule.ps1 para 09:00-01:00.
# =============================================================================
param(
    [string]$Region = "",
    [string]$KeyName = ""
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

$existing = Get-SingleText (aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=$script:Ec2Name" `
              "Name=tag:Environment,Values=$script:EnvName" `
              "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text `
    --region $script:Region)

if ($existing) {
    Write-Host "EC2 ya existe: $existing" -ForegroundColor Yellow
    Write-Host "Siguiente: .\apply-schedule.ps1 -InstanceId $existing"
    exit 0
}

$vpcId = Get-SingleText (aws ec2 describe-vpcs `
    --filters "Name=isDefault,Values=true" `
    --query "Vpcs[0].VpcId" `
    --output text `
    --region $script:Region)
if (-not $vpcId) { throw "No hay VPC por defecto en $script:Region." }

$subnetId = Get-SingleText (aws ec2 describe-subnets `
    --filters "Name=vpc-id,Values=$vpcId" "Name=defaultForAz,Values=true" `
    --query "Subnets[0].SubnetId" `
    --output text `
    --region $script:Region)

$sgId = Get-SingleText (aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=$script:ApiSgName" "Name=vpc-id,Values=$vpcId" `
    --query "SecurityGroups[0].GroupId" `
    --output text `
    --region $script:Region)

if (-not $sgId) {
    $sgId = Get-SingleText (aws ec2 create-security-group `
        --group-name $script:ApiSgName `
        --description "EduGest QA API 80/443 (restringir a IPs de QA)" `
        --vpc-id $vpcId `
        --query GroupId `
        --output text `
        --region $script:Region)
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 80 --cidr "0.0.0.0/0" --region $script:Region | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 443 --cidr "0.0.0.0/0" --region $script:Region | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port 8080 --cidr "0.0.0.0/0" --region $script:Region | Out-Null
    Write-Host "SG creado $sgId (80/443/8080 abiertos; restringe con IPs de QA)." -ForegroundColor Yellow
}

$rdsSg = Get-SingleText (aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=$script:RdsInstanceId-sg" "Name=vpc-id,Values=$vpcId" `
    --query "SecurityGroups[0].GroupId" `
    --output text `
    --region $script:Region)
if ($rdsSg) {
    aws ec2 authorize-security-group-ingress `
        --group-id $rdsSg `
        --protocol tcp `
        --port 5432 `
        --source-group $sgId `
        --region $script:Region 2>$null | Out-Null
}

aws iam get-role --role-name $script:InstanceProfileName 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    $ec2Trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    $trustFile = Join-Path $env:TEMP "edugest-ec2-trust.json"
    Set-Content -Path $trustFile -Value $ec2Trust -Encoding ascii
    aws iam create-role --role-name $script:InstanceProfileName --assume-role-policy-document "file://$trustFile" | Out-Null
    aws iam attach-role-policy --role-name $script:InstanceProfileName --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" | Out-Null
    aws iam create-instance-profile --instance-profile-name $script:InstanceProfileName | Out-Null
    aws iam add-role-to-instance-profile --instance-profile-name $script:InstanceProfileName --role-name $script:InstanceProfileName | Out-Null
    Write-Host "Esperando instance profile..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

$ami = Get-SingleText (aws ssm get-parameters `
    --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" `
    --query "Parameters[0].Value" `
    --output text `
    --region $script:Region)

$userDataPath = Join-Path $PSScriptRoot "userdata.sh"

$runArgs = @(
    "ec2", "run-instances",
    "--image-id", $ami,
    "--instance-type", $script:InstanceType,
    "--subnet-id", $subnetId,
    "--security-group-ids", $sgId,
    "--iam-instance-profile", "Name=$script:InstanceProfileName",
    "--user-data", ("file://" + $userDataPath.Replace("\", "/")),
    "--block-device-mappings", "DeviceName=/dev/xvda,Ebs={VolumeSize=$($script:RootVolumeGb),VolumeType=gp3,DeleteOnTermination=true}",
    "--tag-specifications", "ResourceType=instance,Tags=[{Key=Name,Value=$script:Ec2Name},{Key=Project,Value=$script:Project},{Key=Environment,Value=$script:EnvName},{Key=Schedule,Value=office-hours}]",
    "--metadata-options", "HttpTokens=required,HttpEndpoint=enabled",
    "--region", $script:Region,
    "--query", "Instances[0].InstanceId",
    "--output", "text"
)
if ($KeyName) { $runArgs += @("--key-name", $KeyName) }

$instanceId = Get-SingleText (aws @runArgs)
if (-not $instanceId) { throw "run-instances no devolvio InstanceId." }

Write-Host "EC2 lanzada: $instanceId  (t3.micro, 8 GB, SSM, sin key pair salvo -KeyName)" -ForegroundColor Green
Write-Host "Siguiente:" -ForegroundColor Yellow
Write-Host "  .\apply-schedule.ps1 -InstanceId $instanceId"
Write-Host "  Copiar el JAR por SSM y apuntar Amplify al API_URL."
