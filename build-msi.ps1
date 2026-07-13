#Requires -Version 5.1
# Build the MSI locally. Requires the WiX .NET tool (v5; v6+ requires the OSMF EULA):
#   dotnet tool install --global wix --version 5.0.2
param(
    [string]$Version = '1.0.0'
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    Write-Host "WiX toolset not found. Install it with:" -ForegroundColor Yellow
    Write-Host "  dotnet tool install --global wix --version 5.0.2"
    exit 1
}

$dist = Join-Path $PSScriptRoot 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

$out = Join-Path $dist "UnProcessTool-$Version.msi"
wix build (Join-Path $PSScriptRoot 'wix\Package.wxs') -d "ProductVersion=$Version" -o $out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Built: $out" -ForegroundColor Green
