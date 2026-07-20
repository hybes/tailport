#requires -Version 5.1

param(
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'tailport'),
    [switch]$NoPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binDirectory = Join-Path $Prefix 'bin'
New-Item -ItemType Directory -Force -Path $binDirectory | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'tailport.ps1') (Join-Path $binDirectory 'tailport.ps1')

$wrapper = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tailport.ps1" %*
'@
$wrapper | Set-Content -Encoding ASCII (Join-Path $binDirectory 'tailport.cmd')
$wrapper | Set-Content -Encoding ASCII (Join-Path $binDirectory 'tp.cmd')

if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries -notcontains $binDirectory) {
        $newUserPath = (@($entries) + $binDirectory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        $env:Path = "$env:Path;$binDirectory"
        Write-Output "Added $binDirectory to your user PATH. Open a new terminal to use it."
    }
}

Write-Output "Installed tailport and tp in $binDirectory"
