#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-NewsTickerConfiguredSnapshot {
    Get-NewsTickerSnapshot -Path ([string](Get-Setting 'NewsFilePath')) -Separator ([string](Get-Setting 'NewsItemSeparator')) `
        -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
}

function Save-NewsTickerDraft {
    if (-not $script:NewsTickerDraft) { return $false }
    try {
        $json = $script:NewsTickerDraft | ConvertTo-Json -Depth 8
        $parent = Split-Path -Parent $script:newsDraftFile
        if (-not (Test-Path -LiteralPath $parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $temp = "$script:newsDraftFile.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($true))
        [IO.File]::Move($temp, $script:newsDraftFile, $true)
        return $true
    } catch { Write-BridgeLog "Could not save news draft: $($_.Exception.Message)" 'ERROR'; return $false }
}

function Import-NewsTickerDraft {
    if (-not (Test-Path -LiteralPath $script:newsDraftFile)) { return }
    try { $script:NewsTickerDraft = Get-Content -LiteralPath $script:newsDraftFile -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-BridgeLog "Could not load news draft: $($_.Exception.Message)" 'WARN'; $script:NewsTickerDraft = $null }
}

function Get-NewsTickerDraft { param([long]$UserId = 0)
    if (-not $script:NewsTickerDraft) { return $null }
    if ($UserId -and [long]$script:NewsTickerDraft.OwnerUserId -ne $UserId) { return $null }
    return $script:NewsTickerDraft
}

function Remove-NewsTickerDraft {
    $script:NewsTickerDraft = $null
    Remove-Item -LiteralPath $script:newsDraftFile -Force -ErrorAction SilentlyContinue
}

function Start-NewsTickerDraft {
    param([long]$ChatId,[long]$UserId)
    if ($script:NewsTickerDraft) {
        if ([long]$script:NewsTickerDraft.OwnerUserId -eq $UserId) { return [pscustomobject]@{Success=$true;Draft=$script:NewsTickerDraft;Error=''} }
        return [pscustomobject]@{Success=$false;Draft=$null;Error="المسودة مقفلة حاليًا للمستخدم $($script:NewsTickerDraft.OwnerUserId)."}
    }
    $snapshot = Get-NewsTickerConfiguredSnapshot
    if (-not $snapshot.Success) { return [pscustomobject]@{Success=$false;Draft=$null;Error=$snapshot.Error} }
    $script:NewsTickerDraft = [ordered]@{ Id=[guid]::NewGuid().ToString('N');OwnerUserId=$UserId;OwnerChatId=$ChatId;CreatedAt=(Get-Date).ToString('o');UpdatedAt=(Get-Date).ToString('o');BaseHash=$snapshot.Hash;Items=@($snapshot.Items) }
    Save-NewsTickerDraft | Out-Null
    return [pscustomobject]@{Success=$true;Draft=$script:NewsTickerDraft;Error=''}
}

function Add-NewsTickerDraftItem { param([long]$UserId,[string]$Text)
    $draft = Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return $false }
    $parsed = ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems 1
    if (-not $parsed.Success -or @($parsed.Items).Count -ne 1) { return $false }
    # Newest first, because that is what a ticker is for: the item just typed
    # is the one that matters, and appending buried it behind however many
    # older items the draft already held. NewNewsItemAtTop turns it back into
    # an append for a rundown that is ordered by hand.
    $draft.Items = if (Get-Setting 'NewNewsItemAtTop') { @($parsed.Items) + @($draft.Items) }
    else { @($draft.Items) + @($parsed.Items) }
    $draft.UpdatedAt = (Get-Date).ToString('o'); return (Save-NewsTickerDraft)
}

function Update-NewsTickerDraftItem { param([long]$UserId,[int]$Index,[string]$Text)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count) { return $false }
    $parsed = ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems 1
    if (-not $parsed.Success -or @($parsed.Items).Count -ne 1) { return $false }
    $items = @($draft.Items)
    $items[$Index] = $parsed.Items[0]
    $draft.Items = $items
    $draft.UpdatedAt = (Get-Date).ToString('o')
    return (Save-NewsTickerDraft)
}

function Remove-NewsTickerDraftItem { param([long]$ChatId,[long]$UserId,[int]$Index)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count) { return $false }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -and -not (Get-Setting 'AllowOperatorsDeleteNews')) { return $false }
    $items = [Collections.Generic.List[string]]::new()
    @($draft.Items) | ForEach-Object { $items.Add([string]$_) }
    $items.RemoveAt($Index)
    $draft.Items = @($items)
    return (Save-NewsTickerDraft)
}

function Move-NewsTickerDraftItem { param([long]$UserId,[int]$Index,[int]$Delta)
    $draft = Get-NewsTickerDraft -UserId $UserId
    $target = $Index + $Delta
    if (-not $draft -or $Index -lt 0 -or $target -lt 0 -or $Index -ge @($draft.Items).Count -or $target -ge @($draft.Items).Count) { return $false }
    $items = @($draft.Items)
    $swap = $items[$target]
    $items[$target] = $items[$Index]
    $items[$Index] = $swap
    $draft.Items = $items
    $draft.UpdatedAt = (Get-Date).ToString('o')
    return (Save-NewsTickerDraft)
}

function Import-NewsTickerTextToDraft { param([long]$UserId,[string]$Text,[ValidateSet('replace','append')][string]$Mode='replace')
    $draft=Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return [pscustomobject]@{Success=$false;Error='لا توجد مسودة مملوكة لك.'} }
    $parsed=ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $parsed.Success) { return [pscustomobject]@{Success=$false;Error=($parsed.Errors -join ' ')} }
    $items = if ($Mode -eq 'append') { @($draft.Items)+@($parsed.Items) } else { @($parsed.Items) }
    $validated=ConvertFrom-NewsTickerText -Text (ConvertTo-NewsTickerText -Items $items -Separator ([string](Get-Setting 'NewsItemSeparator'))) -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $validated.Success) { return [pscustomobject]@{Success=$false;Error=($validated.Errors -join ' ')} }
    $draft.Items = @($validated.Items)
    $draft.UpdatedAt = (Get-Date).ToString('o')
    Save-NewsTickerDraft | Out-Null
    return [pscustomobject]@{Success=$true;Count=$draft.Items.Count;Error=''}
}

function Clear-NewsTickerDraftItems { param([long]$ChatId,[long]$UserId)
    if (-not (Get-NewsTickerDraft -UserId $UserId)) { return $false }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -and -not (Get-Setting 'AllowOperatorsClearAllNews')) { return $false }
    $script:NewsTickerDraft.Items = @()
    $script:NewsTickerDraft.UpdatedAt = (Get-Date).ToString('o')
    return (Save-NewsTickerDraft)
}

function Test-NewsSheetWriteConfigured {
    <# Write-back lives in config.json rather than in Settings, next to
       BotToken. The URL and its token together are the permission to rewrite
       the sheet, and Invoke-SettingsExport only ever writes the keys the
       bridge declares in DefaultSettings, so keeping them out of Settings is
       what keeps them out of an exported file forwarded into a chat. #>
    return -not [string]::IsNullOrWhiteSpace([string](Get-JsonProp $config 'NewsSheetWriteUrl'))
}

function Save-NewsSheetItems {
    <# Writes the published ticker back to the sheet, so the sheet stays the
       readable record even when the editing happened in Telegram.

       Posted to a Google Apps Script web app rather than the Sheets API on
       purpose: the API needs OAuth or a service-account key and RS256 JWT
       signing, none of which PowerShell does without dragging in a library.
       A deployed script is one HTTPS POST with a shared secret. #>
    param([AllowNull()][string[]]$Items = @())
    if (-not (Test-NewsSheetWriteConfigured)) {
        return [pscustomobject]@{ Success = $false; Attempted = $false; Error = '' }
    }
    $url = [string](Get-JsonProp $config 'NewsSheetWriteUrl')
    if ($url -notmatch '^https://') {
        return [pscustomobject]@{ Success = $false; Attempted = $false; Error = 'يجب أن يبدأ رابط الكتابة بـ https.' }
    }
    $payload = @{
        token = [string](Get-JsonProp $config 'NewsSheetWriteToken')
        items = @($Items | ForEach-Object { [string]$_ })
    } | ConvertTo-Json -Depth 4 -Compress
    try {
        $response = Invoke-WebRequest -Uri $url -Method Post -Body $payload `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec (Get-SettingInt 'NewsSheetTimeoutSeconds' 1) `
            -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        # Apps Script answers 200 for a rejected token too, so the body is the
        # only honest signal that the write actually happened.
        $body = [string]$response.Content
        if ($body -notmatch '"ok"\s*:\s*true') {
            return [pscustomobject]@{ Success = $false; Attempted = $true; Error = "رفض الشيت الكتابة: $(Protect-SensitiveText $body)" }
        }
        return [pscustomobject]@{ Success = $true; Attempted = $true; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Attempted = $true; Error = $_.Exception.Message }
    }
}

function Publish-NewsTickerDraft { param([long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    # Carries Conflict so every caller can branch on it uniformly; without it
    # $result.Conflict throws under StrictMode on this path.
    if (-not $draft) { return [pscustomobject]@{Success=$false;Conflict=$false;Error='لا توجد مسودة مملوكة لك.'} }
    $result = Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items @($draft.Items) -ExpectedHash ([string]$draft.BaseHash) -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if ($result.Success) {
        Add-AuditEntry "📰 نشر شريط الأخبار بواسطة $(Format-UserAuditActor -UserId $UserId): $(@($draft.Items).Count) خبرًا"
        Write-NewsPublishRecord -UserId $UserId -ItemCount (@($draft.Items).Count)
        # Mirror to the sheet after the ticker is safely on air, never before.
        # A sheet that refuses the write must not undo a publish that already
        # succeeded, so this reports and rolls nothing back.
        $mirror = Save-NewsSheetItems -Items @($draft.Items)
        $result | Add-Member -NotePropertyName 'SheetSaved' -NotePropertyValue ([bool]$mirror.Success) -Force
        $result | Add-Member -NotePropertyName 'SheetError' -NotePropertyValue ([string]$mirror.Error) -Force
        if ($mirror.Attempted -and -not $mirror.Success) {
            Write-BridgeLog "News published but the sheet write-back failed: $($mirror.Error)" 'WARN'
        }
        Remove-NewsTickerDraft
    }
    return $result
}

function Write-NewsPublishRecord {
    <# A structured sibling to the human audit line above. The reports screen
       needs a count per day per operator, and parsing that back out of an
       Arabic sentence would break the first time someone rewords it. #>
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][int]$ItemCount)
    Write-AuditRecord -OperationId "news-$([guid]::NewGuid().ToString('N'))" -EventName news_publish `
        -Result success -UserId $UserId -Action PUBLISH -Count $ItemCount `
        -Message "نشر شريط الأخبار"
}

function Resolve-NewsPublishConflict {
    <#
        Rebases a draft onto the ticker file as it is now.

        Another system writes this file too, so a conflict is the normal case
        rather than an accident, and refusing forever would make the bot
        useless for the ticker. What must not happen is a silent overwrite of
        the other writer's work - so this is only ever reached by an explicit
        choice, and it says exactly what will be dropped or kept.

        Mode 'replace' publishes the draft's items over whatever is there.
        Mode 'append' keeps the current live items and adds the draft's after
        them, which is what an operator adding a breaking line actually wants.
    #>
    param(
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][ValidateSet('replace', 'append')][string]$Mode
    )
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return [pscustomobject]@{Success=$false;Conflict=$false;Error='لا توجد مسودة مملوكة لك.'} }

    $live = Get-NewsTickerConfiguredSnapshot
    if (-not $live.Success) { return [pscustomobject]@{Success=$false;Conflict=$false;Error=$live.Error} }

    $items = if ($Mode -eq 'append') { @($live.Items) + @($draft.Items) } else { @($draft.Items) }
    # Rebase onto the hash we just read, so the publish below is checked
    # against the file as it is now rather than as it was yesterday.
    $draft.BaseHash = $live.Hash
    $draft.Items = @($items)
    $draft.UpdatedAt = (Get-Date).ToString('o')
    Save-NewsTickerDraft | Out-Null

    Write-BridgeLog "User $UserId rebased the news draft onto the live file ($Mode, $(@($items).Count) item(s))" 'WARN'
    return (Publish-NewsTickerDraft -UserId $UserId)
}

function Request-NewsLockRelease {
    <#
        Asks the current draft owner to hand the ticker over, and takes it if
        they do not answer in time.

        Without this the only way past someone else's draft was an
        administrator forcing it, which is the wrong tool: the usual case is
        an operator who went home with a draft open, and the person who needs
        the ticker now is another operator, not an admin. A silent grab would
        be worse - the owner may be mid-edit - so they get a window to say no,
        and only silence hands it over.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $draft = Get-NewsTickerDraft
    if (-not $draft) { return $false }
    if ([long]$draft.OwnerUserId -eq $UserId) { return $false }

    $existing = $script:NewsLockRequest
    if ($existing -and [long]$existing.RequesterUserId -ne $UserId) {
        Send-TelegramMessage -ChatId $ChatId -Text "⏳ يوجد طلب فكّ قفل قيد الانتظار من $(Get-UserDisplayName -UserId ([long]$existing.RequesterUserId)). انتظر نتيجته." -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }

    $minutes = [math]::Max(1, (Get-SettingInt 'NewsLockRequestMinutes' 1))
    $script:NewsLockRequest = @{
        RequesterUserId = $UserId; RequesterChatId = $ChatId
        OwnerUserId = [long]$draft.OwnerUserId; OwnerChatId = [long]$draft.OwnerChatId
        RequestedAt = (Get-Date)
    }
    Write-BridgeLog "User $UserId requested the news lock from $($draft.OwnerUserId) (auto-grant in $minutes min)"
    Add-AuditEntry "🔓 طلب فكّ قفل شريط الأخبار من $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)) بواسطة $(Format-UserAuditActor -UserId $UserId)"

    if ([long]$draft.OwnerChatId -gt 0) {
        Send-TelegramMessage -ChatId ([long]$draft.OwnerChatId) `
            -Text "🔓 يطلب $(Get-UserDisplayName -UserId $UserId) تحرير شريط الأخبار.`nلديك $minutes دقيقة للرد؛ بلا رد سيُمنح تلقائيًا وستُلغى مسودتك (سنرسل لك نصّها)." `
            -ReplyMarkup @{inline_keyboard=@(,@(
                    @{text='✅ سلّم القفل';callback_data='news:lockgrant'},
                    @{text='⛔ ما زلت أعمل';callback_data='news:lockdeny'}))}
    }
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ أُرسل الطلب إلى $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)). إن لم يردّ خلال $minutes دقيقة سيُمنح لك تلقائيًا." -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Complete-NewsLockRelease {
    <# Hands the ticker over. The owner's items are sent back to them as text
       before the draft goes: an unpublished draft is somebody's work, and
       either transferring it to another person or dropping it silently would
       be worse than handing it back. #>
    param([switch]$Denied, [string]$Reason = 'auto')
    $request = $script:NewsLockRequest
    if (-not $request) { return $false }
    $script:NewsLockRequest = $null

    if ($Denied) {
        Send-TelegramMessage -ChatId ([long]$request.RequesterChatId) -Text "⛔ رفض $(Get-UserDisplayName -UserId ([long]$request.OwnerUserId)) تسليم القفل؛ ما زال يعمل على المسودة."
        Write-BridgeLog "News lock request from $($request.RequesterUserId) was denied by $($request.OwnerUserId)"
        return $false
    }

    $draft = Get-NewsTickerDraft
    $items = @(if ($draft) { $draft.Items } else { @() })
    if ($draft -and [long]$request.OwnerChatId -gt 0 -and $items.Count -gt 0) {
        $position = 0
        $body = @($items | ForEach-Object { $position++; "$position. $_" }) -join "`n"
        Send-TelegramMessage -ChatId ([long]$request.OwnerChatId) -Text "📄 نصّ مسودتك قبل تسليم القفل ($($items.Count) خبرًا):`n$body"
    }
    if ($draft) { Remove-NewsTickerDraft }

    Write-BridgeLog "News lock handed to $($request.RequesterUserId) ($Reason)" 'WARN'
    Add-AuditEntry "🔓 سُلّم قفل شريط الأخبار إلى $(Get-UserDisplayName -UserId ([long]$request.RequesterUserId)) ($Reason)"
    if ([long]$request.OwnerChatId -gt 0) {
        Send-TelegramMessage -ChatId ([long]$request.OwnerChatId) -Text '🔓 سُلّم قفل شريط الأخبار وأُلغيت مسودتك.'
    }
    Send-TelegramMessage -ChatId ([long]$request.RequesterChatId) -Text '🔓 صار بإمكانك التحرير. اضغط ✏️ بدء التحرير للعمل على النص الحالي.' `
        -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId ([long]$request.RequesterChatId) -UserId ([long]$request.RequesterUserId))
    return $true
}

function Update-NewsLockRequest {
    <# Grants a pending request once its window has passed. Silence is the
       grant condition: an operator who has gone home cannot answer, and the
       ticker cannot wait for them. #>
    $request = $script:NewsLockRequest
    if (-not $request) { return }
    $minutes = [math]::Max(1, (Get-SettingInt 'NewsLockRequestMinutes' 1))
    if (((Get-Date) - [datetime]$request.RequestedAt).TotalMinutes -lt $minutes) { return }
    Complete-NewsLockRelease -Reason 'no reply within the window' | Out-Null
}

function Get-NewsSheetConfirmPrompt {
    <# One prompt carrying every fact that matters, rather than a generic
       "are you sure" followed by a second warning about the draft owner. Both
       pulls overwrite something, and since the pull is open to operators a
       stray tap must not be enough to rewrite the ticker. #>
    param([ValidateSet('air', 'draft')][string]$Target = 'air')
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Target -eq 'air') {
        $lines.Add('⚠️ سحب الشيت ونشره على الهواء مباشرة؟')
        $snapshot = Get-NewsTickerConfiguredSnapshot
        if ($snapshot.Success) { $lines.Add("سيستبدل $(@($snapshot.Items).Count) خبرًا على الشريط الآن.") }
    }
    else {
        $lines.Add('⚠️ تحميل الشيت في المسودة للمراجعة؟')
        $lines.Add('لن يصل الهواء شيء قبل أن تضغط «مراجعة ونشر».')
    }
    $draft = Get-NewsTickerDraft
    if ($draft) { $lines.Add("🔒 المسودة الحالية بيد $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId))، وسيُستبدل محتواها.") }
    return ($lines -join "`n")
}

function Get-NewsSheetConfirmKeyboard {
    param([ValidateSet('air', 'draft')][string]$Target = 'air')
    $go = if ($Target -eq 'air') { @{text='✅ نعم، انشر';callback_data='news:sheetconfirm';style='danger'} }
    else { @{text='✅ نعم، حمّل المسودة';callback_data='news:sheetdraftconfirm';style='success'} }
    return @{inline_keyboard=@(,@($go, @{text='❌ إلغاء';callback_data='news:refresh'}))}
}

function Test-NewsSheetPullAccess {
    <# Who may pull the sheet. Open to every authorised operator by default:
       the content is whatever the newsroom sheet already says, so a pull
       publishes editorial copy rather than anything the presser typed. Set
       AllowOperatorsSheetPull to false to put it back behind the administrator
       bar, the same way the other AllowOperators* news switches work. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (Test-Admin -ChatId $ChatId -UserId $UserId) { return $true }
    return [bool](Get-Setting 'AllowOperatorsSheetPull')
}

function Get-NewsSheetCsvText {
    <# Downloads the sheet's CSV export. The content ends up on air, so this is
       a trust boundary: https only, a byte cap so a runaway document cannot
       exhaust memory, and a bounded timeout so a hung request cannot stall
       the tick. #>
    param(
        [AllowEmptyString()][string]$Url = '',
        [int]$TimeoutSeconds = 30,
        [int]$MaxBytes = 1048576
    )
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{ Success = $false; Csv = ''; Error = 'لم يُضبط رابط الشيت.' }
    }
    if ($Url -notmatch '^https://') {
        return [pscustomobject]@{ Success = $false; Csv = ''; Error = 'يجب أن يبدأ رابط الشيت بـ https.' }
    }
    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec ([math]::Max(1, $TimeoutSeconds)) `
            -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        $bytes = $response.Content -as [byte[]]
        if ($null -eq $bytes) { $bytes = [Text.Encoding]::UTF8.GetBytes([string]$response.Content) }
        if ($bytes.Length -gt $MaxBytes) {
            return [pscustomobject]@{ Success = $false; Csv = ''; Error = "حجم الشيت يتجاوز الحد المسموح ($MaxBytes بايت)." }
        }
        # Sheets serves UTF-8; decoding explicitly keeps Arabic intact whatever
        # the response headers claim.
        $csv = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        return [pscustomobject]@{ Success = $true; Csv = $csv; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Csv = ''; Error = $_.Exception.Message }
    }
}

function Get-NewsSheetChangeSummary {
    <# Order counts: the ticker reads in sequence, so moving the lead story is
       a real change even when the set of headlines is identical. #>
    param([AllowNull()][string[]]$Before = @(), [AllowNull()][string[]]$After = @())
    $previous = @($Before)
    $current = @($After)
    $previousSet = [Collections.Generic.HashSet[string]]::new([string[]]$previous, [StringComparer]::Ordinal)
    $currentSet = [Collections.Generic.HashSet[string]]::new([string[]]$current, [StringComparer]::Ordinal)
    $added = @($current | Where-Object { -not $previousSet.Contains($_) }).Count
    $removed = @($previous | Where-Object { -not $currentSet.Contains($_) }).Count
    $changed = ($previous -join [char]0x001F) -cne ($current -join [char]0x001F)
    return [pscustomobject]@{ Added = $added; Removed = $removed; Changed = $changed; Total = $current.Count }
}

function Get-NewsSheetNoticeText {
    param($Summary, [string]$Trigger = 'auto', [long]$UserId = 0)
    $source = if ($Trigger -eq 'manual' -and $UserId) { "يدويًا بواسطة $(Get-UserDisplayName -UserId $UserId)" } else { 'تلقائيًا' }
    $lines = @(
        "📰 حُدِّث الشريط من الشيت $source"
        "الآن على الهواء: $($Summary.Total) خبرًا"
    )
    if ($Summary.Added -gt 0) { $lines += "جديد: $($Summary.Added)" }
    if ($Summary.Removed -gt 0) { $lines += "أُزيل: $($Summary.Removed)" }
    if ($Summary.Added -eq 0 -and $Summary.Removed -eq 0) { $lines += 'تغيّر الترتيب فقط' }
    return ($lines -join "`n")
}

function Get-NewsSheetNoticeAudience {
    <# Who hears that the ticker changed. Administrators by default: they own
       the sheet and are the ones who would have to undo a bad publish. "all"
       adds every authorised chat, for a newsroom that wants the whole desk to
       see what went out. #>
    param([string]$Scope = '')
    if ([string]::IsNullOrWhiteSpace($Scope)) { $Scope = [string](Get-Setting 'NewsSheetNotifyScope') }
    if ($Scope -eq 'none') { return @() }
    $admins = @(@(Get-JsonProp $config 'AdminChatIds') | ForEach-Object { [long]$_ })
    if ($Scope -ne 'all') { return @($admins) }
    $everyone = @(@(Get-JsonProp $config 'AllowedChatIds') | ForEach-Object { [long]$_ })
    return @(@($admins + $everyone) | Sort-Object -Unique)
}

function Send-NewsSheetNotice {
    param([Parameter(Mandatory)][string]$Text)
    foreach ($chat in @(Get-NewsSheetNoticeAudience)) {
        Send-TelegramMessage -ChatId ([long]$chat) -Text $Text
    }
}

function Invoke-NewsSheetSync {
    <# Pulls the sheet and publishes it through the same validated, atomic
       writer the Telegram screens use, so the sheet cannot race a person:
       one publisher, one backup trail, one hash check.

       An automatic run yields to anyone holding the draft. Overwriting a
       half-typed draft destroys work the operator cannot get back and gives
       them no clue why. A manual run is a deliberate act, so it proceeds -
       but it still names the current owner and asks first. #>
    param(
        [ValidateSet('auto', 'manual')][string]$Trigger = 'manual',
        [ValidateSet('air', 'draft')][string]$Target = 'air',
        [long]$UserId = 0,
        [long]$ChatId = 0,
        [switch]$Confirmed
    )
    $stop = { param([string]$Message, [bool]$Skip = $false, [bool]$Ask = $false)
        [pscustomobject]@{ Success = $false; Skipped = $Skip; Unchanged = $false; Drafted = $false
            NeedsConfirmation = $Ask; Items = @(); Summary = $null; Error = $Message } }
    # A draft belongs to somebody. An unattended run has no owner to give it
    # to, so the review target is a deliberate act by a named person.
    if ($Target -eq 'draft' -and $UserId -le 0) { return (& $stop 'السحب إلى المسودة يحتاج مستخدمًا معروفًا.') }

    $url = [string](Get-Setting 'NewsSheetCsvUrl')
    if ([string]::IsNullOrWhiteSpace($url)) { return (& $stop 'لم يُضبط رابط Google Sheets في الإعدادات.') }

    $draft = Get-NewsTickerDraft
    if ($draft) {
        $owner = [long]$draft.OwnerUserId
        if ($Trigger -eq 'auto') {
            Write-BridgeLog "News sheet sync skipped: draft held by user $owner" 'WARN'
            return (& $stop 'مسودة الأخبار قيد التحرير؛ تُخطّيت هذه الدورة.' $true $false)
        }
        if ($owner -ne $UserId) {
            # Breaking somebody else's lock is an administrator action
            # everywhere else in the news screens, and a sheet pull destroys
            # that draft just as surely as 🔓 إلغاء القفل does. An operator is
            # pointed at the request instead, which the owner answers.
            if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
                return (& $stop "المسودة بيد $(Get-UserDisplayName -UserId $owner). استخدم «🔓 طلب فكّ القفل» أو اطلب من مشرف.")
            }
            if (-not $Confirmed) {
                return (& $stop "المسودة بيد $(Get-UserDisplayName -UserId $owner). التأكيد يستبدلها بمحتوى الشيت." $false $true)
            }
        }
    }

    $download = Get-NewsSheetCsvText -Url $url `
        -TimeoutSeconds (Get-SettingInt 'NewsSheetTimeoutSeconds' 1) `
        -MaxBytes (Get-SettingInt 'NewsImportMaxBytes' 1)
    if (-not $download.Success) {
        Write-BridgeLog "News sheet download failed: $($download.Error)" 'ERROR'
        return (& $stop "تعذّر تنزيل الشيت: $($download.Error)")
    }

    $items = @(ConvertFrom-NewsSheetCsv -Csv $download.Csv)
    if ($items.Count -eq 0) {
        # A sheet that failed to render, or one somebody cleared by accident,
        # must not take the ticker off air with it. Clearing stays a manual,
        # confirmed action on the news screen.
        return (& $stop 'الشيت فارغ؛ لن يُمسح الشريط تلقائيًا. امسحه يدويًا إن كان هذا مقصودًا.')
    }

    $snapshot = Get-NewsTickerConfiguredSnapshot
    $current = if ($snapshot.Success) { @($snapshot.Items) } else { @() }
    $summary = Get-NewsSheetChangeSummary -Before $current -After $items

    if ($Target -eq 'draft') {
        # Straight into the draft so the sheet can be read, reordered, or
        # corrected before any of it reaches air. Routed through the ordinary
        # draft import so the same length, count, and duplicate rules apply.
        if ($draft -and [long]$draft.OwnerUserId -ne $UserId) { Remove-NewsTickerDraft }
        if (-not (Get-NewsTickerDraft -UserId $UserId)) {
            $started = Start-NewsTickerDraft -ChatId $ChatId -UserId $UserId
            if (-not $started.Success) { return (& $stop $started.Error) }
        }
        $text = ConvertTo-NewsTickerText -Items $items -Separator ([string](Get-Setting 'NewsItemSeparator'))
        $import = Import-NewsTickerTextToDraft -UserId $UserId -Text $text -Mode replace
        if (-not $import.Success) { return (& $stop "تعذّر تحميل الشيت في المسودة: $($import.Error)") }
        return [pscustomobject]@{ Success = $true; Skipped = $false; Unchanged = $false; Drafted = $true
            NeedsConfirmation = $false; Items = $items; Summary = $summary; Error = '' }
    }

    if (-not $summary.Changed) {
        return [pscustomobject]@{ Success = $false; Skipped = $false; Unchanged = $true; Drafted = $false
            NeedsConfirmation = $false; Items = $items; Summary = $summary; Error = '' }
    }

    $result = Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items $items `
        -ExpectedHash ([string]$snapshot.Hash) -Separator ([string](Get-Setting 'NewsItemSeparator')) `
        -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) `
        -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $result.Success) {
        Write-BridgeLog "News sheet publish failed: $($result.Error)" 'ERROR'
        return (& $stop "تعذّر نشر الشيت: $($result.Error)")
    }

    if ($draft) { Remove-NewsTickerDraft }
    $who = if ($Trigger -eq 'manual' -and $UserId) { Get-UserDisplayName -UserId $UserId } else { 'المزامنة التلقائية' }
    Add-AuditEntry "📰 نشر شريط الأخبار من الشيت ($who): $($items.Count) خبرًا"
    Write-NewsPublishRecord -UserId $UserId -ItemCount $items.Count
    Send-NewsSheetNotice -Text (Get-NewsSheetNoticeText -Summary $summary -Trigger $Trigger -UserId $UserId)

    return [pscustomobject]@{ Success = $true; Skipped = $false; Unchanged = $false; Drafted = $false
        NeedsConfirmation = $false; Items = $items; Summary = $summary; Error = '' }
}

function Get-NewsTickerManagementKeyboard { param([long]$ChatId,[long]$UserId)
    $rows = @()
    $draft = Get-NewsTickerDraft
    if (-not $draft) {
        $rows += , @(@{text='✏️ بدء التحرير';callback_data='news:start'}, @{text='📥 استيراد TXT';callback_data='news:import'})
    }
    elseif ([long]$draft.OwnerUserId -eq $UserId) {
        $rows += , @(@{text='➕ إضافة خبر';callback_data='news:add'}, @{text='📝 تعديل وترتيب';callback_data='news:list'})
        $rows += , @(@{text='📥 استيراد TXT';callback_data='news:import'}, @{text='👁 معاينة';callback_data='news:preview'})
        if ((Test-Admin -ChatId $ChatId -UserId $UserId) -or (Get-Setting 'AllowOperatorsClearAllNews')) {
            $rows += , @((New-BridgeButton -Text '🧹 مسح الكل' -CallbackData 'news:clear' -Style 'danger'))
        }
        # The publish/discard row is the one place on this screen where a
        # mis-tap costs work, so it is the one place colour earns its keep.
        $rows += , @((New-BridgeButton -Text '✅ مراجعة ونشر' -CallbackData 'news:publish' -Style 'success'),
            (New-BridgeButton -Text '🗑 إلغاء المسودة' -CallbackData 'news:cancel' -Style 'danger'))
    }
    else {
        $rows += , @(@{text="🔒 لدى $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId))";callback_data='news:refresh'})
        $rows += , @(@{text='🔓 طلب فكّ القفل';callback_data='news:lockrequest'})
        if (Test-Admin -ChatId $ChatId -UserId $UserId) {
            $rows += , @(@{text='🔓 إلغاء القفل (مشرف)';callback_data='news:unlock'})
        }
    }
    if ((Test-Admin -ChatId $ChatId -UserId $UserId) -or (Get-Setting 'AllowOperatorsRestoreNews')) {
        $rows += , @(@{text='🕘 النسخ والاستعادة';callback_data='news:backups'})
    }
    $lockedByOther = $draft -and [long]$draft.OwnerUserId -ne $UserId -and -not (Test-Admin -ChatId $ChatId -UserId $UserId)
    if (-not $lockedByOther -and (Test-NewsSheetPullAccess -ChatId $ChatId -UserId $UserId) -and -not [string]::IsNullOrWhiteSpace([string](Get-Setting 'NewsSheetCsvUrl'))) {
        $rows += , @(@{text='⬇️ سحب ونشر';callback_data='news:sheet'}, @{text='📝 سحب إلى المسودة';callback_data='news:sheetdraft'})
    }
    $rows += , @(@{text='🔄 تحديث';callback_data='news:refresh'}, @{text='⬅️ الرئيسية';callback_data='menu'})
    return @{inline_keyboard=$rows}
}

function Edit-TelegramMessageText {
    <# Edits an existing message in place so interactive screens (e.g. the
       news reorder list) never pile up duplicate messages with stale
       buttons. Falls back to returning $false so callers can resend. #>
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][int]$MessageId,
        [Parameter(Mandatory)][string]$Text,[hashtable]$ReplyMarkup,
        [ValidateSet('', 'HTML')][string]$ParseMode = '')
    $body = @{ chat_id = $ChatId; message_id = $MessageId; text = $Text }
    if ($ParseMode) { $body.parse_mode = $ParseMode }
    if ($ReplyMarkup) { $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/editMessageText" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
    if (-not $request.Success) { Write-BridgeLog "Failed to edit Telegram message ${MessageId}: $($request.Error)" "WARN"; return $false }
    return $true
}

function Show-NewsTickerDeleteConfirm {
    <# Deleting used to happen on the first tap. A news item is text somebody
       typed, and the list is scrolled with a thumb, so a mis-tap silently
       lost work. The confirmation shows the item being removed - the number
       alone is not enough to recognise it. #>
    param([long]$ChatId, [long]$UserId, [int]$Index, [int]$MessageId = 0)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count) { return $false }
    $item = [string]$draft.Items[$Index]
    $preview = if ($item.Length -gt 200) { $item.Substring(0, 200) + '…' } else { $item }
    $text = "🗑 تأكيد حذف الخبر $($Index + 1) من $(@($draft.Items).Count):`n`n$preview"
    $markup = @{inline_keyboard=@(
            , @((New-BridgeButton -Text '🗑 نعم، احذف' -CallbackData "news:delete:$Index" -Style 'danger'),
                (New-BridgeButton -Text '❌ إلغاء' -CallbackData "news:item:$Index")))}
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $markup)) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $markup
    return $true
}

function Show-NewsTickerItemScreen { param([long]$ChatId,[long]$UserId,[int]$Index,[int]$MessageId=0)
    <# One message per news item: full text in the body, move/edit/delete
       buttons carrying the item's CURRENT index. Re-rendered in place after
       every move so the buttons can never point at a stale index. #>
    $draft=Get-NewsTickerDraft -UserId $UserId;if(-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count){return}
    $count=@($draft.Items).Count
    # The arrows are disabled rather than hidden at the ends: a row that loses
    # a button changes width, and the screen appears to shift under the thumb
    # between one item and the next.
    $up = if ($Index -gt 0) { New-BridgeButton -Text '⬆️ تحريك لأعلى' -CallbackData "news:iup:$Index" }
          else { New-BridgeButton -Text '⬆️ تحريك لأعلى' -Disabled }
    $down = if ($Index -lt ($count - 1)) { New-BridgeButton -Text '⬇️ تحريك لأسفل' -CallbackData "news:idown:$Index" }
            else { New-BridgeButton -Text '⬇️ تحريك لأسفل' -Disabled }
    $rows=@(,@($up,$down))
    $rows+=,@((New-BridgeButton -Text '✏️ تعديل' -CallbackData "news:edit:$Index"),
        (New-BridgeButton -Text '🗑 حذف' -CallbackData "news:delask:$Index" -Style 'danger'))
    $rows+=,@(@{text='⬅️ رجوع للترتيب';callback_data='news:list'})
    $text="📰 الخبر $($Index+1) من ${count}:`n`n$($draft.Items[$Index])"
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup @{inline_keyboard=$rows})){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup @{inline_keyboard=$rows}
}

function Get-NewsListLayout {
    <# How the reorder screen renders one item:
         text    - the headline in the message body, a compact button row.
         stacked - the headline on its own button, controls on the row under it.
         inline  - the headline in the row beside its controls.
         compact - one numbered button per item, controls in the item screen;
                   the only shape that fits thirty items on one screen.
       Telegram splits a row's width equally between its buttons, so inline
       gives a headline a quarter of the screen; it stays available because
       it is the most compact of the three. #>
    $layout = [string](Get-Setting 'NewsListLayout')
    if ($layout -notin @('text', 'stacked', 'inline', 'compact')) { return 'text' }
    return $layout
}

function Get-NewsTickerPageSize {
    <#
        How many items one screen of the reorder list may carry.

        NewsListPaged off means "one long list", but that is a cap and not a
        promise: Telegram rejects an over-large keyboard outright, and a
        rejected edit looks exactly like a list that will not update - which
        is how a 38-item draft came to read as "the last items are missing".
        The long list therefore runs to the button budget and still pages
        beyond it, rather than reviving the bug paging was added to fix.

        One helper rather than the same arithmetic in the keyboard, the text
        and the page count: three copies were three chances to disagree about
        where a page ends.
    #>
    # Telegram's practical ceiling is around a hundred buttons. Staying well
    # under it leaves room for the navigation row and the add/back row.
    $buttonBudget = 90
    $perItem = switch (Get-NewsListLayout) { 'stacked' { 5 } 'compact' { 1 } default { 4 } }
    $maxItems = [math]::Max(3, [math]::Floor(($buttonBudget - 5) / $perItem))
    # Compact could fit eighty-five buttons, but every one of them also needs
    # a readable line in the message above, and eighty-five lines share the
    # message budget down to nothing. Forty keeps a line worth reading.
    if ($perItem -eq 1) { $maxItems = [math]::Min($maxItems, 40) }

    if (-not (Get-Setting 'NewsListPaged')) { return $maxItems }
    return [math]::Max(3, [math]::Min($maxItems, (Get-SettingInt 'NewsListPageSize' 10)))
}

function Get-NewsTickerPageCount { param([long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return 1 }
    return [math]::Max(1, [math]::Ceiling(@($draft.Items).Count / (Get-NewsTickerPageSize)))
}

function Get-NewsTickerReorderKeyboard { param([long]$UserId, [int]$Page = 0)
    <#
        One row per item on the current page: the numbered label opens the
        editor, arrows move it, the bin deletes it.

        Paginated because Telegram refuses an over-large keyboard outright. A
        38-item draft rendered 152 buttons; the edit was rejected, the resend
        was rejected for the same reason, and the operator simply saw a list
        that would not update - which reads as "the last items are missing".
        Indexes stay absolute, so every move and delete callback is unchanged
        by paging.
    #>
    $draft = Get-NewsTickerDraft -UserId $UserId
    $rows = @()
    if (-not $draft) {
        $rows += , @(@{text='لا توجد مسودة مملوكة لك'; callback_data='news:refresh'})
        $rows += , @(@{text='⬅️ إدارة الأخبار'; callback_data='news:refresh'})
        return @{inline_keyboard=$rows}
    }

    $count = @($draft.Items).Count
    $size = Get-NewsTickerPageSize
    $pages = [math]::Max(1, [math]::Ceiling($count / $size))
    if ($Page -lt 0) { $Page = 0 }
    if ($Page -ge $pages) { $Page = $pages - 1 }
    $first = $Page * $size
    $last = [math]::Min($count - 1, $first + $size - 1)
    $stackedMax = [math]::Max(8, (Get-SettingInt 'NewsListStackedLabelLength' 8))
    $inlineMax = [math]::Max(8, (Get-SettingInt 'NewsListLabelLength' 8))
    $layout = Get-NewsListLayout
    $numbers = @()

    for ($i = $first; $i -le $last; $i++) {
        if ($layout -eq 'stacked') {
            # Telegram gives a button no colour, border or spacing, so the
            # only way to say "these four belong to that headline" is the
            # label itself: the number rides on every control, and the marker
            # alternates so consecutive items read as separate bands.
            $number = $i + 1
            $marker = if ($i % 2 -eq 0) { '▪️' } else { '▫️' }
            $fullLabel = "$marker $number. $($draft.Items[$i])"
            if ($fullLabel.Length -gt $stackedMax) { $fullLabel = $fullLabel.Substring(0, $stackedMax - 1) + '…' }
            $rows += , @(@{text=$fullLabel; callback_data="news:item:$i"})
            $controls = @()
            if ($i -gt 0) { $controls += , (New-BridgeButton -Text "⬆️ $number" -CallbackData "news:up:$i") }
            if ($i -lt ($count - 1)) { $controls += , (New-BridgeButton -Text "⬇️ $number" -CallbackData "news:down:$i") }
            $controls += , (New-BridgeButton -Text "✏️ $number" -CallbackData "news:edit:$i")
            $controls += , (New-BridgeButton -Text "🗑 $number" -CallbackData "news:delask:$i" -Style 'danger')
            $rows += , @($controls)
            continue
        }
        if ($layout -eq 'compact') {
            # One button per item is what makes thirty of them fit: the
            # controls live in the item screen the number opens, and the
            # headline itself is in the message text above.
            $numbers += , @{text="$($i + 1)"; callback_data="news:item:$i"}
            if ($numbers.Count -eq 5) { $rows += , @($numbers); $numbers = @() }
            continue
        }
        if ($layout -eq 'inline') {
            $label = "$($i + 1). $($draft.Items[$i])"
            if ($label.Length -gt $inlineMax) { $label = $label.Substring(0, $inlineMax - 1) + '…' }
            $row = @()
            if ($i -gt 0) { $row += , (New-BridgeButton -Text '⬆️' -CallbackData "news:up:$i") }
            $row += , (New-BridgeButton -Text $label -CallbackData "news:item:$i")
            if ($i -lt ($count - 1)) { $row += , (New-BridgeButton -Text '⬇️' -CallbackData "news:down:$i") }
            $row += , (New-BridgeButton -Text '🗑' -CallbackData "news:delask:$i" -Style 'danger')
            $rows += , @($row)
            continue
        }

        # The headline is in the message text above, not in this button.
        # Telegram splits a row's width equally between its buttons, so a
        # headline sharing a row with three controls only ever got a quarter
        # of the screen and wrapped into three lines. And the row kept a
        # fixed four buttons: dropping the arrow at either end gave those two
        # rows a third of the width each and made them render taller than the
        # rest, which is what read as items of different sizes.
        #
        # The two end placeholders are real disabled buttons now (Bot API
        # 10.3) instead of a live callback pointing at a no-op handler: the
        # first item's ⬆️ and the last item's ⬇️ were pressable, answered,
        # and did nothing, which is indistinguishable from a bridge that
        # dropped the press. 'news:noop' is still routed - buttons live on in
        # messages Telegram already delivered.
        $row = @()
        $row += , (New-BridgeButton -Text "$($i + 1)" -CallbackData "news:item:$i")
        if ($i -gt 0) { $row += , (New-BridgeButton -Text '⬆️' -CallbackData "news:up:$i") }
        else { $row += , (New-BridgeButton -Text '▫️' -Disabled) }
        if ($i -lt ($count - 1)) { $row += , (New-BridgeButton -Text '⬇️' -CallbackData "news:down:$i") }
        else { $row += , (New-BridgeButton -Text '▫️' -Disabled) }
        $row += , (New-BridgeButton -Text '🗑' -CallbackData "news:delask:$i" -Style 'danger')
        $rows += , @($row)
    }

    if ($numbers.Count -gt 0) { $rows += , @($numbers) }

    if ($pages -gt 1) {
        $nav = @()
        if ($Page -gt 0) { $nav += , @{text='◀️ السابق'; callback_data="news:list:$($Page - 1)"} }
        $nav += , @{text="صفحة $($Page + 1)/$pages"; callback_data="news:list:$Page"}
        if ($Page -lt ($pages - 1)) { $nav += , @{text='التالي ▶️'; callback_data="news:list:$($Page + 1)"} }
        $rows += , @($nav)
    }
    $rows += , @(@{text='➕ إضافة خبر'; callback_data='news:add'}, @{text='⬅️ إدارة الأخبار'; callback_data='news:refresh'})
    return @{inline_keyboard=$rows}
}

function Get-NewsListEscapedLine {
    <#
        One listing line, escaped, guaranteed to fit MaxLength AFTER escaping.

        Shortening the raw headline and escaping the result - rather than
        escaping and then cutting - is the whole point: cutting escaped text
        can land inside '&amp;' and leave '&am', which is not an entity, and
        Telegram rejects the entire message rather than the one line.

        The loop shrinks in proportion to the overshoot, so it converges in a
        step or two even for a headline that is nothing but ampersands.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Item, [Parameter(Mandatory)][int]$MaxLength)
    $raw = $Item
    $ellipsis = ''
    if ($raw.Length -gt $MaxLength) { $raw = $raw.Substring(0, $MaxLength - 1); $ellipsis = '…' }
    $escaped = ConvertTo-TelegramHtmlText -Text $raw
    while (($escaped.Length + $ellipsis.Length) -gt $MaxLength -and $raw.Length -gt 1) {
        $keep = [math]::Floor($raw.Length * ($MaxLength - 1) / $escaped.Length)
        if ($keep -ge $raw.Length) { $keep = $raw.Length - 1 }
        $raw = $raw.Substring(0, [math]::Max(1, $keep))
        $escaped = ConvertTo-TelegramHtmlText -Text $raw
        $ellipsis = '…'
    }
    return "$escaped$ellipsis"
}

function Get-NewsTickerReorderText { param([long]$UserId, [int]$Page = 0)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return "📝 الترتيب والتعديل`n`n⚠️ لا توجد مسودة مملوكة لك." }

    $count = @($draft.Items).Count
    $size = Get-NewsTickerPageSize
    $pages = [math]::Max(1, [math]::Ceiling($count / $size))
    if ($Page -lt 0) { $Page = 0 }
    if ($Page -ge $pages) { $Page = $pages - 1 }
    $first = $Page * $size + 1
    $last = [math]::Min($count, $first + $size - 1)

    $lines = [System.Collections.Generic.List[string]]::new()
    # Sent with parse_mode=HTML, so every literal < > & below must already be
    # escaped and every headline must go through ConvertTo-TelegramHtmlText.
    $lines.Add('<b>📝 ترتيب المسودة</b>')
    $lines.Add("الأخبار: <b>$count</b>")
    if ($pages -gt 1) { $lines.Add("المعروض: $first–$last  ·  صفحة $($Page + 1) من $pages") }
    # Said plainly, because the operator asked for one long list and is
    # getting pages anyway: the reason is Telegram's limit, not the setting
    # being ignored.
    if ($pages -gt 1 -and -not (Get-Setting 'NewsListPaged')) {
        $lines.Add("القائمة الطويلة مفعّلة، لكن تيليجرام لا يقبل أكثر من $size خبرًا في شاشة واحدة.")
    }
    $layout = Get-NewsListLayout
    if ($layout -in @('text', 'compact')) {
        # Here rather than in a button: a button shares its row's width with
        # the controls beside it, while this line has the whole message and
        # wraps by itself. Capped so a long draft cannot push the message
        # past what Telegram will send.
        $items = @($draft.Items)
        # The budget is measured AFTER escaping, and against the bridge's own
        # send limit rather than a number of its own. Escaping only ever grows
        # text - one '&' becomes five characters - so a page of headlines like
        # "AT&T" measured before escaping came out at 6000 characters against
        # a 3500 limit, split into two chunks, and lost its parse mode: the
        # operator got '<b>' and '<blockquote expandable>' as visible text.
        # 900 leaves room for the heading, the hint and the quotation tags.
        $pageBudget = [math]::Max(400, $script:TelegramTextLimit - 900)
        $lineMax = [math]::Min(
            [math]::Max(40, (Get-SettingInt 'NewsListLabelLength' 8)),
            [math]::Max(40, [math]::Floor($pageBudget / $size)))
        $lines.Add('')
        # An expandable block quotation (Bot API 7.6) collapses the listing to
        # a few lines with a "show more" of Telegram's own, so a forty-item
        # page no longer pushes its own keyboard off the screen. The character
        # budget still applies: expandable governs height, not length.
        $body = [System.Collections.Generic.List[string]]::new()
        for ($i = $first; $i -le $last; $i++) {
            $body.Add("<b>$i.</b> $(Get-NewsListEscapedLine -Item ([string]$items[$i - 1]) -MaxLength $lineMax)")
        }
        $lines.Add("<blockquote expandable>$($body -join "`n")</blockquote>")
    }

    $lines.Add('')
    $lines.Add($(switch ($layout) {
                'stacked' { 'أزرار كل خبر أسفله: ⬆️ ⬇️ ترتيب · ✏️ تعديل · 🗑 حذف' }
                'inline'  { '⬆️ ⬇️ للترتيب · اضغط النص للتعديل · 🗑 للحذف' }
                'compact' { 'اضغط رقم الخبر: الترتيب والتعديل والحذف في شاشته' }
                default   { 'الرقم يفتح الخبر للتعديل · ⬆️ ⬇️ للترتيب · 🗑 للحذف' }
            }))
    return ($lines -join "`n")
}

function Show-NewsTickerReorderScreen { param([long]$ChatId,[long]$UserId,[int]$MessageId=0,[int]$Page=0)
    <# Edits the originating message when possible so repeated ⬆️/⬇️ presses
       reuse a single message instead of flooding the chat with stale lists. #>
    $text=Get-NewsTickerReorderText -UserId $UserId -Page $Page;$kb=Get-NewsTickerReorderKeyboard -UserId $UserId -Page $Page
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $kb -ParseMode 'HTML')){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $kb -ParseMode 'HTML'
}

function Get-NewsTickerBackupsKeyboard {
    $rows=@();$files=@(Get-ChildItem -LiteralPath $script:newsBackupDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 10)
    for($i=0;$i-lt $files.Count;$i++){$rows+=,@(@{text=$files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss');callback_data="news:restore:$i"})};$rows+=,@(@{text='⬅️ إدارة الأخبار';callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Get-NewsTickerItemsKeyboard { param([long]$UserId)
    $draft=Get-NewsTickerDraft -UserId $UserId;$rows=@();if($draft){for($i=0;$i-lt @($draft.Items).Count;$i++){$label="$(($i+1)). $($draft.Items[$i])";if($label.Length-gt 35){$label=$label.Substring(0,34)+'…'};$rows+=,@(@{text=$label;callback_data="news:item:$i"})}}
    $rows+=,@(@{text='⬅️ إدارة الأخبار';callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Show-NewsTickerManagementScreen { param([long]$ChatId,[long]$UserId)
    $snapshot=Get-NewsTickerConfiguredSnapshot
    $text=if($snapshot.Success){"📰 إدارة شريط الأخبار`nالحالي: $(@($snapshot.Items).Count) خبرًا."}else{"⚠️ تعذر قراءة ملف الأخبار: $($snapshot.Error)"}
    if($script:NewsTickerDraft){$text+="`nالمسودة مقفلة للمستخدم $($script:NewsTickerDraft.OwnerUserId) وتحتوي $(@($script:NewsTickerDraft.Items).Count) خبرًا."}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-NewsTickerAddText { param([long]$ChatId,[long]$UserId,[string]$Value)
    Clear-PendingState -ChatId $ChatId
    $ok=Add-NewsTickerDraftItem -UserId $UserId -Text $Value
    # Says where it landed, so "first" is visible rather than assumed.
    $where = if (Get-Setting 'NewNewsItemAtTop') { 'في أول الشريط' } else { 'في آخر الشريط' }
    Send-TelegramMessage -ChatId $ChatId -Text $(if($ok){"✅ أضيف الخبر $where - في المسودة فقط."}else{'❌ لم تتم الإضافة؛ تحقق من النص والحدود.'}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-NewsTickerEditText { param([long]$ChatId,[long]$UserId,[string]$Value)
    $state=Get-PendingState -ChatId $ChatId;if(-not $state -or $state.Mode-ne'news_edit_text'){return};$index=[int]$state.Index;Clear-PendingState -ChatId $ChatId
    $ok=Update-NewsTickerDraftItem -UserId $UserId -Index $index -Text $Value
    Send-TelegramMessage -ChatId $chatId -Text $(if($ok){'✅ حُدّث الخبر في المسودة.'}else{'❌ تعذر تعديل الخبر.'});Show-NewsTickerReorderScreen -ChatId $chatId -UserId $UserId
}

function Receive-NewsTickerImport { param($Document,[long]$ChatId,[long]$UserId)
    $state=Get-PendingState -ChatId $ChatId
    if(-not $state -or $state.Mode -ne 'news_import_upload' -or [long]$state.UserId -ne $UserId){Send-TelegramMessage -ChatId $ChatId -Text 'ابدأ الاستيراد من إدارة شريط الأخبار أولًا.';return}
    $name=[string](Get-JsonProp $Document 'file_name');if([IO.Path]::GetExtension($name) -ine '.txt'){Send-TelegramMessage -ChatId $ChatId -Text 'يُقبل ملف TXT فقط.';return}
    $staged=Join-Path $script:newsImportDirectory ("news-$([guid]::NewGuid().ToString('N')).txt")
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $staged -MaximumBytes (Get-SettingInt 'NewsImportMaxBytes' 1)|Out-Null
        $snapshot=Get-NewsTickerSnapshot -Path $staged -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
        if(-not $snapshot.Success){throw $snapshot.Error}
        $text=ConvertTo-NewsTickerText -Items @($snapshot.Items) -Separator ([string](Get-Setting 'NewsItemSeparator'))
        $result=Import-NewsTickerTextToDraft -UserId $UserId -Text $text -Mode replace
        if(-not $result.Success){throw $result.Error}
        Clear-PendingState -ChatId $ChatId
        Send-TelegramMessage -ChatId $ChatId -Text "✅ استورد $($result.Count) خبرًا إلى المسودة فقط. راجعها قبل النشر." -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
    } catch { Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل الاستيراد: $($_.Exception.Message)" }
    finally {Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
}

