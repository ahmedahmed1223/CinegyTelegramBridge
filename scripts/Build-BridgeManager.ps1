#requires -Version 7
<#
    Build-BridgeManager.ps1

    Publishes Manager/BridgeManager (the WinForms supervisor app) as a single
    self-contained BridgeManager.exe under dist/BridgeManager. Requires the
    .NET 9 SDK (https://dotnet.microsoft.com/download) - not PowerShell 7,
    which is only needed to run the bridge itself.

    The exe's own version is stamped from TelegramBridge.ps1's
    $script:BridgeVersion at publish time, so BridgeManager.exe always
    reports the version of the bridge it was built alongside (shown in its
    title bar and in Explorer's file properties).

    Usage:
        .\scripts\Build-BridgeManager.ps1
#>

param()

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)
$project = Join-Path $scriptRoot "Manager\BridgeManager\BridgeManager.csproj"
$outDir = Join-Path $scriptRoot "dist\BridgeManager"
$bridgeScript = Join-Path $scriptRoot "TelegramBridge.ps1"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found. Install the .NET 9 SDK from https://dotnet.microsoft.com/download, then re-run this script."
}

$version = "0.0.0"
if (Test-Path $bridgeScript) {
    foreach ($line in Get-Content -LiteralPath $bridgeScript) {
        if ($line -match "BridgeVersion\s*=\s*'([\d.]+)'") { $version = $Matches[1]; break }
    }
}
Write-Host "Bridge version: $version" -ForegroundColor Cyan

dotnet publish $project -c Release -r win-x64 --self-contained true -o $outDir "-p:Version=$version"
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

Write-Host "Built: $outDir\BridgeManager.exe (v$version)" -ForegroundColor Green
