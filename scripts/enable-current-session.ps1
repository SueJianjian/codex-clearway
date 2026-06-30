$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "auto-env.ps1")
codex-proxy-enable
