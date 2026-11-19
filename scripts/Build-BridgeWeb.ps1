#requires -Version 7
<#
    Build-BridgeWeb.ps1 - builds the web interface into dist\web.

    1. The client (Web\Client): checks its API types against Web\openapi.json,
       type-checks, tests, and builds into the server's wwwroot.
    2. The server (Web\Server): tests, then publishes one self-contained
       CinegyBridge.Web.exe with its wwwroot beside it.

    The control program looks for dist\web\CinegyBridge.Web.exe. Neither Node
    nor .NET is needed on the station that runs it - only on the machine that
    builds it.

        .\scripts\Build-BridgeWeb.ps1
#>
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$client = Join-Path $root 'Web\Client'
$server = Join-Path $root 'Web\Server\CinegyBridge.Web.csproj'
$tests = Join-Path $root 'Web\Server.Tests\CinegyBridge.Web.Tests.csproj'
$outDir = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist\web' }

foreach ($tool in 'dotnet', 'pnpm') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found. The web build needs the .NET 9 SDK and pnpm (npm install -g pnpm)."
    }
}

function Invoke-Step {
    param([string]$Title, [scriptblock]$Command)
    Write-Host "==> $Title" -ForegroundColor Cyan
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Title failed (exit $LASTEXITCODE)." }
}

# The server first: its build regenerates Web\openapi.json, which the client's
# type check below is compared against.
Invoke-Step 'Server tests' { dotnet test $tests -c Release }
Push-Location $client
try {
    Invoke-Step 'Client dependencies' { pnpm install --frozen-lockfile }
    Invoke-Step 'Client API types match openapi.json' { pnpm api:check }
    Invoke-Step 'Client type check' { pnpm typecheck }
    Invoke-Step 'Client tests' { pnpm test }
    Invoke-Step 'Client build' { pnpm build }
}
finally { Pop-Location }
Invoke-Step 'Server publish' { dotnet publish $server -c Release -o $outDir }

Write-Host "Built: $(Join-Path $outDir 'CinegyBridge.Web.exe')" -ForegroundColor Green
