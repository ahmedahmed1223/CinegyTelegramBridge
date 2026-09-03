#requires -Version 7
<#
    Build-BridgeManager.ps1

    Publishes Manager/BridgeManager (the WinForms supervisor app) as a single
    self-contained BridgeManager.exe under dist/BridgeManager. Requires the
    .NET 9 SDK (https://dotnet.microsoft.com/download) - not PowerShell 7,
    which is only needed to run the bridge itself.

    Usage:
        .\scripts\Build-BridgeManager.ps1
#>

param()

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)
$project = Join-Path $scriptRoot "Manager\BridgeManager\BridgeManager.csproj"
$outDir = Join-Path $scriptRoot "dist\BridgeManager"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found. Install the .NET 9 SDK from https://dotnet.microsoft.com/download, then re-run this script."
}

dotnet publish $project -c Release -r win-x64 --self-contained true -o $outDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

Write-Host "Built: $outDir\BridgeManager.exe" -ForegroundColor Green
