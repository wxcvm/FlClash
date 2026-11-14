# Synthetic DNS/curl/route results exercise report shape without network traffic.
$ErrorActionPreference = 'Stop'
function Resolve-DnsName {
    param([string]$Name, [string]$Type, [switch]$DnsOnly, $ErrorAction)
    [pscustomobject]@{ Type = 'A'; IPAddress = '198.18.0.1' }
}
function Find-NetRoute {
    param([string]$RemoteIPAddress, $ErrorAction)
    $alias = if ($RemoteIPAddress -eq '127.0.0.1') { 'Loopback' } else { 'TestTun' }
    [pscustomobject]@{
        InterfaceIndex = 7; InterfaceAlias = $alias
        DestinationPrefix = '198.18.0.0/15'; NextHop = '0.0.0.0'; RouteMetric = 10
    }
}
function curl.exe {
    if ($args[0] -ne '--disable') { throw 'curlrc was not disabled' }
    $global:LASTEXITCODE = 0
    $format = $args[[array]::IndexOf($args, '--write-out') + 1]
    if ($format -notlike '*remote_ip*') { return '204 0.2' }
    if ($args -contains '--proxy') { return '204 0.2|127.0.0.1' }
    return '204 0.2|198.18.0.1'
}
$script = Join-Path $PSScriptRoot 'check-dns-path.ps1'
$legacy = & $script -ResolverHost 'resolver.example' | ConvertFrom-Json
if ($legacy.noApplicationProxy.httpAndSeconds -ne '204 0.2' -or
    $legacy.noApplicationProxy.PSObject.Properties['route']) {
    throw 'Legacy report changed'
}
$details = & $script -ResolverHost 'resolver.example' -RouteDetails | ConvertFrom-Json
if ($details.noApplicationProxy.route.interfaceAlias -ne 'TestTun' -or
    $details.explicitFlClashProxy.route.interfaceAlias -ne 'Loopback' -or
    $details.noApplicationProxy.remoteAddress -ne '198.18.0.1' -or
    $details.destinationCandidates[0].route.destinationPrefix -ne '198.18.0.0/15' -or
    -not $details.dnsAnswers[0].fake) {
    throw 'Incorrect route or DNS report'
}
Write-Output 'PASS: Windows route diagnostic report and legacy shape'
