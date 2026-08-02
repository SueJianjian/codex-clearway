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

. (Join-Path $PSScriptRoot "..\scripts\proxy-selection.ps1")

$config = [pscustomobject]@{
    controllerPort = 19090
    controllerSecret = "local-secret"
    testUrl = "https://api.github.com"
    testTimeoutMs = 5000
    testConcurrency = 3
}

$proxyResponse = [pscustomobject]@{
    proxies = [pscustomobject]@{
        "Main Group" = [pscustomobject]@{ type = "Selector"; all = @("Nested Group", "slow-node", "DIRECT", "REJECT-DROP") }
        "Nested Group" = [pscustomobject]@{ type = "URLTest"; all = @("fast-node", "failed-node", "PASS", "COMPATIBLE") }
        "fast-node" = [pscustomobject]@{ type = "Shadowsocks" }
        "slow-node" = [pscustomobject]@{ type = "Trojan" }
        "failed-node" = [pscustomobject]@{ type = "Vmess" }
        "DIRECT" = [pscustomobject]@{ type = "Direct" }
        "REJECT-DROP" = [pscustomobject]@{ type = "RejectDrop" }
        "PASS" = [pscustomobject]@{ type = "Pass" }
        "COMPATIBLE" = [pscustomobject]@{ type = "Compatible" }
    }
}

$script:capturedSwitch = $null
$rest = {
    param($Method, $Uri, $Headers, $Body)
    if ($Method -eq "GET" -and $Uri -match "/proxies$") { return $proxyResponse }
    if ($Method -eq "GET" -and $Uri -match "/delay\?") {
        if ($Uri -match "fast-node") { return [pscustomobject]@{ delay = 42 } }
        if ($Uri -match "slow-node") { return [pscustomobject]@{ delay = 180 } }
        throw "timeout"
    }
    if ($Method -eq "PUT") {
        $script:capturedSwitch = $Body | ConvertFrom-Json
        return $null
    }
    throw "Unexpected REST call: $Method $Uri"
}

$result = Invoke-ProxySelection -Config $config -HttpPort 17890 -RestInvoker $rest -ProxyVerifier { param($Proxy, $Uri, $TimeoutSec) return $true }
Assert-True $result.Success "selection succeeds"
Assert-Equal "fast-node" $result.Node "lowest delay node wins"
Assert-Equal 42 $result.Delay "reported delay matches"
Assert-Equal "fast-node" $script:capturedSwitch.name "selector switches primary group"

$verificationFailure = Invoke-ProxySelection -Config $config -HttpPort 17890 -RestInvoker $rest -ProxyVerifier { return $false }
Assert-False $verificationFailure.Success "final verification is required"
Assert-True ($verificationFailure.Error -match "verification") "verification error is normalized"

$script:switchCount = 0
$allFailedRest = {
    param($Method, $Uri, $Headers, $Body)
    if ($Method -eq "GET" -and $Uri -match "/proxies$") { return $proxyResponse }
    if ($Method -eq "GET" -and $Uri -match "/delay\?") { throw "secret response body" }
    if ($Method -eq "PUT") { $script:switchCount++; return $null }
}
$allFailed = Invoke-ProxySelection -Config $config -HttpPort 17890 -RestInvoker $allFailedRest -ProxyVerifier { return $true }
Assert-False $allFailed.Success "all failed nodes returns failure"
Assert-Equal 0 $script:switchCount "all failed nodes does not switch"
Assert-False ($allFailed.Error -match "secret response body|local-secret") "error omits sensitive details"

Write-Output "PASS proxy-selection"
