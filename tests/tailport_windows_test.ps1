#requires -Version 5.1

param(
    [string]$Artifact = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist/tailport-windows.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$expectedVersion = (Get-Content (Join-Path $repoRoot 'VERSION') -Raw).Trim()
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("tailport-tests-" + [guid]::NewGuid())
$mockBin = Join-Path $temporary 'bin'
New-Item -ItemType Directory -Force -Path $mockBin | Out-Null

function Fail([string]$Message) {
    throw "not ok - $Message"
}

function Assert-Line([string]$Expected, [string]$File) {
    if ((Get-Content $File) -notcontains $Expected) { Fail "missing '$Expected' in $File" }
}

try {
    @'
@echo off
type "%TAILPORT_TEST_STATUS_JSON%"
'@ | Set-Content -Encoding ASCII (Join-Path $mockBin 'tailscale.cmd')

    @'
$args | Set-Content -Encoding UTF8 $env:TAILPORT_TEST_SSH_ARGS
'@ | Set-Content -Encoding UTF8 (Join-Path $mockBin 'mock-ssh.ps1')

    @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-ssh.ps1" %*
'@ | Set-Content -Encoding ASCII (Join-Path $mockBin 'ssh.cmd')

    $status = @'
{"CurrentTailnet":{"MagicDNSEnabled":true},"Peer":{}}
'@
    $env:TAILPORT_TEST_STATUS_JSON = Join-Path $temporary 'status.json'
    $status | Set-Content -Encoding UTF8 $env:TAILPORT_TEST_STATUS_JSON
    $env:Path = "$mockBin;$env:Path"

    $version = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Artifact --version
    if ($LASTEXITCODE -ne 0 -or $version -ne "tailport $expectedVersion") {
        Fail "unexpected version: $version"
    }
    Write-Output 'ok - Windows release version'

    $env:TAILPORT_TEST_SSH_ARGS = Join-Path $temporary 'ssh-args.txt'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Artifact -u ben bh-mm '5173,3005,8080:3000' |
        Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'direct invocation failed' }
    Assert-Line '127.0.0.1:5173:localhost:5173' $env:TAILPORT_TEST_SSH_ARGS
    Assert-Line '127.0.0.1:3005:localhost:3005' $env:TAILPORT_TEST_SSH_ARGS
    Assert-Line '127.0.0.1:8080:localhost:3000' $env:TAILPORT_TEST_SSH_ARGS
    Assert-Line 'ben@bh-mm' $env:TAILPORT_TEST_SSH_ARGS
    Write-Output 'ok - Windows forwarding and port remapping'

    Remove-Item -Force -ErrorAction SilentlyContinue $env:TAILPORT_TEST_SSH_ARGS
    $invalidOutput = Join-Path $temporary 'invalid-output.txt'
    $invalidError = Join-Path $temporary 'invalid-error.txt'
    $invalidProcessArguments = @{
        FilePath = 'powershell.exe'
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Artifact, 'bh-mm', '70000')
        Wait = $true
        PassThru = $true
        NoNewWindow = $true
        RedirectStandardOutput = $invalidOutput
        RedirectStandardError = $invalidError
    }
    $invalidProcess = Start-Process @invalidProcessArguments
    if ($invalidProcess.ExitCode -eq 0) { Fail 'out-of-range port was accepted' }
    if ((Get-Content $invalidError -Raw) -notmatch 'local port out of range: 70000') {
        Fail 'invalid-port error was not reported'
    }
    if (Test-Path $env:TAILPORT_TEST_SSH_ARGS) { Fail 'SSH ran for an invalid port' }
    Write-Output 'ok - Windows invalid port rejection'
}
finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $temporary
}
