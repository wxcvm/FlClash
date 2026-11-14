param(
    [Parameter(Mandatory = $true)][string]$ResolverHost,
    [ValidateRange(1,65535)][int]$MixedPort = 7890,
    [string]$FakeIpRange = '198.18.0.0/15',
    [string]$TestUrl = 'https://www.gstatic.com/generate_204',
    [ValidateRange(1,120)][int]$Samples = 1,
    [ValidateRange(0,60)][int]$IntervalSeconds = 2,
    [switch]$RouteDetails
)
$ErrorActionPreference = 'Stop'
# No private URL in the diagnostic report or subprocess arguments.
$testUri = [uri]$TestUrl
if (-not $testUri.IsAbsoluteUri -or $testUri.Scheme -ne 'https' -or $testUri.IsLoopback) {
    throw 'Choose a public HTTPS test URL, not loopback.'
}
if ($ResolverHost -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -or
    $ResolverHost.Contains('..')) {
    throw 'Supply the resolver hostname only, without scheme, path or query.'
}
if ($FakeIpRange -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
    throw 'FakeIpRange must be an IPv4 CIDR.'
}
$rangeIp = [System.Net.IPAddress]::Parse($Matches[1])
$prefix = [int]$Matches[2]
if ($prefix -gt 32 -or $rangeIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Invalid IPv4 CIDR.'
}
function Test-FakeAddress([string]$Address) {
    $ip = [System.Net.IPAddress]::Parse($Address)
    if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $a = $ip.GetAddressBytes()
    $b = $rangeIp.GetAddressBytes()
    for ($i = 0; $i -lt $prefix; $i++) {
        $byte = [int][Math]::Floor($i / 8)
        $mask = 128 -shr ($i % 8)
        if (($a[$byte] -band $mask) -ne ($b[$byte] -band $mask)) { return $false }
    }
    return $true
}
# Find-NetRoute reports the best route at observation time, not a packet trace.
function Get-RouteObservation([string]$Address) {
    if (-not $Address) { return $null }
    try {
        $route = Find-NetRoute -RemoteIPAddress $Address -ErrorAction Stop |
            Where-Object { $_.PSObject.Properties['DestinationPrefix'] } |
            Select-Object -First 1
        if (-not $route) { return [pscustomobject]@{ error = 'NoRouteReturned' } }
        return [pscustomobject]@{
            interfaceIndex = $route.InterfaceIndex
            interfaceAlias = $route.InterfaceAlias
            destinationPrefix = $route.DestinationPrefix
            nextHop = $route.NextHop
            routeMetric = $route.RouteMetric
        }
    } catch {
        return [pscustomobject]@{ error = $_.Exception.GetType().Name }
    }
}
function Test-HttpPath([string]$ProxyUrl) {
    $format = '%{http_code} %{time_total}'
    if ($RouteDetails) { $format += '|%{remote_ip}' }
    $args = @('--disable', '--silent', '--output', 'NUL', '--connect-timeout', '5',
              '--max-time', '12', '--write-out', $format)
    if ($ProxyUrl) {
        # Windows PowerShell 5 can drop empty native-command arguments.
        # The fixed diagnostic URL is public; exclude only loopback from proxy bypass.
        $args += @('--proxy', $ProxyUrl, '--noproxy', 'localhost,127.0.0.1,::1')
    } else {
        $args += @('--noproxy', '*')
    }
    $args += $TestUrl
    $started = [DateTimeOffset]::UtcNow
    $value = & curl.exe @args 2>$null
    $code = $LASTEXITCODE
    $finished = [DateTimeOffset]::UtcNow
    $parts = ($value -join '') -split '\|', 2
    $result = [ordered]@{
        startedUtc = $started.ToString('o')
        finishedUtc = $finished.ToString('o')
        curlExit = $code
        httpAndSeconds = $parts[0]
    }
    if ($RouteDetails) {
        $remote = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $result.remoteAddress = $remote
        $result.routeObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $result.route = Get-RouteObservation $remote
    }
    return [pscustomobject]$result
}
function Get-PathSample {
    $started = [DateTimeOffset]::UtcNow
    $answers = @()
    $dnsError = $null
    try {
        $answers = @(Resolve-DnsName -Name $ResolverHost -Type A -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -eq 'A' -and $_.IPAddress } |
            ForEach-Object { [pscustomobject]@{ address = $_.IPAddress; fake = (Test-FakeAddress $_.IPAddress) } })
    } catch { $dnsError = $_.Exception.GetType().Name }
    $sample = [ordered]@{
        startedUtc = $started.ToString('o')
        dnsFinishedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        resolverHost = $ResolverHost
        fakeIpRange = $FakeIpRange
        dnsAnswers = $answers
        dnsError = $dnsError
        noApplicationProxy = (Test-HttpPath '')
        explicitFlClashProxy = (Test-HttpPath "http://127.0.0.1:$MixedPort")
        finishedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($RouteDetails) {
        # When curl could not connect it may have no remote IP. Record the
        # routes to current DNS candidates separately, not as actual peers.
        $sample.destinationCandidates = @(try {
            Resolve-DnsName -Name $testUri.DnsSafeHost -DnsOnly -ErrorAction Stop |
                Where-Object { $_.IPAddress -and $_.Type -in @('A','AAAA') } |
                Select-Object -First 4 | ForEach-Object {
                    [pscustomobject]@{
                        address = $_.IPAddress
                        route = Get-RouteObservation $_.IPAddress
                    }
                }
        } catch {
            [pscustomobject]@{ error = $_.Exception.GetType().Name }
        })
        $sample.candidatesObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    return [pscustomobject]$sample
}
# Preserve the original single-sample JSON shape. In timeline mode, change the
# physical network or AdGuard DNS yourself while probes are running.
if ($Samples -eq 1) {
    Get-PathSample | ConvertTo-Json -Depth 9
} else {
    $timeline = @(for ($i = 1; $i -le $Samples; $i++) {
        Write-Progress -Activity 'FlClash network recovery probes' -Status "Sample $i of $Samples" -PercentComplete (($i - 1) * 100 / $Samples)
        Get-PathSample
        if ($i -lt $Samples) { Start-Sleep -Seconds $IntervalSeconds }
    })
    Write-Progress -Activity 'FlClash network recovery probes' -Completed
    [pscustomobject]@{ samples = $timeline } | ConvertTo-Json -Depth 7
}
