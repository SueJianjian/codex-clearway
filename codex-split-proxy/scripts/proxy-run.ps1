if (!$args -or $args.Count -eq 0) {
    throw "Usage: .\proxy-run.ps1 <command> [args...]"
}

$configPath = Join-Path $HOME ".codex-split-proxy\config.json"
if (!(Test-Path $configPath)) {
    throw "No proxy config found. Run codex-split-proxy.ps1 init <clash-subscription-url> first."
}

$config = Get-Content -Raw $configPath | ConvertFrom-Json
$env:HTTP_PROXY = "http://127.0.0.1:$($config.httpPort)"
$env:HTTPS_PROXY = "http://127.0.0.1:$($config.httpPort)"
$env:ALL_PROXY = "socks5://127.0.0.1:$($config.socksPort)"
$env:NO_PROXY = "localhost,127.0.0.1,::1,.local"

& $args[0] @($args | Select-Object -Skip 1)
exit $LASTEXITCODE
