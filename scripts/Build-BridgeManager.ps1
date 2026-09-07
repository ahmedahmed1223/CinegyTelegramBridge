#requires -Version 7
<#
    Build-BridgeManager.ps1

    Publishes Manager/BridgeManager (the WinForms supervisor app) as a single
    self-contained BridgeManager.exe under dist/BridgeManager. Requires the
    .NET 9 SDK (https://dotnet.microsoft.com/download) - not PowerShell 7,
    which is only needed to run the bridge itself.

    The exe is stamped with the MAJOR version only - 7, not 7.76.0 - and
    shows it in the title bar and in Explorer's file properties.

    The two are versioned apart on purpose. The bridge ships several times a
    day; this exe is republished only when the manager itself changes, so a
    manager stamped 7.76.0 sitting beside a bridge at 7.79.0 reads as out of
    date when it is current. The major number is the compatibility claim it
    can actually keep: this is the v7 manager, for a v7 bridge.

    The running bridge's own full version is read off its startup line and
    shown beside the manager's in the status bar, so the pair is visible
    without either being mistaken for the other.

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

$bridgeVersion = "0.0.0"
if (Test-Path $bridgeScript) {
    foreach ($line in Get-Content -LiteralPath $bridgeScript) {
        if ($line -match "BridgeVersion\s*=\s*'(\d+\.\d+\.\d+)'") { $bridgeVersion = $Matches[1]; break }
    }
}
# Major only - see the header. AssemblyVersion wants four parts, and "7"
# widens to 7.0.0.0 on its own.
$version = ($bridgeVersion -split '\.')[0]
Write-Host "Bridge version: $bridgeVersion  ->  manager v$version" -ForegroundColor Cyan

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

Write-Host "Built: $exe (manager v$version, for bridge v$bridgeVersion)" -ForegroundColor Green
