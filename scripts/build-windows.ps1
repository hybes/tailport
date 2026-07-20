#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $repoRoot 'VERSION') -Raw).Trim()
$source = Join-Path $repoRoot 'src/tailport.ps1'
$outputDirectory = Join-Path $repoRoot 'dist'
$output = Join-Path $outputDirectory 'tailport-windows.ps1'

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'VERSION must contain a semantic version (for example, 0.1.0)'
}

$contents = Get-Content $source -Raw
if (-not $contents.Contains('@TAILPORT_VERSION@')) {
    throw 'version placeholder is missing from src/tailport.ps1'
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$contents.Replace('@TAILPORT_VERSION@', $version) |
    Set-Content -Path $output -Encoding UTF8

Write-Output "Built dist/tailport-windows.ps1 ($version)"
