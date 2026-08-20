# =============================================================================
# Tope de alerta: presupuesto COST mensual 300 USD (cuenta completa).
# No corta el cobro de AWS: envia correo al 50 / 80 / 100 % real y al 100 %
# pronosticado. Primeros 2 presupuestos = 0 USD.
# Corre ESTE script antes de harden-rds / deploy-ec2 / apply-schedule.
# =============================================================================
param(
    [Parameter(Mandatory = $true)]
    [string]$Email,
    [string]$Region = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\common.ps1"
if ($Region) { $script:Region = $Region }

if ($Email -notmatch '^[^@]+@[^@]+\.[^@]+$') {
    throw "Email invalido: $Email"
}

$account = Assert-AwsCli
Write-Host "Cuenta $account - comprobando presupuesto $($script:BudgetName)..." -ForegroundColor Cyan

$found = Invoke-AwsCli budgets describe-budget `
    --account-id $account `
    --budget-name $script:BudgetName `
    --query "Budget.BudgetName" `
    --output text `
    --region $script:Region

if ($found.Code -eq 0 -and $found.Out) {
    Write-Host "Presupuesto ya existe: $($found.Out) (tope $($script:BudgetAmountUsd) USD/mes)." -ForegroundColor Yellow
    Write-Host "No se recrea. Consola: Billing -> Budgets." -ForegroundColor DarkGray
    exit 0
}

if ($found.Code -ne 0 -and $found.Text -notmatch 'NotFoundException') {
    throw "No se pudo consultar el presupuesto. IAM necesita budgets:DescribeBudget y budgets:CreateBudget. $($found.Text)"
}

$now = [DateTime]::UtcNow
$start = [DateTimeOffset]::new($now.Year, $now.Month, 1, 0, 0, 0, [TimeSpan]::Zero).ToUnixTimeSeconds()
$emailEsc = $Email.Replace("\", "\\").Replace('"', '\"')

function New-BudgetAlertJson([int]$Threshold, [string]$Type, [string]$Address) {
    return ('{{"Notification":{{"NotificationType":"{0}","ComparisonOperator":"GREATER_THAN","Threshold":{1},"ThresholdType":"PERCENTAGE"}},"Subscribers":[{{"SubscriptionType":"EMAIL","Address":"{2}"}}]}}' -f $Type, $Threshold, $Address)
}

$budgetJson = '{' +
    '"BudgetName":"' + $script:BudgetName + '",' +
    '"BudgetType":"COST",' +
    '"TimeUnit":"MONTHLY",' +
    '"BudgetLimit":{"Amount":"' + $script:BudgetAmountUsd + '","Unit":"USD"},' +
    '"TimePeriod":{"Start":' + $start + ',"End":3706473600},' +
    '"CostTypes":{"IncludeCredit":true,"IncludeDiscount":true,"IncludeOtherSubscription":true,"IncludeRecurring":true,"IncludeRefund":true,"IncludeSubscription":true,"IncludeSupport":true,"IncludeTax":true,"IncludeUpfront":true,"UseBlended":false}' +
    '}'

$alertsJson = '[' +
    (New-BudgetAlertJson 50 "ACTUAL" $emailEsc) + ',' +
    (New-BudgetAlertJson 80 "ACTUAL" $emailEsc) + ',' +
    (New-BudgetAlertJson 100 "ACTUAL" $emailEsc) + ',' +
    (New-BudgetAlertJson 100 "FORECASTED" $emailEsc) +
    ']'

$budgetPath = Join-Path $env:TEMP "edugest-budget.json"
$alertsPath = Join-Path $env:TEMP "edugest-budget-alerts.json"
[IO.File]::WriteAllText($budgetPath, $budgetJson, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($alertsPath, $alertsJson, [Text.UTF8Encoding]::new($false))

$created = Invoke-AwsCli budgets create-budget `
    --account-id $account `
    --budget (ConvertTo-AwsFileUri $budgetPath) `
    --notifications-with-subscribers (ConvertTo-AwsFileUri $alertsPath) `
    --region $script:Region
if ($created.Code -ne 0) { throw "create-budget fallo. $($created.Text)" }

Write-Host "Presupuesto $($script:BudgetName) = $($script:BudgetAmountUsd) USD/mes. Alertas a $Email (50/80/100% real, 100% forecast)." -ForegroundColor Green
Write-Host "AWS confirma el email la primera vez (bandeja / spam)." -ForegroundColor Yellow
Write-Host "Esto NO apaga EC2/RDS ni impide un NAT. Si el correo no llega, el tope no sirve." -ForegroundColor Yellow
