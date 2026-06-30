$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$autoEnv = Join-Path $scriptDir "auto-env.ps1"

if (!(Test-Path $autoEnv)) {
    throw "auto-env.ps1 not found at $autoEnv"
}

$profilePath = $PROFILE
$profileDir = Split-Path -Parent $profilePath
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

if (Test-Path $profilePath) {
    $content = Get-Content -Raw $profilePath
} else {
    $content = ""
}

$begin = "# BEGIN codex-split-proxy"
$end = "# END codex-split-proxy"
$escapedAutoEnv = $autoEnv.Replace("'", "''")
$block = @"
$begin
`$codexSplitProxyAutoEnv = '$escapedAutoEnv'
if (Test-Path -LiteralPath `$codexSplitProxyAutoEnv) {
    . `$codexSplitProxyAutoEnv
}
$end
"@

$pattern = "(?s)\r?\n?# BEGIN codex-split-proxy.*?# END codex-split-proxy\r?\n?"
if ($content -match [regex]::Escape($begin)) {
    $content = [regex]::Replace($content, $pattern, "`r`n$block`r`n")
} else {
    if ($content -and !$content.EndsWith("`n")) { $content += "`r`n" }
    $content += "`r`n$block`r`n"
}

Set-Content -Encoding UTF8 $profilePath $content
Write-Host "Installed Codex Split Proxy auto mode into $profilePath"
