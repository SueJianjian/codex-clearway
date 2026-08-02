$ErrorActionPreference = "Stop"

function Assert-True($Condition, [string]$Message) {
    if (!$Condition) { throw "Assertion failed: $Message" }
}

function Assert-False($Condition, [string]$Message) {
    if ($Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-clearway-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
$configPath = Join-Path $tempDir "config.json"
@{
    subscriptionUrl = "private-value"
    httpPort = 17890
    socksPort = 17891
} | ConvertTo-Json | Set-Content -Encoding UTF8 $configPath

$savedCodeShell = $env:CODEX_SHELL
$savedHttp = $env:HTTP_PROXY
$savedHttps = $env:HTTPS_PROXY
$savedAll = $env:ALL_PROXY
$savedNo = $env:NO_PROXY

try {
    Remove-Item Env:CODEX_SHELL -ErrorAction SilentlyContinue
    $global:CodexClearwayConfigPathOverride = $configPath
    $global:CodexClearwaySelectionVerified = $false
    $global:CodexClearwayManagerInvoker = {
        param($Manager, $Command)
        if ($Command -eq "select") { $global:CodexClearwaySelectCalls++ }
    }
    $global:CodexClearwaySelectCalls = 0

    . (Join-Path $PSScriptRoot "..\scripts\auto-env.ps1")
    $expectedManager = (Resolve-Path (Join-Path $PSScriptRoot "..\scripts\codex-split-proxy.ps1")).Path
    Assert-Equal $expectedManager (Get-CodexClearwayManagerPath) "manager path is captured when auto-env loads"
    codex-proxy-enable -Quiet
    codex-proxy-enable -Quiet
    Assert-Equal 1 $global:CodexClearwaySelectCalls "successful selection runs once per process"
    Assert-True $global:CodexClearwaySelectionVerified "success marker is set"
    Assert-Equal "http://127.0.0.1:17890" $env:HTTP_PROXY "HTTP proxy is exported after success"
    Assert-Equal "http://127.0.0.1:17890" $env:HTTPS_PROXY "HTTPS proxy is exported after success"
    Assert-Equal "socks5://127.0.0.1:17891" $env:ALL_PROXY "SOCKS proxy is exported after success"

    codex-proxy-refresh -Quiet
    Assert-Equal 2 $global:CodexClearwaySelectCalls "refresh forces another selection"

    $global:CodexClearwaySelectionVerified = $false
    $global:CodexClearwaySelectCalls = 0
    $global:CodexClearwayManagerInvoker = {
        param($Manager, $Command)
        if ($Command -eq "select") { $global:CodexClearwaySelectCalls++; throw "selection failed" }
    }
    $env:HTTP_PROXY = "preserve-http"
    $env:HTTPS_PROXY = "preserve-https"
    $env:ALL_PROXY = "preserve-all"
    $env:NO_PROXY = "preserve-no"

    codex-proxy-enable -Quiet
    Assert-False $global:CodexClearwaySelectionVerified "failed selection leaves marker false"
    Assert-Equal "preserve-http" $env:HTTP_PROXY "failed selection preserves HTTP proxy"
    Assert-Equal "preserve-https" $env:HTTPS_PROXY "failed selection preserves HTTPS proxy"
    Assert-Equal "preserve-all" $env:ALL_PROXY "failed selection preserves ALL_PROXY"
    Assert-Equal "preserve-no" $env:NO_PROXY "failed selection preserves NO_PROXY"
    codex-proxy-enable -Quiet
    Assert-Equal 2 $global:CodexClearwaySelectCalls "failed selection is retried"

    Write-Output "PASS auto-env"
} finally {
    $env:CODEX_SHELL = $savedCodeShell
    $env:HTTP_PROXY = $savedHttp
    $env:HTTPS_PROXY = $savedHttps
    $env:ALL_PROXY = $savedAll
    $env:NO_PROXY = $savedNo
    Remove-Variable CodexClearwayConfigPathOverride -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable CodexClearwaySelectionVerified -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable CodexClearwayManagerInvoker -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable CodexClearwaySelectCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $tempDir
}
