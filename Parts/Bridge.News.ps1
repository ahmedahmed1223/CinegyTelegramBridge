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
    $draft.Items = @($draft.Items) + @($parsed.Items); $draft.UpdatedAt=(Get-Date).ToString('o'); return (Save-NewsTickerDraft)
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
    if (-not $draft) { return [pscustomobject]@{Success=$false;Error='لا توجد مسودة مملوكة لك.'} }
    $result = Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items @($draft.Items) -ExpectedHash ([string]$draft.BaseHash) -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if ($result.Success) {
        Add-AuditEntry "📰 نشر شريط الأخبار بواسطة $(Get-UserDisplayName -UserId $UserId): $(@($draft.Items).Count) خبرًا"
        Remove-NewsTickerDraft
    }
    return $result
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
        $rows += , @(@{text="🔒 لدى $($draft.OwnerUserId)";callback_data='news:refresh'})
        if (Test-Admin -ChatId $ChatId -UserId $UserId) {
            $rows += , @(@{text='🔓 إلغاء القفل (مشرف)';callback_data='news:unlock'})
        }
    }
    if ((Test-Admin -ChatId $ChatId -UserId $UserId) -or (Get-Setting 'AllowOperatorsRestoreNews')) {
        $rows += , @(@{text='🕘 النسخ والاستعادة';callback_data='news:backups'})
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

function Show-NewsTickerItemScreen { param([long]$ChatId,[long]$UserId,[int]$Index,[int]$MessageId=0,[string]$CallbackQueryId='')
    <# One message per news item: full text in the body, move/edit/delete
       buttons carrying the item's CURRENT index. Re-rendered in place after
       every move so the buttons can never point at a stale index. #>
    $draft=Get-NewsTickerDraft -UserId $UserId;if(-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count){return}
    $count=@($draft.Items).Count
    $rows=@(,@(@{text='⬆️ تحريك لأعلى';callback_data="news:iup:$Index"},@{text='⬇️ تحريك لأسفل';callback_data="news:idown:$Index"}))
    $rows+=,@(@{text='✏️ تعديل';callback_data="news:edit:$Index"},@{text='🗑 حذف';callback_data="news:delete:$Index"})
    $rows+=,@(@{text='⬅️ رجوع للترتيب';callback_data='news:list'})
    $text="📰 الخبر $($Index+1) من ${count}:`n`n$($draft.Items[$Index])"
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup @{inline_keyboard=$rows})){
        if($CallbackQueryId){Confirm-TelegramCallback -CallbackQueryId $CallbackQueryId -Text "الموضع $($Index+1) من $count"}
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup @{inline_keyboard=$rows}
}

function Get-NewsTickerReorderKeyboard { param([long]$UserId)
    <# One row per draft item: ⬆️ moves it up, the numbered label opens the
       per-item editor, ⬇️ moves it down. The whole list lives in ONE message
       that is edited in place, so indexes can never go stale. #>
    $draft=Get-NewsTickerDraft -UserId $UserId;$rows=@()
    if($draft){$count=@($draft.Items).Count
        for($i=0;$i-lt $count;$i++){$label="$(($i+1)). $($draft.Items[$i])";if($label.Length-gt 30){$label=$label.Substring(0,29)+'…'}
            $row=@();if($i-gt 0){$row+=,@{text='⬆️';callback_data="news:up:$i"}};$row+=,@{text=$label;callback_data="news:item:$i"};if($i-lt ($count-1)){$row+=,@{text='⬇️';callback_data="news:down:$i"}}
            $rows+=,@($row)}}
    else{$rows+=,@(@{text='لا توجد مسودة مملوكة لك';callback_data='news:refresh'})}
    $rows+=,@(@{text='➕ إضافة خبر';callback_data='news:add'},@{text='⬅️ إدارة الأخبار';callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Get-NewsTickerReorderText { param([long]$UserId)
    $draft=Get-NewsTickerDraft -UserId $UserId
    if(-not $draft){return '📝 الترتيب والتعديل'+"`n"+'⚠️ لا توجد مسودة مملوكة لك.'}
    return "📝 ترتيب المسودة ($(@($draft.Items).Count) خبرًا):`nاضغط ⬆️ أو ⬇️ بجانب الخبر لتحريكه، واضغط نص الخبر لتعديله أو حذفه."
}

function Show-NewsTickerReorderScreen { param([long]$ChatId,[long]$UserId,[int]$MessageId=0)
    <# Edits the originating message when possible so repeated ⬆️/⬇️ presses
       reuse a single message instead of flooding the chat with stale lists. #>
    $text=Get-NewsTickerReorderText -UserId $UserId;$kb=Get-NewsTickerReorderKeyboard -UserId $UserId
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
    Send-TelegramMessage -ChatId $ChatId -Text $(if($ok){'✅ أضيف الخبر إلى المسودة فقط.'}else{'❌ لم تتم الإضافة؛ تحقق من النص والحدود.'}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
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

