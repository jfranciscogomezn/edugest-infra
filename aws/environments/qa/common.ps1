# Helpers compartidos. PowerShell 5.1 trata stderr de aws.exe como error fatal
# si ErrorActionPreference=Stop. Toda llamada aws debe pasar por Invoke-AwsCli.

function Get-SingleText([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "" }
    $first = $Raw -split '\s+' |
        Where-Object { $_ -and $_ -ne "None" -and $_ -ne "null" } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($first)) { return "" }
    return $first.Trim()
}

function ConvertTo-AwsFileUri([string]$Path) {
    return "file://" + $Path.Replace("\", "/")
}

function Invoke-AwsCli {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = & aws @AwsArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $stdoutBits = New-Object System.Collections.Generic.List[string]
    $allBits = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($raw)) {
        $line = "$item"
        [void]$allBits.Add($line)
        if ($item -isnot [System.Management.Automation.ErrorRecord]) {
            [void]$stdoutBits.Add($line)
        }
    }
    if ($null -eq $code) { $code = 1 }
    $stdout = [string]($stdoutBits -join "`n")
    $all = [string]($allBits -join "`n")
    return [pscustomobject]@{
        Code   = [int]$code
        Out    = Get-SingleText $stdout
        StdOut = $stdout.Trim()
        Text   = $all.Trim()
    }
}

function Assert-AwsCli {
    $who = Invoke-AwsCli sts get-caller-identity --query Account --output text --region $script:Region
    if ($who.Code -ne 0 -or -not $who.Out) {
        throw "Credenciales AWS invalidas. $($who.Text)"
    }
    return $who.Out
}
