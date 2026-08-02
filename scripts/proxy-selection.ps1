$ErrorActionPreference = "Stop"

function New-SelectionResult([bool]$Success, [string]$Node = "", [int]$Delay = 0, [string]$Error = "") {
    return [pscustomobject]@{
        Success = $Success
        Node = $Node
        Delay = $Delay
        Error = $Error
    }
}

function Invoke-ControllerRest([string]$Method, [string]$Uri, $Headers, [string]$Body = $null) {
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $Headers
        UseBasicParsing = $true
        TimeoutSec = 10
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body
        $parameters.ContentType = "application/json"
    }
    return Invoke-RestMethod @parameters
}

function Get-ProxyValue($ProxyMap, [string]$Name) {
    $property = $ProxyMap.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-TerminalProxyNames($ProxyMap, [string[]]$Names) {
    $special = @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL")
    $visitedGroups = @{}
    $result = New-Object System.Collections.Generic.List[string]

    function Visit-ProxyName([string]$Name) {
        if ([string]::IsNullOrWhiteSpace($Name) -or $special -contains $Name.ToUpperInvariant()) { return }
        $proxy = Get-ProxyValue $ProxyMap $Name
        if ($null -eq $proxy) { return }
        $membersProperty = $proxy.PSObject.Properties["all"]
        if ($membersProperty -and $null -ne $membersProperty.Value) {
            if ($visitedGroups.ContainsKey($Name)) { return }
            $visitedGroups[$Name] = $true
            foreach ($member in @($membersProperty.Value)) { Visit-ProxyName ([string]$member) }
            return
        }
        if (!$result.Contains($Name)) { $result.Add($Name) }
    }

    foreach ($name in $Names) { Visit-ProxyName $name }
    return $result.ToArray()
}

function Invoke-InjectedDelayTests($Candidates, $Config, [string]$ControllerBase, $Headers, [scriptblock]$RestInvoker) {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $Candidates) {
        $encodedName = [uri]::EscapeDataString($candidate)
        $encodedUrl = [uri]::EscapeDataString([string]$Config.testUrl)
        $uri = "$ControllerBase/proxies/$encodedName/delay?url=$encodedUrl&timeout=$([int]$Config.testTimeoutMs)"
        try {
            $response = & $RestInvoker "GET" $uri $Headers $null
            $delay = [int]$response.delay
            if ($delay -gt 0) { $results.Add([pscustomobject]@{ Node = $candidate; Delay = $delay }) }
        } catch {
            continue
        }
    }
    return $results.ToArray()
}

function Invoke-ParallelDelayTests($Candidates, $Config, [string]$ControllerBase, $Headers) {
    $maxConcurrency = [Math]::Max(1, [Math]::Min([int]$Config.testConcurrency, $Candidates.Count))
    $pool = [runspacefactory]::CreateRunspacePool(1, $maxConcurrency)
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    $worker = {
        param($ControllerBase, $Node, $TestUrl, $TimeoutMs, $Headers)
        $encodedName = [uri]::EscapeDataString($Node)
        $encodedUrl = [uri]::EscapeDataString($TestUrl)
        $uri = "$ControllerBase/proxies/$encodedName/delay?url=$encodedUrl&timeout=$TimeoutMs"
        try {
            $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -UseBasicParsing -TimeoutSec ([Math]::Max(1, [Math]::Ceiling($TimeoutMs / 1000.0) + 1))
            $delay = [int]$response.delay
            if ($delay -gt 0) { [pscustomobject]@{ Node = $Node; Delay = $delay } }
        } catch {
            return
        }
    }

    try {
        foreach ($candidate in $Candidates) {
            $powerShell = [powershell]::Create()
            $powerShell.RunspacePool = $pool
            [void]$powerShell.AddScript($worker).AddArgument($ControllerBase).AddArgument($candidate).AddArgument([string]$Config.testUrl).AddArgument([int]$Config.testTimeoutMs).AddArgument($Headers)
            $jobs.Add([pscustomobject]@{ PowerShell = $powerShell; Handle = $powerShell.BeginInvoke() })
        }
        $results = New-Object System.Collections.Generic.List[object]
        foreach ($job in $jobs) {
            foreach ($item in @($job.PowerShell.EndInvoke($job.Handle))) {
                if ($null -ne $item) { $results.Add($item) }
            }
        }
        return $results.ToArray()
    } finally {
        foreach ($job in $jobs) { $job.PowerShell.Dispose() }
        $pool.Close()
        $pool.Dispose()
    }
}

function Invoke-ProxySelection {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][int]$HttpPort,
        [scriptblock]$RestInvoker,
        [scriptblock]$ProxyVerifier
    )

    $controllerBase = "http://127.0.0.1:$([int]$Config.controllerPort)"
    $headers = @{ Authorization = "Bearer $($Config.controllerSecret)" }
    if (!$RestInvoker) { $RestInvoker = ${function:Invoke-ControllerRest} }

    try {
        $controller = & $RestInvoker "GET" "$controllerBase/proxies" $headers $null
        $proxyMap = $controller.proxies
        $primary = $proxyMap.PSObject.Properties | Where-Object {
            $_.Value.type -eq "Selector" -and $_.Value.PSObject.Properties["all"]
        } | Select-Object -First 1
        if (!$primary) { return New-SelectionResult $false "" 0 "No selectable proxy group is available." }

        $candidates = @(Get-TerminalProxyNames $proxyMap @($primary.Value.all))
        if ($candidates.Count -eq 0) { return New-SelectionResult $false "" 0 "No eligible proxy nodes are available." }

        if ($PSBoundParameters.ContainsKey("RestInvoker")) {
            $measurements = @(Invoke-InjectedDelayTests $candidates $Config $controllerBase $headers $RestInvoker)
        } else {
            $measurements = @(Invoke-ParallelDelayTests $candidates $Config $controllerBase $headers)
        }
        $best = $measurements | Sort-Object Delay, Node | Select-Object -First 1
        if (!$best) { return New-SelectionResult $false "" 0 "All eligible proxy nodes failed the GitHub delay test." }

        $groupName = [uri]::EscapeDataString($primary.Name)
        $body = @{ name = $best.Node } | ConvertTo-Json -Compress
        [void](& $RestInvoker "PUT" "$controllerBase/proxies/$groupName" $headers $body)

        $proxyUri = "http://127.0.0.1:$HttpPort"
        $timeoutSec = [Math]::Max(1, [Math]::Ceiling([int]$Config.testTimeoutMs / 1000.0))
        if ($ProxyVerifier) {
            $verified = [bool](& $ProxyVerifier $proxyUri ([string]$Config.testUrl) $timeoutSec)
        } else {
            try {
                [void](Invoke-WebRequest -UseBasicParsing -Proxy $proxyUri -Uri ([string]$Config.testUrl) -TimeoutSec $timeoutSec)
                $verified = $true
            } catch {
                $verified = $false
            }
        }
        if (!$verified) { return New-SelectionResult $false "" 0 "Selected route failed final GitHub verification." }
        return New-SelectionResult $true $best.Node ([int]$best.Delay) ""
    } catch {
        return New-SelectionResult $false "" 0 "Proxy selection could not be completed."
    }
}
