#requires -RunAsAdministrator
<#
    Uninstall-BridgeService-NSSM.ps1

    Stops and removes the NSSM service created by Install-BridgeService-NSSM.ps1.
    Run as Administrator.
#>

param(
    [string]$ServiceName = "CinegyTelegramBridge",
    [string]$NssmPath
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)

function Find-Nssm {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    $local = Join-Path $scriptRoot "nssm.exe"
    if (Test-Path $local) { return $local }
    $onPath = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($candidate in @("$env:ProgramData\chocolatey\bin\nssm.exe", "C:\nssm\nssm.exe", "C:\nssm\win64\nssm.exe")) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    Write-Host "No service named '$ServiceName' found - nothing to remove." -ForegroundColor Yellow
    return
}

$nssmPath = Find-Nssm -Explicit $NssmPath
if (-not $nssmPath) {
    throw "Service '$ServiceName' exists but nssm.exe could not be found to remove it cleanly. Locate the nssm.exe you installed with and pass it via -NssmPath, e.g. .\scripts\Uninstall-BridgeService-NSSM.ps1 -NssmPath 'C:\nssm\nssm.exe'."
}

& $nssmPath stop $ServiceName confirm 2>$null | Out-Null
& $nssmPath remove $ServiceName confirm | Out-Null

Write-Host "Service '$ServiceName' stopped and removed." -ForegroundColor Green
