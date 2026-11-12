param(
    [Parameter(Mandatory = $true)][string]$ResolverHost,
    [ValidateRange(1,65535)][int]$MixedPort = 7890,
    [string]$FakeIpRange = '198.18.0.0/15',
    [string]$TestUrl = 'https://www.gstatic.com/generate_204'
)
$ErrorActionPreference = 'Stop'
# No private URL in the diagnostic report or subprocess arguments.
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
$answers = @()
$dnsError = $null
try {
    $answers = @(Resolve-DnsName -Name $ResolverHost -Type A -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -eq 'A' -and $_.IPAddress } |
        ForEach-Object { [pscustomobject]@{ address = $_.IPAddress; fake = (Test-FakeAddress $_.IPAddress) } })
} catch { $dnsError = $_.Exception.GetType().Name }
function Test-HttpPath([string]$ProxyUrl) {
    $args = @('--silent', '--output', 'NUL', '--connect-timeout', '5',
              '--max-time', '12', '--write-out', '%{http_code} %{time_total}')
    if ($ProxyUrl) {
        $args += @('--proxy', $ProxyUrl, '--noproxy', '')
    } else {
        $args += @('--noproxy', '*')
    }
    $args += $TestUrl
    $value = & curl.exe @args 2>$null
    $code = $LASTEXITCODE
    return [pscustomobject]@{ curlExit = $code; httpAndSeconds = ($value -join '') }
}
[pscustomobject]@{
    resolverHost = $ResolverHost
    fakeIpRange = $FakeIpRange
    dnsAnswers = $answers
    dnsError = $dnsError
    noApplicationProxy = (Test-HttpPath '')
    explicitFlClashProxy = (Test-HttpPath "http://127.0.0.1:$MixedPort")
} | ConvertTo-Json -Depth 5
