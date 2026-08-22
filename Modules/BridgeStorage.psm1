Set-StrictMode -Version Latest

function Write-BridgeValidatedJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    $temporary = "$Path.tmp"
    $backup = "$Path.bak"
    $backupTemporary = "$backup.tmp"
    try {
        $Json | ConvertFrom-Json -ErrorAction Stop | Out-Null
        $parent = Split-Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $temporary -Value $Json -Encoding utf8 -ErrorAction Stop
        Get-Content -LiteralPath $temporary -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        Copy-Item -LiteralPath $Path -Destination $backupTemporary -Force -ErrorAction Stop
        Move-Item -LiteralPath $backupTemporary -Destination $backup -Force -ErrorAction Stop
        return $true
    }
    catch {
        Remove-Item -LiteralPath $temporary, $backupTemporary -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Read-BridgeValidatedJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AsHashtable
    )
    $backup = "$Path.bak"
    $primaryError = ''
    if (Test-Path -LiteralPath $Path) {
        try {
            $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            $data = if ($AsHashtable) {
                $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            else { $text | ConvertFrom-Json -ErrorAction Stop }
            return [pscustomobject]@{ Data=$data; Recovered=$false }
        }
        catch { $primaryError = $_.Exception.Message }
    }
    if (-not (Test-Path -LiteralPath $backup)) {
        if ($primaryError) { throw "Primary JSON is invalid and no backup exists: $primaryError" }
        return $null
    }
    try {
        $backupText = Get-Content -LiteralPath $backup -Raw -ErrorAction Stop
        $data = if ($AsHashtable) {
            $backupText | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        else { $backupText | ConvertFrom-Json -ErrorAction Stop }
        $restoreTemporary = "$Path.restore.tmp"
        Set-Content -LiteralPath $restoreTemporary -Value $backupText -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $restoreTemporary -Destination $Path -Force -ErrorAction Stop
        return [pscustomobject]@{ Data=$data; Recovered=$true }
    }
    catch { throw "Primary and backup JSON are invalid: primary=$primaryError; backup=$($_.Exception.Message)" }
}

Export-ModuleMember -Function Write-BridgeValidatedJson, Read-BridgeValidatedJson
