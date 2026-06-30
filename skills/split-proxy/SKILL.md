---
name: split-proxy
description: Start, stop, configure, and use a local mihomo split proxy for Codex terminal commands without changing Windows global proxy settings.
---

# Codex Clearway

Use this skill when the user wants Codex-launched terminal commands to access non-mainland-China networks through a proxy while mainland China and local network traffic goes direct.

## What This Plugin Does

- Uses `mihomo` as a local background proxy core.
- Stores private runtime config in `%USERPROFILE%\.codex-split-proxy`.
- Keeps the user's subscription URL out of plugin files and source control.
- Exposes HTTP proxy `127.0.0.1:7890` and SOCKS5 proxy `127.0.0.1:7891`.
- Does not modify Windows global proxy settings or registry values.
- Does not provide TUN mode.

## Commands

All commands are run from the plugin root:

```powershell
.\scripts\codex-split-proxy.ps1 status
```

Initialize with a Clash/mihomo-compatible subscription URL:

```powershell
.\scripts\codex-split-proxy.ps1 init <subscription-url>
```

Manage the background proxy:

```powershell
.\scripts\codex-split-proxy.ps1 start
.\scripts\codex-split-proxy.ps1 stop
.\scripts\codex-split-proxy.ps1 status
.\scripts\codex-split-proxy.ps1 update
```

Print PowerShell environment variables for the current shell:

```powershell
.\scripts\codex-split-proxy.ps1 env
```

Run one command through the proxy:

```powershell
.\scripts\codex-split-proxy.ps1 run git ls-remote https://github.com/openai/openai-python.git
```

or:

```powershell
.\scripts\proxy-run.ps1 npm view react version
.\scripts\proxy-run.ps1 curl.exe -I https://api.github.com
```

## Behavior Notes

- In Codex PowerShell terminals, `auto-env.ps1` can be loaded from the PowerShell profile to automatically start mihomo and export proxy environment variables.
- In an already-open Codex terminal, run `. .\scripts\enable-current-session.ps1` once from the plugin root to activate the current session.
- The subscription must be Clash/mihomo YAML with a `proxies:` section.
- If the subscription has `proxy-groups:`, those groups are preserved.
- If no `proxy-groups:` exists, the script creates a `Proxy` select group from detected proxy names.
- Generated rules add local/private-network direct rules, then preserve subscription rules. If the subscription has no rules, the fallback is `DOMAIN-SUFFIX,cn,DIRECT` and `MATCH,<proxy-group>`.
- If port `7890` or `7891` is already in use, startup fails with the owning process instead of killing it.
- If GitHub release downloads are unavailable, copy a compatible `mihomo.exe` to `%USERPROFILE%\.codex-split-proxy\bin\mihomo.exe`.
