#requires -Version 7
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$SecretStorePath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BridgeSecurity.psm1') -Force
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
if ([string]::IsNullOrWhiteSpace($SecretStorePath)) {
    $SecretStorePath = Join-Path (Split-Path -Parent $ConfigPath) 'secrets.dpapi.json'
}
$SecretStorePath = [IO.Path]::GetFullPath($SecretStorePath)
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config file not found: $ConfigPath" }

$config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$secrets = if (Test-Path -LiteralPath $SecretStorePath) { Read-BridgeSecretStore -Path $SecretStorePath } else { @{} }
$mappings = @(
    @{ Secret = 'BotToken'; Object = $config; Property = 'BotToken' }
    @{ Secret = 'LiveStream.SourceUrl'; Object = $config.LiveStream; Property = 'SourceUrl' }
    @{ Secret = 'LiveStream.RtmpDestination'; Object = $config.LiveStream; Property = 'RtmpDestination' }
)
$migrated = @()
foreach ($mapping in $mappings) {
    if ($null -eq $mapping.Object -or $mapping.Object.PSObject.Properties.Match($mapping.Property).Count -eq 0) { continue }
    $value = [string]$mapping.Object.($mapping.Property)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^dpapi:') { continue }
    $secrets[$mapping.Secret] = $value
    $mapping.Object.($mapping.Property) = "dpapi:$($mapping.Secret)"
    $migrated += $mapping.Secret
}
if ($migrated.Count -eq 0 -and -not $Force) { throw 'No plaintext bridge secrets were found to migrate.' }
$settings = $config.Settings
if ($null -eq $settings) {
    $settings = [pscustomobject]@{}
    $config | Add-Member -NotePropertyName Settings -NotePropertyValue $settings -Force
}
$settings | Add-Member -NotePropertyName EnableDpapiSecrets -NotePropertyValue $true -Force

if ($PSCmdlet.ShouldProcess($ConfigPath, "Move $($migrated.Count) secret(s) to a CurrentUser DPAPI store")) {
    $backupPath = "$ConfigPath.pre-dpapi.bak"
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force -ErrorAction Stop
    Write-BridgeSecretStore -Path $SecretStorePath -Secrets $secrets
    $temporary = "$ConfigPath.dpapi.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $ConfigPath -Force -ErrorAction Stop
        Protect-BridgeConfigurationAcl -ConfigPath $ConfigPath
        Protect-BridgePathAcl -Path $SecretStorePath, $backupPath
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ Migrated = @($migrated); ConfigPath = $ConfigPath; SecretStorePath = $SecretStorePath; BackupPath = $backupPath }
}
