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
. "$PSScriptRoot\common.ps1"
if ($Region) { $script:Region = $Region }

Assert-AwsCli | Out-Null

$existing = (Invoke-AwsCli ec2 describe-instances `
    --filters "Name=tag:Name,Values=$($script:Ec2Name)" "Name=tag:Environment,Values=$($script:EnvName)" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text `
    --region $script:Region).Out

if ($existing) {
    Write-Host "EC2 ya existe: $existing" -ForegroundColor Yellow
    Write-Host "Siguiente: .\apply-schedule.ps1 -InstanceId $existing"
    exit 0
}

$vpcId = (Invoke-AwsCli ec2 describe-vpcs `
    --filters "Name=isDefault,Values=true" `
    --query "Vpcs[0].VpcId" `
    --output text `
    --region $script:Region).Out
if (-not $vpcId) { throw "No hay VPC por defecto en $($script:Region)." }

$subnetId = (Invoke-AwsCli ec2 describe-subnets `
    --filters "Name=vpc-id,Values=$vpcId" "Name=defaultForAz,Values=true" `
    --query "Subnets[0].SubnetId" `
    --output text `
    --region $script:Region).Out
if (-not $subnetId) { throw "No hay subnet default en la VPC $vpcId." }

$sgId = (Invoke-AwsCli ec2 describe-security-groups `
    --filters "Name=group-name,Values=$($script:ApiSgName)" "Name=vpc-id,Values=$vpcId" `
    --query "SecurityGroups[0].GroupId" `
    --output text `
    --region $script:Region).Out

if (-not $sgId) {
    $sgId = (Invoke-AwsCli ec2 create-security-group `
        --group-name $script:ApiSgName `
        --description "EduGest QA API 80/443 (restringir a IPs de QA)" `
        --vpc-id $vpcId `
        --query "GroupId" `
        --output text `
        --region $script:Region).Out
    if (-not $sgId) { throw "No se pudo crear el security group $($script:ApiSgName)." }
    foreach ($port in @(80, 443)) {
        $ing = Invoke-AwsCli ec2 authorize-security-group-ingress --group-id $sgId --protocol tcp --port $port --cidr 0.0.0.0/0 --region $script:Region
        if ($ing.Code -ne 0) { throw "No se abrio el puerto $port. $($ing.Text)" }
    }
    Write-Host "SG creado $sgId (80/443 abiertos; restringe con IPs de QA). 8080 no se publica." -ForegroundColor Yellow
}

$rdsSg = (Invoke-AwsCli ec2 describe-security-groups `
    --filters "Name=group-name,Values=$($script:RdsInstanceId)-sg" "Name=vpc-id,Values=$vpcId" `
    --query "SecurityGroups[0].GroupId" `
    --output text `
    --region $script:Region).Out
if ($rdsSg) {
    $rdsIng = Invoke-AwsCli ec2 authorize-security-group-ingress `
        --group-id $rdsSg `
        --protocol tcp `
        --port 5432 `
        --source-group $sgId `
        --region $script:Region
    if ($rdsIng.Code -ne 0 -and $rdsIng.Text -notmatch 'InvalidPermission.Duplicate') {
        Write-Host "Aviso: no se pudo abrir 5432 desde el SG de la EC2. $($rdsIng.Text)" -ForegroundColor Yellow
    }
}

$role = Invoke-AwsCli iam get-role --role-name $script:InstanceProfileName
if ($role.Code -ne 0) {
    $trustFile = Join-Path $env:TEMP "edugest-ec2-trust.json"
    $ec2Trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    [IO.File]::WriteAllText($trustFile, $ec2Trust, [Text.UTF8Encoding]::new($false))
    $cr = Invoke-AwsCli iam create-role --role-name $script:InstanceProfileName --assume-role-policy-document (ConvertTo-AwsFileUri $trustFile)
    if ($cr.Code -ne 0) { throw "create-role fallo. $($cr.Text)" }
    $ap = Invoke-AwsCli iam attach-role-policy --role-name $script:InstanceProfileName --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    if ($ap.Code -ne 0) { throw "attach-role-policy fallo. $($ap.Text)" }
    $cip = Invoke-AwsCli iam create-instance-profile --instance-profile-name $script:InstanceProfileName
    if ($cip.Code -ne 0 -and $cip.Text -notmatch 'EntityAlreadyExists') { throw "create-instance-profile fallo. $($cip.Text)" }
    $add = Invoke-AwsCli iam add-role-to-instance-profile --instance-profile-name $script:InstanceProfileName --role-name $script:InstanceProfileName
    if ($add.Code -ne 0 -and $add.Text -notmatch 'LimitExceeded|EntityAlreadyExists') { throw "add-role-to-instance-profile fallo. $($add.Text)" }
    Write-Host "Esperando instance profile..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
}

$ami = (Invoke-AwsCli ssm get-parameters `
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 `
    --query "Parameters[0].Value" `
    --output text `
    --region $script:Region).Out
if (-not $ami) { throw "No se obtuvo AMI Amazon Linux 2023." }

$userDataUri = ConvertTo-AwsFileUri (Join-Path $PSScriptRoot "userdata.sh")
$ebs = "DeviceName=/dev/xvda,Ebs={VolumeSize=$($script:RootVolumeGb),VolumeType=gp3,DeleteOnTermination=true}"
$tags = "ResourceType=instance,Tags=[{Key=Name,Value=$($script:Ec2Name)},{Key=Project,Value=$($script:Project)},{Key=Environment,Value=$($script:EnvName)},{Key=Schedule,Value=office-hours}]"

$runArgs = @(
    "ec2", "run-instances",
    "--image-id", $ami,
    "--instance-type", $script:InstanceType,
    "--subnet-id", $subnetId,
    "--security-group-ids", $sgId,
    "--iam-instance-profile", "Name=$($script:InstanceProfileName)",
    "--user-data", $userDataUri,
    "--block-device-mappings", $ebs,
    "--tag-specifications", $tags,
    "--metadata-options", "HttpTokens=required,HttpEndpoint=enabled",
    "--region", $script:Region,
    "--query", "Instances[0].InstanceId",
    "--output", "text"
)
if ($KeyName) { $runArgs += @("--key-name", $KeyName) }

$launched = Invoke-AwsCli @runArgs
$instanceId = $launched.Out
if ($launched.Code -ne 0 -or -not $instanceId) { throw "run-instances no devolvio InstanceId. $($launched.Text)" }

Write-Host "EC2 lanzada: $instanceId  (t3.micro, 8 GB, SSM, sin key pair salvo -KeyName)" -ForegroundColor Green
Write-Host "Siguiente:" -ForegroundColor Yellow
Write-Host "  .\apply-schedule.ps1 -InstanceId $instanceId"
Write-Host "  Copiar el JAR por SSM y apuntar Amplify al API_URL HTTPS (Caddy en 443)."
