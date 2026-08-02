# Per-Session Node Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Test every eligible subscription node against the GitHub API once per Codex PowerShell session, select the lowest-latency available node, and export proxy variables only after an end-to-end verification succeeds.

**Architecture:** Extend the generated mihomo configuration with an authenticated loopback REST controller. Put controller discovery, delay testing, group switching, and final verification in a focused PowerShell module, while the existing manager owns configuration migration and process lifecycle and `auto-env.ps1` owns the per-process success marker.

**Tech Stack:** Windows PowerShell 5.1+, mihomo REST API, built-in `Invoke-RestMethod`, built-in `ConvertTo-Json`, repository-local PowerShell test harness.

## Global Constraints

- Bind proxy listeners and the REST controller only to `127.0.0.1`.
- Do not modify Windows global proxy settings, registry proxy settings, or TUN configuration.
- Keep the subscription URL and controller secret only under `%USERPROFILE%\.codex-split-proxy`; never print or commit them.
- Test `https://api.github.com` with bounded per-node timeouts and bounded concurrency.
- Do not export proxy environment variables unless node selection and the final proxied GitHub request both succeed.
- Test once after each successful selection per PowerShell process; allow retry after failure.
- Add no external PowerShell module or runtime dependency.

---

### Task 1: Private Configuration Migration And Controller Config

**Files:**
- Modify: `scripts/codex-split-proxy.ps1`
- Create: `tests/config-generation.tests.ps1`

**Interfaces:**
- Produces: runtime config properties `controllerPort: int`, `controllerSecret: string`, `testUrl: string`, `testTimeoutMs: int`, and `testConcurrency: int`.
- Produces: generated mihomo keys `external-controller: 127.0.0.1:<port>` and `secret: '<escaped-secret>'`.
- Produces: manager command `migrate-config`, used internally by `init`, `update`, `start`, and `select`.

- [ ] **Step 1: Write failing configuration tests**

Create a test harness that imports manager functions under a test-only dot-source guard and asserts that migration preserves `subscriptionUrl`, `httpPort`, and `socksPort`, adds all five new fields, generates a non-empty secret when absent, preserves an existing secret, and emits loopback-only controller YAML with the secret single-quote escaped.

```powershell
$migrated = Merge-ConfigDefaults ([pscustomobject]@{
    subscriptionUrl = 'private-value'
    httpPort = 17890
    socksPort = 17891
})
Assert-Equal 'private-value' $migrated.subscriptionUrl
Assert-Equal 19090 $migrated.controllerPort
Assert-True (-not [string]::IsNullOrWhiteSpace($migrated.controllerSecret))
Assert-Equal 'https://api.github.com' $migrated.testUrl
Assert-Equal 5000 $migrated.testTimeoutMs
Assert-Equal 6 $migrated.testConcurrency

$yaml = Build-MihomoConfig $sampleSubscription 17890 17891 19090 "a'b"
Assert-Match '(?m)^external-controller: 127\.0\.0\.1:19090$' $yaml
Assert-Match "(?m)^secret: 'a''b'$" $yaml
```

- [ ] **Step 2: Run the test and verify failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\config-generation.tests.ps1`

Expected: nonzero exit because `Merge-ConfigDefaults` and the extended `Build-MihomoConfig` signature do not exist.

- [ ] **Step 3: Implement migration and generated controller settings**

Add defaults with exact values `19090`, `https://api.github.com`, `5000`, and `6`. Generate the secret with 32 random bytes encoded as lowercase hexadecimal. Make `Read-JsonConfig` merge missing properties without overwriting existing values. Update `Build-MihomoConfig` to accept controller port and secret and emit:

```yaml
external-controller: 127.0.0.1:19090
secret: '<single-quote-escaped secret>'
```

Make `init`, `update`, and `start` persist migrated private configuration before generating or launching mihomo. Check controller-port ownership along with HTTP and SOCKS ports.

- [ ] **Step 4: Run focused tests and syntax validation**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\config-generation.tests.ps1
powershell.exe -NoProfile -Command "[void][scriptblock]::Create((Get-Content -Raw '.\scripts\codex-split-proxy.ps1'))"
```

Expected: tests print `PASS config-generation`; parser exits 0.

- [ ] **Step 5: Commit**

```powershell
git add scripts/codex-split-proxy.ps1 tests/config-generation.tests.ps1
git commit -m "feat: add private mihomo controller configuration"
```

### Task 2: Node Discovery, Delay Testing, Switching, And Verification

**Files:**
- Create: `scripts/proxy-selection.ps1`
- Create: `tests/proxy-selection.tests.ps1`
- Modify: `scripts/codex-split-proxy.ps1`

**Interfaces:**
- Consumes: migrated controller settings from Task 1.
- Produces: `Invoke-ProxySelection -Config <pscustomobject> -HttpPort <int>` returning `{ Success: bool; Node: string; Delay: int; Error: string }`.
- Produces: manager command `select` that starts mihomo if required and exits nonzero unless selection and final verification succeed.

- [ ] **Step 1: Write failing selection tests using injected REST and verification callbacks**

Cover these exact cases: nested proxy groups are excluded from candidates; `DIRECT`, `REJECT`, `REJECT-DROP`, `PASS`, and `COMPATIBLE` are excluded case-insensitively; failed and timed-out delay calls are ignored; the lowest successful delay wins; the primary group receives a PUT request containing the selected node; failed final verification returns `Success = $false`; and an all-failed set returns a non-sensitive error without issuing a switch.

```powershell
$result = Invoke-ProxySelection -Config $config -HttpPort 17890 `
    -RestInvoker $fakeRest -ProxyVerifier $fakeVerify
Assert-True $result.Success
Assert-Equal 'fast-node' $result.Node
Assert-Equal 42 $result.Delay
Assert-Equal 'fast-node' $capturedSwitch.name
```

- [ ] **Step 2: Run the test and verify failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\proxy-selection.tests.ps1`

Expected: nonzero exit because `scripts/proxy-selection.ps1` does not exist.

- [ ] **Step 3: Implement the selector**

Use the mihomo endpoints `GET /proxies`, `GET /proxies/{name}/delay?url=<encoded>&timeout=<ms>`, and `PUT /proxies/{group}` with JSON `{ "name": "<node>" }`. Send `Authorization: Bearer <secret>` on every request. Determine the primary group from the generated routing target, recursively classify group members using the `/proxies` response, and retain only terminal proxy nodes. URL-encode every proxy and group name.

Use a runspace pool capped at `testConcurrency` for delay requests. Collect only positive integer delays, sort by delay and then node name for deterministic ties, switch the primary group, and verify with `Invoke-WebRequest -UseBasicParsing -Proxy http://127.0.0.1:<httpPort> -Uri <testUrl> -TimeoutSec <ceiling(testTimeoutMs/1000)>`. Return normalized errors that contain no controller secret, subscription URL, node configuration, or REST response body.

Add `select` to the manager command set. It must call `start`, invoke the selector, print selected node and delay on success, and exit nonzero on failure.

- [ ] **Step 4: Run focused tests and syntax validation**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\proxy-selection.tests.ps1
powershell.exe -NoProfile -Command "Get-ChildItem .\scripts\*.ps1 | ForEach-Object { [void][scriptblock]::Create((Get-Content -Raw $_.FullName)) }"
```

Expected: tests print `PASS proxy-selection`; all scripts parse successfully.

- [ ] **Step 5: Commit**

```powershell
git add scripts/proxy-selection.ps1 scripts/codex-split-proxy.ps1 tests/proxy-selection.tests.ps1
git commit -m "feat: select the fastest working proxy node"
```

### Task 3: Per-Session Enable Gate

**Files:**
- Modify: `scripts/auto-env.ps1`
- Modify: `scripts/enable-current-session.ps1`
- Create: `tests/auto-env.tests.ps1`
- Modify: `README.md`
- Modify: `skills/split-proxy/SKILL.md`

**Interfaces:**
- Consumes: manager command `select` from Task 2.
- Produces: global session marker `$global:CodexClearwaySelectionVerified` set to `$true` only after `select` exits 0.
- Produces: `codex-proxy-refresh`, which clears the marker and reruns selection explicitly.

- [ ] **Step 1: Write failing session-gate tests**

Load `auto-env.ps1` with automatic startup suppressed, inject a fake manager invoker, and assert: the first enable calls `select` once before setting environment variables; a second enable in the same process does not call it again; a failed first selection leaves all proxy variables unchanged and does not set the marker; a second call after failure retries; and refresh clears the marker and causes another selection.

```powershell
codex-proxy-enable -Quiet
codex-proxy-enable -Quiet
Assert-Equal 1 $script:selectCalls
Assert-True $global:CodexClearwaySelectionVerified
Assert-Equal 'http://127.0.0.1:17890' $env:HTTP_PROXY
```

- [ ] **Step 2: Run the test and verify failure**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\auto-env.tests.ps1`

Expected: nonzero exit because enable currently starts the proxy without selection or a success marker.

- [ ] **Step 3: Implement the session gate and documentation**

Make `codex-proxy-enable` call manager `select` unless `$global:CodexClearwaySelectionVerified -eq $true`. Export all four proxy variables only after a zero exit code, then set the marker. Preserve existing proxy environment values on failure. Define `codex-proxy-refresh` to clear the marker and call enable. Ensure automatic mode remains gated by `CODEX_SHELL=1` and `enable-current-session.ps1` uses the same function.

Update README and the skill instructions with the once-per-session behavior, GitHub API target, refresh helper, failure behavior, controller loopback guarantee, initialization instructions, and the requirement to keep the existing GUI proxy running until standalone verification passes.

- [ ] **Step 4: Run focused and aggregate tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\auto-env.tests.ps1
Get-ChildItem .\tests\*.tests.ps1 | ForEach-Object { powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
```

Expected: each test prints a `PASS` line and the aggregate command exits 0.

- [ ] **Step 5: Commit**

```powershell
git add scripts/auto-env.ps1 scripts/enable-current-session.ps1 tests/auto-env.tests.ps1 README.md skills/split-proxy/SKILL.md
git commit -m "feat: verify the fastest node once per Codex session"
```

### Task 4: Private Initialization, Plugin Refresh, And End-To-End Verification

**Files:**
- Modify locally only: `%USERPROFILE%\.codex-split-proxy\config.json`
- Modify via helper: `.codex-plugin/plugin.json`

**Interfaces:**
- Consumes: all commands and session behavior from Tasks 1-3.
- Produces: an initialized and reinstalled local plugin with a verified standalone route.

- [ ] **Step 1: Run repository safety and validation checks**

Run:

```powershell
git diff --check
git status --short
powershell.exe -NoProfile -Command "Get-ChildItem .\scripts\*.ps1,.\tests\*.ps1 | ForEach-Object { [void][scriptblock]::Create((Get-Content -Raw $_.FullName)) }"
python C:\Users\Administrator\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py C:\Users\Administrator\plugins\codex-split-proxy
```

Expected: no whitespace errors, only intended tracked changes, all scripts parse, plugin validation passes.

- [ ] **Step 2: Initialize private runtime and handle port conflicts**

Call `init` with the user-provided private URL through an in-memory PowerShell variable so the URL is not printed by the script. Before startup, inspect `7890`, `7891`, and `19090`. If another process owns a default port, choose free loopback ports in the private config, regenerate, and recheck them without stopping the owning process.

- [ ] **Step 3: Verify selection while the existing proxy remains available**

Run `select`, then request `https://api.github.com` through the configured Clearway HTTP listener. Confirm a successful HTTP response, a selected node and positive delay, and no Windows global proxy or registry modification.

- [ ] **Step 4: Refresh the plugin cache and reinstall**

Run:

```powershell
python C:\Users\Administrator\.codex\skills\.system\plugin-creator\scripts\update_plugin_cachebuster.py C:\Users\Administrator\plugins\codex-split-proxy
python C:\Users\Administrator\.codex\skills\.system\plugin-creator\scripts\read_marketplace_name.py
codex plugin add codex-split-proxy@personal
codex plugin list
```

Expected: the cachebuster changes once, reinstall succeeds from the personal marketplace, and the plugin is enabled.

- [ ] **Step 5: Verify without the existing GUI proxy**

Ask the user to close the existing proxy application only after Step 3 succeeds. In a new Codex PowerShell process, load `auto-env.ps1`, confirm selection runs once, and request the GitHub API. Start a second new process and confirm it performs a fresh selection. Success requires both requests to pass through Clearway while Windows global proxy remains unchanged.

- [ ] **Step 6: Final secret scan and commit plugin metadata**

Search tracked files for the subscription host, URL-shaped secrets, `subscriptionUrl` values, and controller-secret values without printing matching secret text. Confirm runtime files remain outside the repository, then commit only the cachebuster metadata:

```powershell
git add .codex-plugin/plugin.json
git commit -m "chore: refresh Codex Clearway plugin cache"
```
