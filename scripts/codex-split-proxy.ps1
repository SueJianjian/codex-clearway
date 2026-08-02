param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "start", "stop", "status", "update", "env", "run", "config-path", "migrate-config")]
    [string]$Command = "status",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

$AppDir = Join-Path $HOME ".codex-split-proxy"
$BinDir = Join-Path $AppDir "bin"
$ConfigPath = Join-Path $AppDir "config.json"
$MihomoConfigPath = Join-Path $AppDir "mihomo.yaml"
$SubscriptionPath = Join-Path $AppDir "subscription.yaml"
$LogPath = Join-Path $AppDir "mihomo.log"
$ErrorLogPath = Join-Path $AppDir "mihomo.err.log"
$PidPath = Join-Path $AppDir "mihomo.pid"
$DefaultHttpPort = 7890
$DefaultSocksPort = 7891
$DefaultControllerPort = 19090
$DefaultTestUrl = "https://api.github.com"
$DefaultTestTimeoutMs = 5000
$DefaultTestConcurrency = 6
$MihomoVersion = "v1.19.13"
$MihomoZipUrl = "https://github.com/MetaCubeX/mihomo/releases/download/$MihomoVersion/mihomo-windows-amd64-$MihomoVersion.zip"

function Ensure-AppDir {
    New-Item -ItemType Directory -Force -Path $AppDir, $BinDir | Out-Null
}

function New-ControllerSecret {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-ConfigProperty($Config, [string]$Name, $Default) {
    $property = $Config.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value -and !($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))) {
        return $property.Value
    }
    return $Default
}

function Merge-ConfigDefaults($Config) {
    if ($null -eq $Config) { $Config = [pscustomobject]@{} }
    return [pscustomobject][ordered]@{
        subscriptionUrl = [string](Get-ConfigProperty $Config "subscriptionUrl" "")
        httpPort = [int](Get-ConfigProperty $Config "httpPort" $DefaultHttpPort)
        socksPort = [int](Get-ConfigProperty $Config "socksPort" $DefaultSocksPort)
        controllerPort = [int](Get-ConfigProperty $Config "controllerPort" $DefaultControllerPort)
        controllerSecret = [string](Get-ConfigProperty $Config "controllerSecret" (New-ControllerSecret))
        testUrl = [string](Get-ConfigProperty $Config "testUrl" $DefaultTestUrl)
        testTimeoutMs = [int](Get-ConfigProperty $Config "testTimeoutMs" $DefaultTestTimeoutMs)
        testConcurrency = [int](Get-ConfigProperty $Config "testConcurrency" $DefaultTestConcurrency)
    }
}

function Read-JsonConfig {
    if (!(Test-Path $ConfigPath)) {
        return Merge-ConfigDefaults $null
    }
    return Merge-ConfigDefaults (Get-Content -Raw $ConfigPath | ConvertFrom-Json)
}

function Write-JsonConfig($Config) {
    Ensure-AppDir
    $Config | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $ConfigPath
}

function Assert-Configured {
    $config = Read-JsonConfig
    if ([string]::IsNullOrWhiteSpace($config.subscriptionUrl)) {
        throw "No subscription is configured. Run: .\codex-split-proxy.ps1 init <clash-subscription-url>"
    }
    Write-JsonConfig $config
    return $config
}

function Find-Mihomo {
    $local = Get-ChildItem -Path $BinDir -Filter "mihomo*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($local) { return $local.FullName }

    $cmd = Get-Command "mihomo.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Install-Mihomo {
    Ensure-AppDir
    $existing = Find-Mihomo
    if ($existing) { return $existing }

    $zipPath = Join-Path $AppDir "mihomo.zip"
    $extractDir = Join-Path $AppDir "mihomo-download"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    Write-Host "Downloading mihomo $MihomoVersion..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $downloadClient = New-Object System.Net.WebClient
        $downloadClient.Headers.Set("User-Agent", "codex-split-proxy/0.1")
        $downloadClient.DownloadFile($MihomoZipUrl, $zipPath)
    } catch {
        throw "Could not download mihomo from GitHub. Download $MihomoZipUrl manually, extract mihomo.exe, and place it at $BinDir\mihomo.exe. Original error: $($_.Exception.Message)"
    }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
    $exe = Get-ChildItem -Path $extractDir -Filter "*.exe" -Recurse | Select-Object -First 1
    if (!$exe) {
        throw "Downloaded archive did not contain a mihomo executable."
    }

    $target = Join-Path $BinDir "mihomo.exe"
    Copy-Item -Force $exe.FullName $target
    Remove-Item -Force $zipPath
    Remove-Item -Recurse -Force $extractDir
    return $target
}

function Get-PortProcess($Port) {
    $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (!$connections) { return $null }
    $pidValue = $connections[0].OwningProcess
    $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Port = $Port
        ProcessId = $pidValue
        ProcessName = if ($proc) { $proc.ProcessName } else { "unknown" }
    }
}

function Assert-PortFree($Port) {
    $owner = Get-PortProcess $Port
    if ($owner) {
        throw "Port $Port is already in use by process $($owner.ProcessName) ($($owner.ProcessId)). Stop that process or change the port in $ConfigPath."
    }
}

function Get-ManagedProcess {
    if (!(Test-Path $PidPath)) { return $null }
    $pidText = (Get-Content -Raw $PidPath).Trim()
    if (!$pidText) { return $null }
    return Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
}

function Test-IsYamlLike($Text) {
    return $Text -match "(?m)^\s*proxies\s*:" -or $Text -match "(?m)^\s*proxy-groups\s*:" -or $Text -match "(?m)^\s*rules\s*:"
}

function Get-YamlBlockLines([string[]]$Lines, [string]$Key) {
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*:") {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { return @() }

    $result = New-Object System.Collections.Generic.List[string]
    $result.Add($Lines[$start])
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match "^[A-Za-z0-9_-]+\s*:") { break }
        $result.Add($line)
    }
    return $result.ToArray()
}

function Extract-ProxyNames([string[]]$ProxyLines) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $ProxyLines) {
        if ($line -match "^\s*-\s*\{.*name\s*:\s*([^,\}]+)") {
            $names.Add($matches[1].Trim().Trim("'`""))
        } elseif ($line -match "^\s*-\s*name\s*:\s*(.+)$") {
            $names.Add($matches[1].Trim().Trim("'`""))
        }
    }
    return $names.ToArray()
}

function Extract-GroupNames([string[]]$GroupLines) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $GroupLines) {
        if ($line -match "^\s*-\s*\{.*name\s*:\s*([^,\}]+)") {
            $names.Add($matches[1].Trim().Trim("'`""))
        } elseif ($line -match "^\s*-\s*name\s*:\s*(.+)$") {
            $names.Add($matches[1].Trim().Trim("'`""))
        }
    }
    return $names.ToArray()
}

function Convert-ToSingleQuotedYaml($Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Build-MihomoConfig($SubscriptionText, $HttpPort, $SocksPort, $ControllerPort, $ControllerSecret) {
    if (!(Test-IsYamlLike $SubscriptionText)) {
        throw "The subscription does not look like Clash/mihomo YAML. Please use a Clash-compatible subscription URL."
    }

    $lines = $SubscriptionText -split "`r?`n"
    $proxyLines = Get-YamlBlockLines $lines "proxies"
    if ($proxyLines.Count -eq 0) {
        throw "The subscription YAML has no proxies section."
    }

    $proxyGroupLines = Get-YamlBlockLines $lines "proxy-groups"
    $ruleLines = Get-YamlBlockLines $lines "rules"
    $proxyNames = @(Extract-ProxyNames $proxyLines)
    $fallbackGroupName = "Proxy"
    $groupNames = @(Extract-GroupNames $proxyGroupLines)
    $finalGroupName = if ($groupNames.Count -gt 0) { $groupNames[0] } else { $fallbackGroupName }

    $builder = New-Object System.Collections.Generic.List[string]
    $builder.Add("# Generated by codex-split-proxy. Do not edit this file directly.")
    $builder.Add("mixed-port: $HttpPort")
    $builder.Add("socks-port: $SocksPort")
    $builder.Add("allow-lan: false")
    $builder.Add("bind-address: 127.0.0.1")
    $builder.Add("mode: rule")
    $builder.Add("log-level: info")
    $builder.Add("ipv6: false")
    $builder.Add("external-controller: 127.0.0.1:$ControllerPort")
    $builder.Add("secret: $(Convert-ToSingleQuotedYaml $ControllerSecret)")
    $builder.Add("")

    foreach ($line in $proxyLines) { $builder.Add($line) }
    $builder.Add("")

    if ($proxyGroupLines.Count -gt 0) {
        foreach ($line in $proxyGroupLines) { $builder.Add($line) }
    } else {
        if ($proxyNames.Count -eq 0) {
            throw "The subscription has proxies, but proxy names could not be detected."
        }
        $builder.Add("proxy-groups:")
        $builder.Add("  - name: $fallbackGroupName")
        $builder.Add("    type: select")
        $builder.Add("    proxies:")
        foreach ($name in $proxyNames) {
            $builder.Add("      - $(Convert-ToSingleQuotedYaml $name)")
        }
    }
    $builder.Add("")
    $builder.Add("rules:")
    $builder.Add("  - DOMAIN-SUFFIX,local,DIRECT")
    $builder.Add("  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve")
    $builder.Add("  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")
    $builder.Add("  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve")
    $builder.Add("  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve")
    $builder.Add("  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve")
    if ($ruleLines.Count -gt 1) {
        foreach ($line in ($ruleLines | Select-Object -Skip 1)) {
            if (![string]::IsNullOrWhiteSpace($line)) { $builder.Add($line) }
        }
    } else {
        $builder.Add("  - DOMAIN-SUFFIX,cn,DIRECT")
        $builder.Add("  - MATCH,$finalGroupName")
    }
    return ($builder -join "`n") + "`n"
}

function Update-ConfigFromSubscription {
    $config = Assert-Configured
    Ensure-AppDir
    Write-Host "Fetching subscription..."
    $client = New-Object System.Net.WebClient
    $client.Encoding = [System.Text.Encoding]::UTF8
    $client.Headers.Set("User-Agent", "ClashforWindows/0.20.39")
    $subscriptionText = $client.DownloadString($config.subscriptionUrl)
    if ([string]::IsNullOrWhiteSpace($subscriptionText)) {
        throw "Subscription response was empty."
    }

    Set-Content -Encoding UTF8 $SubscriptionPath $subscriptionText
    $mihomoYaml = Build-MihomoConfig $subscriptionText $config.httpPort $config.socksPort $config.controllerPort $config.controllerSecret
    Set-Content -Encoding UTF8 $MihomoConfigPath $mihomoYaml
    Write-Host "Generated $MihomoConfigPath"
}

function Write-Env {
    $config = Read-JsonConfig
    $http = "http://127.0.0.1:$($config.httpPort)"
    $socks = "socks5://127.0.0.1:$($config.socksPort)"
    Write-Output "`$env:HTTP_PROXY='$http'"
    Write-Output "`$env:HTTPS_PROXY='$http'"
    Write-Output "`$env:ALL_PROXY='$socks'"
    Write-Output "`$env:NO_PROXY='localhost,127.0.0.1,::1,.local'"
}

function Invoke-Run($ArgsToRun) {
    if (!$ArgsToRun -or $ArgsToRun.Count -eq 0) {
        throw "Usage: .\codex-split-proxy.ps1 run <command> [args...]"
    }
    $config = Read-JsonConfig
    $env:HTTP_PROXY = "http://127.0.0.1:$($config.httpPort)"
    $env:HTTPS_PROXY = "http://127.0.0.1:$($config.httpPort)"
    $env:ALL_PROXY = "socks5://127.0.0.1:$($config.socksPort)"
    $env:NO_PROXY = "localhost,127.0.0.1,::1,.local"
    & $ArgsToRun[0] @($ArgsToRun | Select-Object -Skip 1)
    exit $LASTEXITCODE
}

if ($env:CODEX_CLEARWAY_TEST_IMPORT -ne "1") {
switch ($Command) {
    "init" {
        if (!$Rest -or [string]::IsNullOrWhiteSpace($Rest[0])) {
            throw "Usage: .\codex-split-proxy.ps1 init <clash-subscription-url>"
        }
        Ensure-AppDir
        $config = [ordered]@{
            subscriptionUrl = $Rest[0]
            httpPort = $DefaultHttpPort
            socksPort = $DefaultSocksPort
        }
        $config = Merge-ConfigDefaults ([pscustomobject]$config)
        Write-JsonConfig $config
        Update-ConfigFromSubscription
        Write-Host "Saved private config to $ConfigPath"
    }
    "update" {
        Update-ConfigFromSubscription
    }
    "start" {
        $config = Assert-Configured
        if (Get-ManagedProcess) {
            Write-Host "mihomo is already running with PID $((Get-ManagedProcess).Id)."
            return
        }
        if (!(Test-Path $MihomoConfigPath)) { Update-ConfigFromSubscription }
        Assert-PortFree $config.httpPort
        Assert-PortFree $config.socksPort
        Assert-PortFree $config.controllerPort
        $mihomo = Install-Mihomo
        $args = @("-f", $MihomoConfigPath, "-d", $AppDir)
        $process = Start-Process -FilePath $mihomo -ArgumentList $args -WorkingDirectory $AppDir -WindowStyle Hidden -RedirectStandardOutput $LogPath -RedirectStandardError $ErrorLogPath -PassThru
        Set-Content -Encoding ASCII $PidPath $process.Id
        Start-Sleep -Seconds 2
        if (!(Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            throw "mihomo exited after startup. Check $LogPath"
        }
        Write-Host "Started mihomo PID $($process.Id). HTTP proxy: 127.0.0.1:$($config.httpPort), SOCKS5: 127.0.0.1:$($config.socksPort)"
    }
    "stop" {
        $proc = Get-ManagedProcess
        if (!$proc) {
            Remove-Item -Force $PidPath -ErrorAction SilentlyContinue
            Write-Host "mihomo is not running."
            return
        }
        Stop-Process -Id $proc.Id
        Remove-Item -Force $PidPath -ErrorAction SilentlyContinue
        Write-Host "Stopped mihomo PID $($proc.Id)."
    }
    "status" {
        $config = Read-JsonConfig
        $proc = Get-ManagedProcess
        Write-Host "Config: $ConfigPath"
        Write-Host "Generated mihomo config: $MihomoConfigPath"
        Write-Host "HTTP proxy: 127.0.0.1:$($config.httpPort)"
        Write-Host "SOCKS5 proxy: 127.0.0.1:$($config.socksPort)"
        if ($proc) { Write-Host "Status: running, PID $($proc.Id)" } else { Write-Host "Status: stopped" }
        if (Test-Path $SubscriptionPath) { Write-Host "Subscription cache: $((Get-Item $SubscriptionPath).LastWriteTime)" }
        if (Test-Path $LogPath) {
            Write-Host "Recent log:"
            Get-Content $LogPath -Tail 20
        }
        if (Test-Path $ErrorLogPath) {
            Write-Host "Recent error log:"
            Get-Content $ErrorLogPath -Tail 20
        }
    }
    "env" {
        Write-Env
    }
    "run" {
        Invoke-Run $Rest
    }
    "config-path" {
        Write-Output $ConfigPath
    }
    "migrate-config" {
        $config = Assert-Configured
        Write-Host "Migrated private config at $ConfigPath"
    }
}
}
