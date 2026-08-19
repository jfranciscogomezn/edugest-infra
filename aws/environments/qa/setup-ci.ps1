# =============================================================================
# QA CI: S3 artefactos, OIDC GitHub, rol GHA, Amplify (deploy manual), EIP
# estable, parametros SSM. NO destruye la EC2.
# =============================================================================
param(
    [string]$DbPassword = "changeme_dev",
    [string]$Region = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\common.ps1"
if ($Region) { $script:Region = $Region }

function Write-ReplacedJson([string]$Src, [string]$Dst, [hashtable]$Map) {
    $text = [IO.File]::ReadAllText($Src)
    foreach ($k in $Map.Keys) { $text = $text.Replace($k, [string]$Map[$k]) }
    [IO.File]::WriteAllText($Dst, $text, [Text.UTF8Encoding]::new($false))
}

function Set-SsmParam([string]$Name, [string]$Value, [string]$Type) {
    $r = Invoke-AwsCli ssm put-parameter --name $Name --value $Value --type $Type --overwrite --region $script:Region
    if ($r.Code -ne 0) { throw "put-parameter $Name fallo. $($r.Text)" }
}

$account = Assert-AwsCli
$bucket = "$($script:ArtifactPrefix)-$account"
Write-Host "Cuenta $account  bucket $bucket" -ForegroundColor Cyan

$instanceId = (Invoke-AwsCli ec2 describe-instances `
    --filters "Name=tag:Name,Values=$($script:Ec2Name)" "Name=tag:Environment,Values=$($script:EnvName)" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query "Reservations[0].Instances[0].InstanceId" `
    --output text `
    --region $script:Region).Out
if (-not $instanceId) { throw "No hay EC2 $($script:Ec2Name). Corre deploy-ec2.ps1 primero. No hace falta destruirla." }

$rdsHost = (Invoke-AwsCli rds describe-db-instances `
    --db-instance-identifier $script:RdsInstanceId `
    --query "DBInstances[0].Endpoint.Address" `
    --output text `
    --region $script:Region).Out
if (-not $rdsHost) { throw "No se obtuvo endpoint de RDS $($script:RdsInstanceId)." }

# --- S3 ---
$exists = Invoke-AwsCli s3api head-bucket --bucket $bucket --region $script:Region
if ($exists.Code -ne 0) {
    $created = Invoke-AwsCli s3api create-bucket --bucket $bucket --region $script:Region
    if ($created.Code -ne 0) { throw "create-bucket fallo. $($created.Text)" }
}
Invoke-AwsCli s3api put-public-access-block --bucket $bucket --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --region $script:Region | Out-Null
$life = '{"Rules":[{"ID":"expire-qa-artifacts","Prefix":"","Status":"Enabled","Expiration":{"Days":7}}]}'
$lifeFile = Join-Path $env:TEMP "edugest-s3-life.json"
[IO.File]::WriteAllText($lifeFile, $life, [Text.UTF8Encoding]::new($false))
Invoke-AwsCli s3api put-bucket-lifecycle-configuration --bucket $bucket --lifecycle-configuration (ConvertTo-AwsFileUri $lifeFile) --region $script:Region | Out-Null
Write-Host "S3 $bucket listo (lifecycle 7 dias)." -ForegroundColor Green

# --- GitHub OIDC ---
$oidc = Invoke-AwsCli iam get-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::${account}:oidc-provider/token.actions.githubusercontent.com"
if ($oidc.Code -ne 0) {
    $oidcNew = Invoke-AwsCli iam create-open-id-connect-provider `
        --url https://token.actions.githubusercontent.com `
        --client-id-list sts.amazonaws.com `
        --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd
    if ($oidcNew.Code -ne 0) { throw "OIDC GitHub: $($oidcNew.Text)" }
    Write-Host "OIDC GitHub creado." -ForegroundColor Green
} else {
    Write-Host "OIDC GitHub ya existe." -ForegroundColor Yellow
}

$tmp = $env:TEMP
Write-ReplacedJson (Join-Path $PSScriptRoot "iam\gha-trust.json") (Join-Path $tmp "edugest-gha-trust.json") @{ "__ACCOUNT__" = $account }
Write-ReplacedJson (Join-Path $PSScriptRoot "iam\gha-policy.json") (Join-Path $tmp "edugest-gha-policy.json") @{ "__BUCKET__" = $bucket }
Write-ReplacedJson (Join-Path $PSScriptRoot "iam\ec2-deploy-policy.json") (Join-Path $tmp "edugest-ec2-deploy.json") @{
    "__BUCKET__"  = $bucket
    "__REGION__"  = $script:Region
    "__ACCOUNT__" = $account
}

$ghaRole = Invoke-AwsCli iam get-role --role-name $script:GhaRoleName
if ($ghaRole.Code -ne 0) {
    $cr = Invoke-AwsCli iam create-role --role-name $script:GhaRoleName --assume-role-policy-document (ConvertTo-AwsFileUri (Join-Path $tmp "edugest-gha-trust.json"))
    if ($cr.Code -ne 0) { throw "create-role GHA: $($cr.Text)" }
} else {
    Invoke-AwsCli iam update-assume-role-policy --role-name $script:GhaRoleName --policy-document (ConvertTo-AwsFileUri (Join-Path $tmp "edugest-gha-trust.json")) | Out-Null
}
$pp = Invoke-AwsCli iam put-role-policy --role-name $script:GhaRoleName --policy-name edugest-qa-gha --policy-document (ConvertTo-AwsFileUri (Join-Path $tmp "edugest-gha-policy.json"))
if ($pp.Code -ne 0) { throw "put-role-policy GHA: $($pp.Text)" }
$roleArn = "arn:aws:iam::${account}:role/$($script:GhaRoleName)"
Write-Host "Rol GHA $roleArn" -ForegroundColor Green

$ec2Pol = Invoke-AwsCli iam put-role-policy --role-name $script:InstanceProfileName --policy-name edugest-qa-ec2-deploy --policy-document (ConvertTo-AwsFileUri (Join-Path $tmp "edugest-ec2-deploy.json"))
if ($ec2Pol.Code -ne 0) { throw "put-role-policy EC2: $($ec2Pol.Text)" }
Write-Host "EC2 role puede leer S3 artefactos y SSM /edugest/qa." -ForegroundColor Green

# --- EIP (URL estable; no recrea la instancia) ---
$assoc = (Invoke-AwsCli ec2 describe-addresses `
    --filters "Name=instance-id,Values=$instanceId" `
    --query "Addresses[0].PublicIp" `
    --output text `
    --region $script:Region).Out
if (-not $assoc) {
    $alloc = (Invoke-AwsCli ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$($script:EipName)},{Key=Project,Value=$($script:Project)},{Key=Environment,Value=$($script:EnvName)}]" --query "AllocationId" --output text --region $script:Region)
    if ($alloc.Code -ne 0 -or -not $alloc.Out) { throw "allocate-address: $($alloc.Text)" }
    $as = Invoke-AwsCli ec2 associate-address --instance-id $instanceId --allocation-id $alloc.Out --region $script:Region
    if ($as.Code -ne 0) { throw "associate-address: $($as.Text)" }
    $assoc = (Invoke-AwsCli ec2 describe-addresses --allocation-ids $alloc.Out --query "Addresses[0].PublicIp" --output text --region $script:Region).Out
    Write-Host "EIP $assoc asociada a $instanceId (la instancia NO se destruye)." -ForegroundColor Green
} else {
    Write-Host "EIP ya asociada: $assoc" -ForegroundColor Yellow
}

$apiHost = ($assoc -replace '\.', '-') + ".sslip.io"
$apiBase = "https://$apiHost/api/v1"

# --- Amplify (hosting manual; el zip lo sube GitHub Actions) ---
$appId = (Invoke-AwsCli amplify list-apps --query "apps[?name=='$($script:AmplifyAppName)'].appId | [0]" --output text --region $script:Region).Out
if (-not $appId) {
    $createdApp = Invoke-AwsCli amplify create-app --name $script:AmplifyAppName --platform WEB --region $script:Region --query "app.appId" --output text
    if ($createdApp.Code -ne 0 -or -not $createdApp.Out) { throw "create-app Amplify: $($createdApp.Text)" }
    $appId = $createdApp.Out
    Write-Host "Amplify app $appId" -ForegroundColor Green
} else {
    Write-Host "Amplify ya existe: $appId" -ForegroundColor Yellow
}
$branch = Invoke-AwsCli amplify get-branch --app-id $appId --branch-name $script:AmplifyBranch --region $script:Region
if ($branch.Code -ne 0) {
    $cb = Invoke-AwsCli amplify create-branch --app-id $appId --branch-name $script:AmplifyBranch --stage DEVELOPMENT --no-enable-auto-build --region $script:Region
    if ($cb.Code -ne 0) { throw "create-branch Amplify: $($cb.Text)" }
}
$frontUrl = "https://$($script:AmplifyBranch).$appId.amplifyapp.com"
Invoke-AwsCli amplify update-app --app-id $appId --custom-rules "source=/<*>,target=/index.html,status=200" --region $script:Region | Out-Null

Set-SsmParam "$($script:SsmPrefix)/db-host" $rdsHost "String"
Set-SsmParam "$($script:SsmPrefix)/db-password" $DbPassword "SecureString"
Set-SsmParam "$($script:SsmPrefix)/api-hostname" $apiHost "String"
Set-SsmParam "$($script:SsmPrefix)/api-base-url" $apiBase "String"
Set-SsmParam "$($script:SsmPrefix)/frontend-url" $frontUrl "String"
Set-SsmParam "$($script:SsmPrefix)/cors-origins" $frontUrl "String"
Set-SsmParam "$($script:SsmPrefix)/artifact-bucket" $bucket "String"
Set-SsmParam "$($script:SsmPrefix)/instance-id" $instanceId "String"
Set-SsmParam "$($script:SsmPrefix)/amplify-app-id" $appId "String"

Write-Host ""
Write-Host "Listo. Siguiente: .\bootstrap-ec2.ps1" -ForegroundColor Cyan
Write-Host "GitHub secret QA_AWS_ROLE_ARN = $roleArn" -ForegroundColor Yellow
Write-Host "API  $apiBase" -ForegroundColor Yellow
Write-Host "Front (tras primer workflow) $frontUrl" -ForegroundColor Yellow
Write-Host "No destruyas la EC2 $instanceId." -ForegroundColor DarkGray
