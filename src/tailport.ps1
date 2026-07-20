#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TailportVersion = '@TAILPORT_VERSION@'

function Show-Usage {
    @'
Usage: tailport [options] [machine] [ports]

Pick an online Tailscale machine and forward its loopback ports to this PC.

Arguments:
  machine             MagicDNS name, SSH alias, IP, or user@machine
  ports               Comma-separated ports, e.g. 5173,3005
                      Use LOCAL:REMOTE to remap, e.g. 8080:3000

Options:
  -u, --user USER     SSH user (or set TAILPORT_USER)
  -a, --all           Include offline Tailscale peers in the picker
  -V, --version       Show the installed version
  -h, --help          Show this help

Examples:
  tailport
  tailport bh-mm 5173,3005
  tailport -u ben bh-mm 5173,8080:3005
'@ | Write-Output
}

function Fail([string]$Message) {
    [Console]::Error.WriteLine("tailport: $Message")
    exit 1
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "missing dependency: $Name"
    }
}

function Fit-Column([string]$Value, [int]$Width) {
    if ($null -eq $Value) { return '' }
    if ($Value.Length -le $Width) { return $Value }
    return $Value.Substring(0, $Width)
}

$sshUser = $env:TAILPORT_USER
$includeOffline = $false
$positionals = New-Object 'System.Collections.Generic.List[string]'

for ($index = 0; $index -lt $args.Count; $index++) {
    $argument = [string]$args[$index]

    if ($argument -eq '-u' -or $argument -eq '--user') {
        if ($index + 1 -ge $args.Count) { Fail "$argument requires a username" }
        $index++
        $sshUser = [string]$args[$index]
    }
    elseif ($argument -eq '-a' -or $argument -eq '--all') {
        $includeOffline = $true
    }
    elseif ($argument -eq '-h' -or $argument -eq '--help') {
        Show-Usage
        exit 0
    }
    elseif ($argument -eq '-V' -or $argument -eq '--version') {
        Write-Output "tailport $TailportVersion"
        exit 0
    }
    elseif ($argument -eq '--') {
        for ($index++; $index -lt $args.Count; $index++) {
            $positionals.Add([string]$args[$index])
        }
        break
    }
    elseif ($argument.StartsWith('-')) {
        Fail "unknown option: $argument"
    }
    else {
        $positionals.Add($argument)
    }
}

if ($positionals.Count -gt 2) {
    Fail 'expected at most a machine and a port list'
}

Require-Command 'tailscale'
Require-Command 'ssh'

$machine = if ($positionals.Count -ge 1) { $positionals[0] } else { '' }
$portsInput = if ($positionals.Count -ge 2) { $positionals[1] } else { '' }

if ([string]::IsNullOrWhiteSpace($machine)) {
    $statusOutput = & tailscale status --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "could not read the Tailscale peer list: $($statusOutput -join ' ')"
    }

    try {
        $status = ($statusOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        Fail "could not parse the Tailscale peer list: $($_.Exception.Message)"
    }

    $magicDns = [bool]$status.CurrentTailnet.MagicDNSEnabled
    $peers = @(
        $status.Peer.PSObject.Properties |
            ForEach-Object { $_.Value } |
            Where-Object { $_.Online -or $includeOffline } |
            ForEach-Object {
                $dnsName = [string]$_.DNSName
                $dnsName = $dnsName.TrimEnd('.')
                $shortName = if ($dnsName) { $dnsName.Split('.')[0] } else { [string]$_.HostName }
                $target = if ($magicDns -and $dnsName) { $shortName } else { [string]$_.TailscaleIPs[0] }

                [PSCustomObject]@{
                    Name = $shortName
                    Host = [string]$_.HostName
                    OS = [string]$_.OS
                    State = if ($_.Online) { 'online' } else { 'offline' }
                    Target = $target
                }
            } |
            Sort-Object Name
    )

    if ($peers.Count -eq 0) { Fail 'no matching Tailscale peers found' }

    Write-Output 'Tailscale machines:'
    Write-Output ('     {0,-18}  {1,-24}  {2,-8}  {3,-7}' -f 'TAILNET NAME', 'HOSTNAME', 'OS', 'STATE')
    for ($index = 0; $index -lt $peers.Count; $index++) {
        $peer = $peers[$index]
        $row = [string]::Format(
            '  {0,2}) {1,-18}  {2,-24}  {3,-8}  {4,-7}',
            ($index + 1),
            (Fit-Column $peer.Name 18),
            (Fit-Column $peer.Host 24),
            (Fit-Column $peer.OS 8),
            $peer.State
        )
        Write-Output $row
    }

    $choiceText = Read-Host 'Machine number'
    $choice = 0
    if (-not [int]::TryParse($choiceText, [ref]$choice)) { Fail 'invalid selection' }
    if ($choice -lt 1 -or $choice -gt $peers.Count) { Fail 'selection out of range' }
    $machine = $peers[$choice - 1].Target
}

if ([string]::IsNullOrWhiteSpace($portsInput)) {
    $portsInput = Read-Host 'Ports (comma-separated, e.g. 5173,3005)'
}

$portsInput = [regex]::Replace($portsInput, '\s', '')
if ([string]::IsNullOrWhiteSpace($portsInput)) { Fail 'no ports supplied' }

$sshArguments = New-Object 'System.Collections.Generic.List[string]'
$sshArguments.Add('-N')
$sshArguments.Add('-T')
$sshArguments.Add('-o')
$sshArguments.Add('ExitOnForwardFailure=yes')
$sshArguments.Add('-o')
$sshArguments.Add('ServerAliveInterval=30')
$sshArguments.Add('-o')
$sshArguments.Add('ServerAliveCountMax=3')
$summary = New-Object 'System.Collections.Generic.List[string]'
$claimedLocalPorts = @{}

foreach ($spec in $portsInput.Split(',')) {
    if ([string]::IsNullOrWhiteSpace($spec)) { Fail "empty port in list: $portsInput" }
    $parts = $spec.Split(':')
    if ($parts.Count -gt 2) { Fail "invalid mapping: $spec" }

    $localRaw = $parts[0]
    $remoteRaw = if ($parts.Count -eq 2) { $parts[1] } else { $parts[0] }
    $localPort = 0
    $remotePort = 0

    if (-not [int]::TryParse($localRaw, [ref]$localPort)) { Fail "invalid local port: $localRaw" }
    if (-not [int]::TryParse($remoteRaw, [ref]$remotePort)) { Fail "invalid remote port: $remoteRaw" }
    if ($localPort -lt 1 -or $localPort -gt 65535) { Fail "local port out of range: $localRaw" }
    if ($remotePort -lt 1 -or $remotePort -gt 65535) { Fail "remote port out of range: $remoteRaw" }
    if ($claimedLocalPorts.ContainsKey($localPort)) { Fail "local port repeated: $localPort" }
    $claimedLocalPorts[$localPort] = $true

    $sshArguments.Add('-L')
    $sshArguments.Add("127.0.0.1:${localPort}:localhost:${remotePort}")
    $summary.Add("localhost:${localPort} -> ${machine}:${remotePort}")
}

$target = $machine
if (-not [string]::IsNullOrWhiteSpace($sshUser) -and -not $machine.Contains('@')) {
    $target = "${sshUser}@${machine}"
}

Write-Output ''
Write-Output "Opening Tailscale SSH tunnel to ${target}:"
foreach ($line in $summary) { Write-Output "  $line" }
Write-Output ''
Write-Output 'Keep this window open; press Ctrl-C to close every forward.'
Write-Output ''

$sshArgumentArray = $sshArguments.ToArray()
& ssh @sshArgumentArray $target
$sshSucceeded = $?
$sshExitCode = if (Test-Path 'variable:LASTEXITCODE') {
    $LASTEXITCODE
}
elseif ($sshSucceeded) {
    0
}
else {
    1
}
exit $sshExitCode
