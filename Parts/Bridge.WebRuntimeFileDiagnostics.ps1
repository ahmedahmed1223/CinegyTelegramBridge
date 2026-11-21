#requires -Version 7

$script:WebRuntimeFileDiagnostics = $null

function Get-WebRuntimeFileDiagnostics {
    param([System.Collections.IDictionary]$Arguments, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $checkedAt = $Now.ToUnixTimeMilliseconds()
    if ($script:WebRuntimeFileDiagnostics) {
        $ageMs = $checkedAt - $script:WebRuntimeFileDiagnostics.checkedAt
        if ($ageMs -ge 0 -and $ageMs -lt 30000) { return @{ ok = $true; data = $script:WebRuntimeFileDiagnostics } }
    }

    # This allowlist controls both file selection and the names exposed to the
    # browser. Raw paths, contents and diagnostic messages are never serialized.
    $kinds = @{
        'onair.json' = 'onair'; 'schedule.json' = 'schedule'; 'autohide.json' = 'autohide'
        'template-reminders.json' = 'reminders'; 'drafts.json' = 'drafts'; 'news-draft.json' = 'newsDraft'
        'favorites.json' = 'favorites'; 'user-profiles.json' = 'profiles'
    }
    $limit = 1MB
    $inputs = @(Get-BridgeRuntimeFiles | Where-Object { $kinds.ContainsKey($_.Name) } | Select-Object -First $kinds.Count)
    $items = @(if ($inputs.Count -gt 0) {
            foreach ($record in @(Get-RuntimeFileHealth -Files $inputs -MaxJsonBytes $limit)) {
                $state = [string]$record.State
                if ($state -cnotin 'healthy', 'absent', 'recoverable', 'broken', 'skipped', 'unreadable') { $state = 'unknown' }
                [ordered]@{
                    kind = $kinds[$record.Name]; state = $state
                    sizeKilobytes = [double]$record.SizeKB; modifiedAt = ConvertTo-AirStatusWidgetEpoch $record.ModifiedAt
                    hasBackup = [bool]$record.HasBackup
                }
            }
        })
    $script:WebRuntimeFileDiagnostics = @{ checkedAt = $checkedAt; parseLimitBytes = $limit; items = $items }
    return @{ ok = $true; data = $script:WebRuntimeFileDiagnostics }
}
