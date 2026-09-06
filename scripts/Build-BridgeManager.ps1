#requires -Version 7
<#
    Build-BridgeManager.ps1

    Publishes Manager/BridgeManager (the WinForms supervisor app) as a single
    self-contained BridgeManager.exe under dist/BridgeManager. Requires the
    .NET 9 SDK (https://dotnet.microsoft.com/download) - not PowerShell 7,
    which is only needed to run the bridge itself.

    The exe's own version is stamped from TelegramBridge.ps1's
    $script:BridgeVersion at publish time, including minor and patch versions,
    shown in its title bar and in Explorer's file properties.

    Usage:
        .\scripts\Build-BridgeManager.ps1
#>

param([string]$OutputDirectory)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)
$project = Join-Path $scriptRoot "Manager\BridgeManager\BridgeManager.csproj"
$outDir = if ($OutputDirectory) { [System.IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $scriptRoot "dist\BridgeManager" }
$bridgeScript = Join-Path $scriptRoot "TelegramBridge.ps1"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found. Install the .NET 9 SDK from https://dotnet.microsoft.com/download, then re-run this script."
}

$version = "0"
if (Test-Path $bridgeScript) {
    foreach ($line in Get-Content -LiteralPath $bridgeScript) {
        if ($line -match "BridgeVersion\s*=\s*'(\d+\.\d+\.\d+)'") { $version = $Matches[1]; break }
    }
}
Write-Host "Bridge version: $version" -ForegroundColor Cyan

dotnet publish $project -c Release -r win-x64 --self-contained true -o $outDir "-p:Version=$version"
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }

$exe = Join-Path $outDir "BridgeManager.exe"

# The selftest existed for months and nothing ever ran it, which is the same as
# not having it. Start-Process -Wait rather than calling the exe directly:
# BridgeManager is a WinExe, so PowerShell does not wait for it and $LASTEXITCODE
# would be read before the process had finished deciding.
Write-Host "Running BridgeManager selftest..." -ForegroundColor Cyan
$selftest = Start-Process -FilePath $exe -ArgumentList '--selftest' -Wait -PassThru -WindowStyle Hidden
$report = Join-Path $outDir "BridgeManager-selftest.log"
if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report | ForEach-Object { Write-Host "  $_" } }
if ($selftest.ExitCode -ne 0) {
    throw "BridgeManager selftest failed (exit $($selftest.ExitCode)). See $report."
}

Write-Host "Built: $exe (v$version)" -ForegroundColor Green
