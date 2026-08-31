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

function Publish-NewsTickerDraft { param([long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    # Carries Conflict so every caller can branch on it uniformly; without it
    # $result.Conflict throws under StrictMode on this path.
    if (-not $draft) { return [pscustomobject]@{Success=$false;Conflict=$false;Error='لا توجد مسودة مملوكة لك.'} }
    $result = Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items @($draft.Items) -ExpectedHash ([string]$draft.BaseHash) -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if ($result.Success) {
        Add-AuditEntry "📰 نشر شريط الأخبار بواسطة $(Get-UserDisplayName -UserId $UserId): $(@($draft.Items).Count) خبرًا"
        Write-NewsPublishRecord -UserId $UserId -ItemCount (@($draft.Items).Count)
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
    Add-AuditEntry "🔓 طلب فكّ قفل شريط الأخبار من $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)) بواسطة $(Get-UserDisplayName -UserId $UserId)"

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

function Send-NewsSheetNotice {
    param([Parameter(Mandatory)][string]$Text)
    if (-not (Get-Setting 'NewsSheetNotifyAdmins')) { return }
    foreach ($admin in @(@(Get-JsonProp $config 'AdminChatIds') | ForEach-Object { [long]$_ })) {
        Send-TelegramMessage -ChatId $admin -Text $Text
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
        [long]$UserId = 0,
        [switch]$Confirmed
    )
    $stop = { param([string]$Message, [bool]$Skip = $false, [bool]$Ask = $false)
        [pscustomobject]@{ Success = $false; Skipped = $Skip; Unchanged = $false
            NeedsConfirmation = $Ask; Items = @(); Summary = $null; Error = $Message } }

    $url = [string](Get-Setting 'NewsSheetCsvUrl')
    if ([string]::IsNullOrWhiteSpace($url)) { return (& $stop 'لم يُضبط رابط Google Sheets في الإعدادات.') }

    $draft = Get-NewsTickerDraft
    if ($draft) {
        $owner = [long]$draft.OwnerUserId
        if ($Trigger -eq 'auto') {
            Write-BridgeLog "News sheet sync skipped: draft held by user $owner" 'WARN'
            return (& $stop 'مسودة الأخبار قيد التحرير؛ تُخطّيت هذه الدورة.' $true $false)
        }
        if ($owner -ne $UserId -and -not $Confirmed) {
            return (& $stop "المسودة بيد $(Get-UserDisplayName -UserId $owner). التأكيد يستبدلها بمحتوى الشيت." $false $true)
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
    if (-not $summary.Changed) {
        return [pscustomobject]@{ Success = $false; Skipped = $false; Unchanged = $true
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

    return [pscustomobject]@{ Success = $true; Skipped = $false; Unchanged = $false
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
            $rows += , @(@{text='🧹 مسح الكل';callback_data='news:clear'})
        }
        $rows += , @(@{text='✅ مراجعة ونشر';callback_data='news:publish'}, @{text='🗑 إلغاء المسودة';callback_data='news:cancel'})
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
    if ((Test-Admin -ChatId $ChatId -UserId $UserId) -and -not [string]::IsNullOrWhiteSpace([string](Get-Setting 'NewsSheetCsvUrl'))) {
        $rows += , @(@{text='⬇️ سحب من الشيت';callback_data='news:sheet'})
    }
    $rows += , @(@{text='🔄 تحديث';callback_data='news:refresh'}, @{text='⬅️ الرئيسية';callback_data='menu'})
    return @{inline_keyboard=$rows}
}

function Edit-TelegramMessageText {
    <# Edits an existing message in place so interactive screens (e.g. the
       news reorder list) never pile up duplicate messages with stale
       buttons. Falls back to returning $false so callers can resend. #>
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][int]$MessageId,
        [Parameter(Mandatory)][string]$Text,[hashtable]$ReplyMarkup)
    $body = @{ chat_id = $ChatId; message_id = $MessageId; text = $Text }
    if ($ReplyMarkup) { $body.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 10 -Compress) }
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
            , @(@{text='🗑 نعم، احذف';callback_data="news:delete:$Index"}, @{text='❌ إلغاء';callback_data="news:item:$Index"}))}
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
    $rows=@(,@(@{text='⬆️ تحريك لأعلى';callback_data="news:iup:$Index"},@{text='⬇️ تحريك لأسفل';callback_data="news:idown:$Index"}))
    $rows+=,@(@{text='✏️ تعديل';callback_data="news:edit:$Index"},@{text='🗑 حذف';callback_data="news:delask:$Index"})
    $rows+=,@(@{text='⬅️ رجوع للترتيب';callback_data='news:list'})
    $text="📰 الخبر $($Index+1) من ${count}:`n`n$($draft.Items[$Index])"
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup @{inline_keyboard=$rows})){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup @{inline_keyboard=$rows}
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
    $perItem = if (Get-Setting 'NewsListStackedLayout') { 5 } else { 4 }
    $maxItems = [math]::Max(3, [math]::Floor(($buttonBudget - 5) / $perItem))

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
    $labelMax = [math]::Max(8, (Get-SettingInt 'NewsListLabelLength' 8))
    $stackedMax = [math]::Max($labelMax, (Get-SettingInt 'NewsListStackedLabelLength' 8))

    for ($i = $first; $i -le $last; $i++) {
        $label = "$($i + 1). $($draft.Items[$i])"
        $fullLabel = $label
        if ($fullLabel.Length -gt $stackedMax) { $fullLabel = $fullLabel.Substring(0, $stackedMax - 1) + '…' }
        if ($label.Length -gt $labelMax) { $label = $label.Substring(0, $labelMax - 1) + '…' }

        if (Get-Setting 'NewsListStackedLayout') {
            $rows += , @(@{text=$fullLabel; callback_data="news:item:$i"})
            $controls = @()
            if ($i -gt 0) { $controls += , @{text='⬆️'; callback_data="news:up:$i"} }
            if ($i -lt ($count - 1)) { $controls += , @{text='⬇️'; callback_data="news:down:$i"} }
            $controls += , @{text='✏️'; callback_data="news:edit:$i"}
            $controls += , @{text='🗑'; callback_data="news:delask:$i"}
            $rows += , @($controls)
            continue
        }
        $row = @()
        if ($i -gt 0) { $row += , @{text='⬆️'; callback_data="news:up:$i"} }
        $row += , @{text=$label; callback_data="news:item:$i"}
        if ($i -lt ($count - 1)) { $row += , @{text='⬇️'; callback_data="news:down:$i"} }
        $row += , @{text='🗑'; callback_data="news:delask:$i"}
        $rows += , @($row)
    }

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
    $lines.Add('📝 ترتيب المسودة')
    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الأخبار: $count")
    if ($pages -gt 1) { $lines.Add("المعروض: $first–$last  ·  صفحة $($Page + 1) من $pages") }
    # Said plainly, because the operator asked for one long list and is
    # getting pages anyway: the reason is Telegram's limit, not the setting
    # being ignored.
    if ($pages -gt 1 -and -not (Get-Setting 'NewsListPaged')) {
        $lines.Add("القائمة الطويلة مفعّلة، لكن تيليجرام لا يقبل أكثر من $size خبرًا في شاشة واحدة.")
    }
    $lines.Add('')
    $lines.Add($(if (Get-Setting 'NewsListStackedLayout') {
                'أزرار كل خبر أسفله: ⬆️ ⬇️ ترتيب · ✏️ تعديل · 🗑 حذف'
            } else {
                '⬆️ ⬇️ للترتيب · اضغط النص للتعديل · 🗑 للحذف'
            }))
    return ($lines -join "`n")
}

function Show-NewsTickerReorderScreen { param([long]$ChatId,[long]$UserId,[int]$MessageId=0,[int]$Page=0)
    <# Edits the originating message when possible so repeated ⬆️/⬇️ presses
       reuse a single message instead of flooding the chat with stale lists. #>
    $text=Get-NewsTickerReorderText -UserId $UserId -Page $Page;$kb=Get-NewsTickerReorderKeyboard -UserId $UserId -Page $Page
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $kb)){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $kb
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

