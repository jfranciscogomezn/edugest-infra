# =============================================================================
# Instala Caddy + systemd en la EC2 YA EXISTENTE (SSM). No termina ni recrea.
# Requiere setup-ci.ps1 antes.
# =============================================================================
param(
    [string]$Region = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\common.ps1"
if ($Region) { $script:Region = $Region }

function Get-SsmValue([string]$Name, [switch]$Decrypt) {
    $args = @("ssm", "get-parameter", "--name", $Name, "--query", "Parameter.Value", "--output", "text", "--region", $script:Region)
    if ($Decrypt) { $args += "--with-decryption" }
    $r = Invoke-AwsCli @args
    if ($r.Code -ne 0 -or -not $r.Out) { throw "Falta parametro $Name. Corre setup-ci.ps1. $($r.Text)" }
    return $r.Out
}

function Wait-QaInstance([string]$Id) {
    $state = (Invoke-AwsCli ec2 describe-instances --instance-ids $Id --query "Reservations[0].Instances[0].State.Name" --output text --region $script:Region).Out
    if ($state -eq "stopped" -or $state -eq "stopping") {
        Write-Host "Arrancando $Id para el bootstrap..." -ForegroundColor Yellow
        $st = Invoke-AwsCli ec2 start-instances --instance-ids $Id --region $script:Region
        if ($st.Code -ne 0) { throw "start-instances: $($st.Text)" }
    }
    for ($i = 0; $i -lt 36; $i++) {
        $ping = (Invoke-AwsCli ssm describe-instance-information --filters "Key=InstanceIds,Values=$Id" --query "InstanceInformationList[0].PingStatus" --output text --region $script:Region).Out
        if ($ping -eq "Online") { return }
        Start-Sleep -Seconds 10
    }
    throw "SSM no esta Online en $Id. Revisa el instance profile y que la instancia tenga red."
}

Assert-AwsCli | Out-Null

$bucket = Get-SsmValue "$($script:SsmPrefix)/artifact-bucket"
$instanceId = Get-SsmValue "$($script:SsmPrefix)/instance-id"
$apiHost = Get-SsmValue "$($script:SsmPrefix)/api-hostname"
$dbHost = Get-SsmValue "$($script:SsmPrefix)/db-host"
$dbPass = Get-SsmValue "$($script:SsmPrefix)/db-password" -Decrypt
$cors = Get-SsmValue "$($script:SsmPrefix)/cors-origins"
$front = Get-SsmValue "$($script:SsmPrefix)/frontend-url"

Wait-QaInstance $instanceId

$envBody = @(
    "SPRING_PROFILES_ACTIVE=cloud-dev"
    "DB_HOST=$dbHost"
    "DB_PASSWORD=$dbPass"
    "APP_CORS_ALLOWED_ORIGINS=$cors"
    "APP_FRONTEND_BASE_URL=$front"
    "APP_MAIL_ENABLED=false"
) -join "`n"
$caddyEnv = "API_HOSTNAME=$apiHost`n"
$envFile = Join-Path $env:TEMP "ms-security.env"
$caddyFile = Join-Path $env:TEMP "caddy.env"
[IO.File]::WriteAllText($envFile, $envBody + "`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($caddyFile, $caddyEnv, [Text.UTF8Encoding]::new($false))

$filesDir = Join-Path $PSScriptRoot "files"
$uploads = @(
    @{ Local = (Join-Path $filesDir "install-runtime.sh"); Key = "bootstrap/install-runtime.sh" }
    @{ Local = (Join-Path $filesDir "Caddyfile"); Key = "bootstrap/Caddyfile" }
    @{ Local = (Join-Path $filesDir "ms-security.service"); Key = "bootstrap/ms-security.service" }
    @{ Local = (Join-Path $filesDir "caddy.service"); Key = "bootstrap/caddy.service" }
    @{ Local = $envFile; Key = "bootstrap/ms-security.env" }
    @{ Local = $caddyFile; Key = "bootstrap/caddy.env" }
)
foreach ($u in $uploads) {
    $cp = Invoke-AwsCli s3 cp $u.Local "s3://$bucket/$($u.Key)" --region $script:Region
    if ($cp.Code -ne 0) { throw "s3 cp $($u.Key): $($cp.Text)" }
}

$remote = "set -euxo pipefail; aws s3 cp s3://$bucket/bootstrap/install-runtime.sh /tmp/install-runtime.sh; sed -i 's/\r$//' /tmp/install-runtime.sh; bash /tmp/install-runtime.sh $bucket $apiHost"
$params = '{"commands":["' + $remote.Replace('\', '\\').Replace('"', '\"') + '"]}'
$paramFile = Join-Path $env:TEMP "ssm-bootstrap.json"
[IO.File]::WriteAllText($paramFile, $params, [Text.UTF8Encoding]::new($false))

$sent = Invoke-AwsCli ssm send-command `
    --instance-ids $instanceId `
    --document-name AWS-RunShellScript `
    --comment "edugest-qa-bootstrap" `
    --parameters (ConvertTo-AwsFileUri $paramFile) `
    --timeout-seconds 600 `
    --query "Command.CommandId" `
    --output text `
    --region $script:Region
if ($sent.Code -ne 0 -or -not $sent.Out) { throw "send-command: $($sent.Text)" }
$cmdId = $sent.Out
Write-Host "SSM command $cmdId — esperando..." -ForegroundColor Cyan

$status = ""
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 8
    $status = (Invoke-AwsCli ssm get-command-invocation --command-id $cmdId --instance-id $instanceId --query "Status" --output text --region $script:Region).Out
    if ($status -eq "Success") { break }
    if ($status -eq "Failed" -or $status -eq "Cancelled" -or $status -eq "TimedOut") {
        $err = (Invoke-AwsCli ssm get-command-invocation --command-id $cmdId --instance-id $instanceId --query "StandardErrorContent" --output text --region $script:Region).StdOut
        throw "Bootstrap SSM $status. $err"
    }
}
if ($status -ne "Success") { throw "Bootstrap SSM no termino (status=$status)." }

Write-Host "Runtime listo en $instanceId. Caddy https://$apiHost — el JAR lo sube GitHub Actions." -ForegroundColor Green
Write-Host "Secret de GitHub: QA_AWS_ROLE_ARN = arn:aws:iam::$(Assert-AwsCli):role/$($script:GhaRoleName)" -ForegroundColor Yellow
