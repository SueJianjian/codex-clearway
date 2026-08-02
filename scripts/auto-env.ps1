$script:CodexClearwayPluginRoot = Split-Path -Parent $PSScriptRoot

function Get-CodexClearwayConfigPath {
    if ($global:CodexClearwayConfigPathOverride) { return $global:CodexClearwayConfigPathOverride }
    return Join-Path $HOME ".codex-split-proxy\config.json"
}

function Get-CodexClearwayManagerPath {
    return Join-Path $script:CodexClearwayPluginRoot "scripts\codex-split-proxy.ps1"
}

function Invoke-CodexClearwayManager($Manager, [string]$Command) {
    if ($global:CodexClearwayManagerInvoker) {
        return & $global:CodexClearwayManagerInvoker $Manager $Command
    }
    return & $Manager $Command
}

function global:codex-proxy-status {
    Invoke-CodexClearwayManager (Get-CodexClearwayManagerPath) "status"
}

function global:codex-proxy-stop {
    Invoke-CodexClearwayManager (Get-CodexClearwayManagerPath) "stop"
}

function global:codex-proxy-start {
    Invoke-CodexClearwayManager (Get-CodexClearwayManagerPath) "start"
}

function global:codex-proxy-refresh {
    param([switch]$Quiet)
    $global:CodexClearwaySelectionVerified = $false
    codex-proxy-enable -Quiet:$Quiet
}

function global:codex-proxy-enable {
    param(
        [switch]$Quiet
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $configPath = Get-CodexClearwayConfigPath
    if (!(Test-Path $configPath)) {
        $ErrorActionPreference = $previousErrorActionPreference
        return
    }

    $manager = Get-CodexClearwayManagerPath
    if (!(Test-Path $manager)) {
        $ErrorActionPreference = $previousErrorActionPreference
        return
    }

    try {
    $config = Get-Content -Raw $configPath | ConvertFrom-Json
    $httpPort = if ($config.httpPort) { [int]$config.httpPort } else { 7890 }
    $socksPort = if ($config.socksPort) { [int]$config.socksPort } else { 7891 }

    if ($global:CodexClearwaySelectionVerified -ne $true) {
        try {
            Invoke-CodexClearwayManager $manager "select" *> $null
            $global:CodexClearwaySelectionVerified = $true
        } catch {
            if (!$Quiet) { Write-Warning "Codex Clearway could not verify a GitHub route. Proxy variables were not changed." }
            return
        }
    }

    $env:HTTP_PROXY = "http://127.0.0.1:$httpPort"
    $env:HTTPS_PROXY = "http://127.0.0.1:$httpPort"
    $env:ALL_PROXY = "socks5://127.0.0.1:$socksPort"
    $env:NO_PROXY = "localhost,127.0.0.1,::1,.local"

        if (!$Quiet) {
            Write-Host "Codex Clearway enabled for this PowerShell session: 127.0.0.1:$httpPort"
        }
    } catch {
        return
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

if ($env:CODEX_SHELL -eq "1") {
    codex-proxy-enable -Quiet
}
