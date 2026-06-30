function global:codex-proxy-enable {
    param(
        [switch]$Quiet
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $configPath = Join-Path $HOME ".codex-split-proxy\config.json"
    if (!(Test-Path $configPath)) {
        $ErrorActionPreference = $previousErrorActionPreference
        return
    }

    $pluginRoot = Split-Path -Parent (Split-Path -Parent $script:MyInvocation.MyCommand.Path)
    $manager = Join-Path $pluginRoot "scripts\codex-split-proxy.ps1"
    if (!(Test-Path $manager)) {
        $ErrorActionPreference = $previousErrorActionPreference
        return
    }

    try {
    $config = Get-Content -Raw $configPath | ConvertFrom-Json
    $httpPort = if ($config.httpPort) { [int]$config.httpPort } else { 7890 }
    $socksPort = if ($config.socksPort) { [int]$config.socksPort } else { 7891 }

    $httpListening = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $httpPort -State Listen -ErrorAction SilentlyContinue
    $socksListening = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $socksPort -State Listen -ErrorAction SilentlyContinue
    if (!$httpListening -or !$socksListening) {
        & $manager start *> $null
        Start-Sleep -Milliseconds 500
    }

    $env:HTTP_PROXY = "http://127.0.0.1:$httpPort"
    $env:HTTPS_PROXY = "http://127.0.0.1:$httpPort"
    $env:ALL_PROXY = "socks5://127.0.0.1:$socksPort"
    $env:NO_PROXY = "localhost,127.0.0.1,::1,.local"

    function global:codex-proxy-status {
        & $manager status
    }

    function global:codex-proxy-stop {
        & $manager stop
    }

    function global:codex-proxy-start {
        & $manager start
    }

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
