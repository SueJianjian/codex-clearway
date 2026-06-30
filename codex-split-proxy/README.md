# Codex Split Proxy

Local Codex plugin for running Codex-launched terminal commands through a mihomo split proxy.

It is designed for Windows PowerShell. It does not change Windows global proxy settings and does not require opening a GUI proxy client.

## Requirements

- Windows PowerShell
- A Clash/mihomo-compatible subscription URL
- A compatible `mihomo.exe`

## Quick Start

```powershell
.\scripts\codex-split-proxy.ps1 init <clash-subscription-url>
.\scripts\codex-split-proxy.ps1 start
.\scripts\proxy-run.ps1 curl.exe -I https://api.github.com
```

To print proxy environment variables for the current shell:

```powershell
.\scripts\codex-split-proxy.ps1 env
```

Runtime data is stored under `%USERPROFILE%\.codex-split-proxy`.
Do not commit that runtime directory. It may contain subscription URLs, generated proxy configs, and provider secrets.

## Codex Auto Mode

This plugin can be loaded from the Windows PowerShell profile and is gated by `CODEX_SHELL=1`.
When a Codex terminal starts, it automatically starts mihomo if needed and exports:

```powershell
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
ALL_PROXY=socks5://127.0.0.1:7891
NO_PROXY=localhost,127.0.0.1,::1,.local
```

Helper commands in Codex terminals:

```powershell
codex-proxy-enable
codex-proxy-status
codex-proxy-start
codex-proxy-stop
```

For an already-open Codex terminal, run this once:

```powershell
. .\scripts\enable-current-session.ps1
```

To install auto mode into your PowerShell profile:

```powershell
.\scripts\install-profile.ps1
```

Auto mode is gated by `CODEX_SHELL=1`, so it only activates inside Codex-launched PowerShell terminals.

If GitHub release downloads are unavailable, place a compatible mihomo executable at:

```powershell
%USERPROFILE%\.codex-split-proxy\bin\mihomo.exe
```

## Security Notes

- Do not publish your subscription URL.
- Do not publish generated `mihomo.yaml` or `subscription.yaml`.
- Do not publish `%USERPROFILE%\.codex-split-proxy`.
- Review your generated config before sharing logs or screenshots.
