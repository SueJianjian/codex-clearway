# Per-Session Node Selection Design

## Goal

Before a Codex PowerShell session exports proxy environment variables, test every eligible subscription node against `https://api.github.com`, select the available node with the lowest measured latency, switch the primary proxy group to that node, and verify the selected route. Repeat this process once for every new Codex PowerShell session.

## Scope

This change extends Codex Clearway's existing Windows PowerShell and mihomo workflow. It does not modify Windows global proxy settings, registry proxy settings, or TUN configuration. The subscription URL and mihomo controller secret remain in the private runtime directory under `%USERPROFILE%\.codex-split-proxy` and must never be printed or committed.

## Architecture

The generated mihomo configuration will expose a REST controller on a configurable port bound only to `127.0.0.1`. Initialization will generate a controller secret and store it in the private JSON configuration. Existing installations without these fields will receive conservative defaults during update or start without exposing the controller to the LAN.

The proxy manager will provide a node-selection command used by `auto-env.ps1`. That command will:

1. Ensure the managed mihomo process is running.
2. Query the local controller for proxy groups and their members.
3. Resolve the primary selectable group used by the routing rules.
4. Build a list containing only real selectable nodes, excluding groups and special entries such as `DIRECT` and `REJECT`.
5. Measure every candidate against `https://api.github.com` with a bounded timeout and bounded concurrency.
6. Select the successful candidate with the lowest latency.
7. Switch the primary group to that candidate.
8. Make a final GitHub API request through the local HTTP proxy.
9. Report success only after final verification passes.

Controller requests will authenticate with the local secret. The generated configuration will remain bound to loopback and will not enable LAN access.

## Session Behavior

`auto-env.ps1` will keep an in-memory global variable scoped to the current PowerShell process. On the first `codex-proxy-enable` call in a Codex session, it will run selection and verification before exporting `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY`.

After a successful selection, subsequent enable calls in the same PowerShell process will reuse the verified selection and skip testing. A new PowerShell process has no marker and therefore performs a fresh full test. A failed attempt will not set the success marker, allowing an explicit retry in the same session.

Manual start remains available and starts mihomo without claiming that a route has been verified. Manual enable follows the same selection gate as automatic enable.

## Failure Handling

The selector will use explicit timeouts so a dead node cannot block session startup indefinitely. Individual node failures will be recorded only by node name and normalized error category; sensitive proxy configuration and subscription data will not be logged.

If the controller cannot be reached, no eligible nodes exist, all tests fail, switching fails, or the final proxied GitHub request fails, proxy environment variables will not be exported. The command will return a nonzero result and show a concise actionable message. It will not silently retain an unverified route or fall back to direct access.

If configured listener or controller ports are occupied by an unrelated process, startup will stop and identify the conflicting process without terminating it.

## Initialization And Migration

Initialization writes the user-provided subscription URL only to the private runtime configuration, downloads the subscription, generates the mihomo configuration, and installs mihomo if needed. Existing configuration files are migrated by adding missing controller settings and a generated secret while preserving the subscription URL and configured proxy ports.

The first setup is performed while the user's existing proxy software remains available. If default listener ports conflict, the Clearway runtime configuration will use verified free loopback ports and regenerate the mihomo configuration. After Clearway passes its own proxied GitHub check, the user can close the existing proxy application and repeat the session-start test.

## Verification

Automated checks will cover:

- Generated mihomo controller binding and authentication.
- Migration of existing private configuration without replacing user values.
- Primary-group discovery and exclusion of groups and special entries.
- Selection of the lowest-latency successful node.
- Partial failures and all-nodes-failed behavior.
- Final GitHub verification as a prerequisite for environment export.
- One successful test per PowerShell process and retry after failure.
- Listener and controller port-conflict reporting.
- PowerShell syntax and plugin manifest validation.

End-to-end verification will initialize with the private subscription, start the managed mihomo process, select a route, and request the GitHub API through Clearway. The same check will then be repeated in a new Codex PowerShell session after the existing GUI proxy application is closed. Success means the GitHub API responds through Clearway, a new session performs a fresh selection, the Windows global proxy remains unchanged, and no subscription credential appears in repository changes or reported output.
