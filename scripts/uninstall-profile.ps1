$ErrorActionPreference = "Stop"

$profilePath = $PROFILE
if (!(Test-Path $profilePath)) {
    Write-Host "PowerShell profile does not exist: $profilePath"
    return
}

$content = Get-Content -Raw $profilePath
$begin = "# BEGIN codex-split-proxy"
$end = "# END codex-split-proxy"

if ($content -notmatch [regex]::Escape($begin)) {
    Write-Host "Codex Split Proxy auto mode is not installed in $profilePath"
    return
}

$pattern = "(?s)\r?\n?# BEGIN codex-split-proxy.*?# END codex-split-proxy\r?\n?"
$content = [regex]::Replace($content, $pattern, "`r`n")
Set-Content -Encoding UTF8 $profilePath $content
Write-Host "Removed Codex Split Proxy auto mode from $profilePath"
