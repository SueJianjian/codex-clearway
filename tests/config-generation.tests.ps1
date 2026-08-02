$ErrorActionPreference = "Stop"

function Assert-True($Condition, [string]$Message) {
    if (!$Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Match([string]$Pattern, [string]$Actual, [string]$Message) {
    if ($Actual -notmatch $Pattern) { throw "Assertion failed: $Message" }
}

$env:CODEX_CLEARWAY_TEST_IMPORT = "1"
. (Join-Path $PSScriptRoot "..\scripts\codex-split-proxy.ps1")

$legacy = [pscustomobject]@{
    subscriptionUrl = "private-value"
    httpPort = 17890
    socksPort = 17891
}
$migrated = Merge-ConfigDefaults $legacy
Assert-Equal "private-value" $migrated.subscriptionUrl "migration preserves subscription"
Assert-Equal 17890 $migrated.httpPort "migration preserves HTTP port"
Assert-Equal 17891 $migrated.socksPort "migration preserves SOCKS port"
Assert-Equal 19090 $migrated.controllerPort "migration adds controller port"
Assert-True (-not [string]::IsNullOrWhiteSpace($migrated.controllerSecret)) "migration generates controller secret"
Assert-Equal "https://api.github.com" $migrated.testUrl "migration adds test URL"
Assert-Equal 5000 $migrated.testTimeoutMs "migration adds timeout"
Assert-Equal 6 $migrated.testConcurrency "migration adds concurrency"

$existing = [pscustomobject]@{
    subscriptionUrl = "private-value"
    httpPort = 17890
    socksPort = 17891
    controllerPort = 19999
    controllerSecret = "keep-me"
    testUrl = "https://example.test"
    testTimeoutMs = 2500
    testConcurrency = 3
}
$preserved = Merge-ConfigDefaults $existing
Assert-Equal 19999 $preserved.controllerPort "migration preserves controller port"
Assert-Equal "keep-me" $preserved.controllerSecret "migration preserves secret"
Assert-Equal "https://example.test" $preserved.testUrl "migration preserves test URL"
Assert-Equal 2500 $preserved.testTimeoutMs "migration preserves timeout"
Assert-Equal 3 $preserved.testConcurrency "migration preserves concurrency"

$sampleSubscription = @"
proxies:
  - name: sample
    type: socks5
    server: 127.0.0.2
    port: 1080
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - sample
rules:
  - MATCH,Proxy
"@
$yaml = Build-MihomoConfig $sampleSubscription 17890 17891 19090 "a'b"
Assert-Match "(?m)^external-controller: 127\.0\.0\.1:19090$" $yaml "controller is loopback-only"
Assert-Match "(?m)^secret: 'a''b'$" $yaml "secret is YAML escaped"

Remove-Item Env:CODEX_CLEARWAY_TEST_IMPORT -ErrorAction SilentlyContinue
Write-Output "PASS config-generation"
