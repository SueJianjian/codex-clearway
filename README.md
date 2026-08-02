# Codex Clearway

Run Codex-launched Windows PowerShell commands through a local `mihomo` split proxy without changing Windows global proxy settings or opening a GUI proxy client.

This project is a local Codex plugin plus a small set of PowerShell scripts. It is meant for commands started from Codex terminals, such as `git`, `npm`, `pip`, `curl.exe`, build scripts, package managers, and other CLI tools that honor standard proxy environment variables.

## What It Does

- Starts `mihomo` in the background on `127.0.0.1`.
- Exposes HTTP proxy `127.0.0.1:7890`.
- Exposes SOCKS5 proxy `127.0.0.1:7891`.
- Uses your Clash/mihomo-compatible subscription.
- Preserves subscription proxy groups and routing rules.
- Adds local/private-network direct rules before subscription rules.
- Automatically injects proxy environment variables in Codex PowerShell terminals.
- Tests every eligible node against `https://api.github.com` once per Codex PowerShell session and selects the lowest-latency working node.
- Does not modify Windows global proxy settings.
- Does not write registry proxy settings.
- Does not enable TUN mode.

## Requirements

- Windows PowerShell 5.1 or newer.
- A Clash/mihomo-compatible subscription URL.
- A compatible `mihomo.exe`.

The script can try to download `mihomo` from GitHub releases. If GitHub release downloads are blocked or unstable in your network, place a compatible executable here:

```powershell
%USERPROFILE%\.codex-split-proxy\bin\mihomo.exe
```

If you already have Clash Verge or another mihomo-based client installed, you can usually copy its `mihomo.exe` or `verge-mihomo.exe` to that path and rename it to `mihomo.exe`.

## Install

Clone the repository and enter it:

```powershell
git clone <this-repository-url> codex-split-proxy
cd codex-split-proxy
```

Initialize with your subscription URL:

```powershell
.\scripts\codex-split-proxy.ps1 init "<your-clash-subscription-url>"
```

Start the local proxy:

```powershell
.\scripts\codex-split-proxy.ps1 start
```

Verify it:

```powershell
.\scripts\codex-split-proxy.ps1 status
.\scripts\proxy-run.ps1 curl.exe -I https://api.github.com
```

Expected result: `curl.exe` should show an HTTP response from GitHub, usually `200 OK`.

## Enable Automatic Codex Mode

Install auto mode into your PowerShell profile:

```powershell
.\scripts\install-profile.ps1
```

Auto mode is gated by `CODEX_SHELL=1`, so it only activates inside Codex-launched PowerShell terminals. It will not change normal Windows PowerShell windows unless they also set `CODEX_SHELL=1`.

After installing auto mode, open a new Codex terminal. The following variables are set automatically:

```powershell
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
ALL_PROXY=socks5://127.0.0.1:7891
NO_PROXY=localhost,127.0.0.1,::1,.local
```

Then use normal commands directly:

```powershell
git clone https://github.com/example/project.git
npm install
pip install requests
curl.exe -I https://api.github.com
```

Before those variables are exported, Clearway starts mihomo, tests all eligible terminal nodes through the loopback-only controller, switches the primary selectable group to the fastest successful node, and verifies the GitHub API through the selected route. If selection or final verification fails, the existing environment variables are left unchanged.

For an already-open Codex terminal, activate the current session once:

```powershell
. .\scripts\enable-current-session.ps1
```

## Daily Commands

Show status:

```powershell
.\scripts\codex-split-proxy.ps1 status
```

Start:

```powershell
.\scripts\codex-split-proxy.ps1 start
```

Stop:

```powershell
.\scripts\codex-split-proxy.ps1 stop
```

Refresh subscription and regenerate the mihomo config:

```powershell
.\scripts\codex-split-proxy.ps1 update
```

Print proxy environment variables for manual use:

```powershell
.\scripts\codex-split-proxy.ps1 env
```

Run one command through the proxy without auto mode:

```powershell
.\scripts\proxy-run.ps1 npm view react version
.\scripts\proxy-run.ps1 curl.exe -I https://api.github.com
```

Inside Codex terminals with auto mode installed, helper commands are also available:

```powershell
codex-proxy-enable
codex-proxy-status
codex-proxy-start
codex-proxy-stop
codex-proxy-refresh
```

`codex-proxy-refresh` clears the current PowerShell process's success marker and performs a fresh full node test. A new Codex PowerShell process always starts without the marker and therefore tests again.

## Runtime Files

Runtime data is stored outside the repository:

```powershell
%USERPROFILE%\.codex-split-proxy
```

Important files:

- `config.json`: private settings, including your subscription URL.
- `subscription.yaml`: cached subscription response.
- `mihomo.yaml`: generated mihomo config.
- `mihomo.log`: mihomo stdout log.
- `mihomo.err.log`: mihomo stderr log.
- `mihomo.pid`: managed mihomo process id.
- `bin\mihomo.exe`: local mihomo executable.

Do not publish this runtime directory. It can contain provider secrets.

## Routing Behavior

The generated config:

- Binds proxy listeners to `127.0.0.1`.
- Binds the authenticated mihomo REST controller to `127.0.0.1`.
- Disables LAN exposure.
- Preserves `proxies:` from the subscription.
- Preserves `proxy-groups:` from the subscription when present.
- Creates a fallback `Proxy` group only if the subscription has no groups.
- Adds local/private network direct rules.
- Preserves subscription `rules:` after the local/private rules.
- Falls back to `DOMAIN-SUFFIX,cn,DIRECT` plus `MATCH,<proxy-group>` only when the subscription has no rules.

This means mainland-China direct behavior mainly follows the subscription's own rules. If a subscription has weak or incorrect rules, routing quality will reflect that.

## Troubleshooting

### `The subscription does not look like Clash/mihomo YAML`

Your subscription endpoint may be returning a non-Clash format. Use a Clash/mihomo subscription URL, or adjust provider settings so the subscription returns YAML with a `proxies:` section.

### GitHub download of `mihomo` fails

Manually place a compatible executable at:

```powershell
%USERPROFILE%\.codex-split-proxy\bin\mihomo.exe
```

Then run:

```powershell
.\scripts\codex-split-proxy.ps1 start
```

### Port `7890`, `7891`, or `19090` is already in use

Run:

```powershell
.\scripts\codex-split-proxy.ps1 status
```

The script reports the owning process when it detects a port conflict during startup. Stop the conflicting process or edit `%USERPROFILE%\.codex-split-proxy\config.json` to use different ports, then run:

```powershell
.\scripts\codex-split-proxy.ps1 update
.\scripts\codex-split-proxy.ps1 start
```

### Auto mode does not affect an already-open terminal

Run this once in that terminal:

```powershell
. .\scripts\enable-current-session.ps1
```

New Codex terminals will load auto mode through the PowerShell profile.

### No node passes the GitHub test

Keep the existing GUI proxy running while initializing Clearway, refresh the subscription, and retry:

```powershell
.\scripts\codex-split-proxy.ps1 update
codex-proxy-refresh
```

Only close the existing GUI proxy after Clearway has selected a node and successfully requested the GitHub API through its own HTTP listener.

### A command still does not use the proxy

Most CLI tools honor `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY`, but not all do. Check:

```powershell
$env:HTTP_PROXY
$env:HTTPS_PROXY
$env:ALL_PROXY
```

If they are set and the command still ignores the proxy, configure that tool's own proxy settings.

## Uninstall

Stop the managed mihomo process:

```powershell
.\scripts\codex-split-proxy.ps1 stop
```

Remove Clearway auto mode from your PowerShell profile:

```powershell
.\scripts\uninstall-profile.ps1
```

Optional: remove runtime files:

```powershell
Remove-Item -Recurse -Force "$HOME\.codex-split-proxy"
```

## Security Notes

- Do not publish your subscription URL.
- Do not publish generated `mihomo.yaml` or `subscription.yaml`.
- Do not publish the controller secret stored in `config.json`.
- Do not publish `%USERPROFILE%\.codex-split-proxy`.
- Do not paste logs that include provider secrets.
- Review generated configs before sharing screenshots or bug reports.

## Repository Hygiene

The repository `.gitignore` excludes common runtime files, but runtime files are designed to live under `%USERPROFILE%\.codex-split-proxy`, outside the repository.

Before publishing forks, scan for secrets:

```powershell
Select-String -Path (Get-ChildItem -Recurse -File | Select-Object -ExpandProperty FullName) -Pattern 'token=|password:|subscription|mihomo.yaml|subscription.yaml'
```
