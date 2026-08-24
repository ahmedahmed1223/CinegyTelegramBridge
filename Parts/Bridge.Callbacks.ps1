#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Test-CallbackAdmin {
    <# Guard used by every admin-only callback branch. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (Test-Admin -ChatId $ChatId -UserId $UserId) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text "هذا الخيار للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $false
}

function Invoke-CallbackQuery {
    param($CallbackQuery)

    # message is absent when the originating message is too old for Telegram to
    # still have it, so it cannot be dereferenced blindly under StrictMode.
    $fromObj = Get-JsonProp $CallbackQuery 'from'
    $userId = if ($fromObj) { [long](Get-JsonProp $fromObj 'id') } else { 0 }
    $msgObj = Get-JsonProp $CallbackQuery 'message'
    $chatId = if ($msgObj) { [long]$msgObj.chat.id } else { $userId }
    $data = [string](Get-JsonProp $CallbackQuery 'data')
    Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id

    if ($chatId -eq 0) {
        Write-BridgeLog "Ignoring callback with neither a message nor a sender" "WARN"
        return
    }

    if ($msgObj -and -not (Test-TelegramPrivateChat -Chat $msgObj.chat)) {
        Write-BridgeLog "Ignoring callback from non-private chat $chatId" "WARN"
        return
    }

    if (-not (Test-Authorized -ChatId $chatId -UserId $userId)) {
        Write-BridgeLog "Rejected callback from unauthorized chat $chatId / user $userId" "WARN"
        $queued = Request-Approval -ChatId $chatId -UserId $userId -From $fromObj
        $msg = if ($queued) { "غير مصرح لك باستخدام هذا البوت بعد. تم إرسال طلب وصول إلى المشرف." }
        else { "غير مصرح لك باستخدام هذا البوت. تواصل مع المشرف مباشرة." }
        Send-TelegramMessage -ChatId $chatId -Text $msg
        return
    }
    Update-UserLastActivity -UserId $userId | Out-Null

    switch -Wildcard ($data) {
        'menu:news' { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break }
        'news:refresh' { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break }
        'news:start' {
            $result=Start-NewsTickerDraft -ChatId $chatId -UserId $userId
            if(-not $result.Success){Send-TelegramMessage -ChatId $chatId -Text "🔒 $($result.Error)" -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)}else{Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId};break
        }
        'news:add' {
            if(-not(Get-NewsTickerDraft -UserId $userId)){Send-TelegramMessage -ChatId $chatId -Text 'لا توجد مسودة مملوكة لك.';break}
            Set-PendingState -ChatId $chatId -State @{Mode='news_add_text';UserId=$userId;StartedAt=(Get-Date)}
            Send-TelegramMessage -ChatId $chatId -Text 'أرسل نص الخبر الجديد:';break
        }
        'news:preview' {
            $draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft){Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break}
            $position=0;$preview=@($draft.Items|ForEach-Object {$position++;"$position. $_"}) -join "`n"
            Send-TelegramMessage -ChatId $chatId -Text "👁 معاينة المسودة ($(@($draft.Items).Count)):`n$preview" -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:publish' {
            $draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft){Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break}
            Send-TelegramMessage -ChatId $chatId -Text "⚠️ تأكيد نشر $(@($draft.Items).Count) خبرًا إلى الملف الحي؟" -ReplyMarkup @{inline_keyboard=@(,@(@{text='✅ نعم، انشر';callback_data='news:publishconfirm'},@{text='إلغاء';callback_data='news:refresh'}))};break
        }
        'news:publishconfirm' {
            $result=Publish-NewsTickerDraft -UserId $userId
            Send-TelegramMessage -ChatId $chatId -Text $(if($result.Success){'✅ نُشر شريط الأخبار مع إنشاء نسخة احتياطية.'}else{"❌ لم يتم النشر: $($result.Error)"}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:list' { Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id);break }
        'news:item:*' {
            $i=[int](Get-CallbackArg $data 'news:item:');Show-NewsTickerItemScreen -ChatId $chatId -UserId $userId -Index $i;break
        }
        'news:edit:*' { $i=[int](Get-CallbackArg $data 'news:edit:');Set-PendingState -ChatId $chatId -State @{Mode='news_edit_text';UserId=$userId;Index=$i;StartedAt=(Get-Date)};Send-TelegramMessage -ChatId $chatId -Text 'أرسل النص البديل للخبر:';break }
        'news:delete:*' { $i=[int](Get-CallbackArg $data 'news:delete:');$ok=Remove-NewsTickerDraftItem -ChatId $chatId -UserId $userId -Index $i;if($ok){Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) -Text '🗑 حُذف هذا الخبر من المسودة.' -ReplyMarkup @{inline_keyboard=@(,@(@{text='⬅️ رجوع للترتيب';callback_data='news:list'}))}|Out-Null}else{Send-TelegramMessage -ChatId $chatId -Text '⛔ الحذف غير مسموح.'};break }
        'news:up:*' {
            $i=[int](Get-CallbackArg $data 'news:up:');$total=@((Get-NewsTickerDraft -UserId $userId).Items).Count
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta -1){Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id);Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text "الموضع ${i} من $total"}
            else{Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⛔ الخبر في أول القائمة بالفعل.'};break
        }
        'news:down:*' {
            $i=[int](Get-CallbackArg $data 'news:down:');$total=@((Get-NewsTickerDraft -UserId $userId).Items).Count
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta 1){Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id);Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text "الموضع $(($i+1)+1) من $total"}
            else{Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⛔ الخبر في آخر القائمة بالفعل.'};break
        }
        'news:iup:*' {
            $i=[int](Get-CallbackArg $data 'news:iup:')
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta -1){Show-NewsTickerItemScreen -ChatId $chatId -UserId $userId -Index ($i-1) -MessageId ([int]$msgObj.message_id) -CallbackQueryId $CallbackQuery.id}
            else{Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⛔ الخبر في أول القائمة بالفعل.'};break
        }
        'news:idown:*' {
            $i=[int](Get-CallbackArg $data 'news:idown:')
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta 1){Show-NewsTickerItemScreen -ChatId $chatId -UserId $userId -Index ($i+1) -MessageId ([int]$msgObj.message_id) -CallbackQueryId $CallbackQuery.id}
            else{Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⛔ الخبر في آخر القائمة بالفعل.'};break
        }
        'news:unlock' { if(Test-CallbackAdmin -ChatId $chatId -UserId $userId){Remove-NewsTickerDraft;Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId};break }
        'news:clear' { Send-TelegramMessage -ChatId $chatId -Text '⚠️ سيُمسح كل محتوى المسودة فقط. هل تؤكد؟' -ReplyMarkup @{inline_keyboard=@(,@(@{text='نعم، امسح المسودة';callback_data='news:clearconfirm'},@{text='إلغاء';callback_data='news:refresh'}))};break }
        'news:clearconfirm' { $ok=Clear-NewsTickerDraftItems -ChatId $chatId -UserId $userId;Send-TelegramMessage -ChatId $chatId -Text $(if($ok){'✅ مُسحت المسودة. لم يُمس الملف الحي.'}else{'⛔ غير مسموح.'}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break }
        'news:backups' { Send-TelegramMessage -ChatId $chatId -Text 'اختر نسخة لمراجعة استعادتها:' -ReplyMarkup (Get-NewsTickerBackupsKeyboard);break }
        'news:restore:*' {
            if(-not(Test-Admin -ChatId $chatId -UserId $userId)-and -not(Get-Setting 'AllowOperatorsRestoreNews')){break};$i=[int](Get-CallbackArg $data 'news:restore:')
            Send-TelegramMessage -ChatId $chatId -Text '⚠️ تأكيد الاستعادة؟ ستُحفظ الحالة الحالية أولًا.' -ReplyMarkup @{inline_keyboard=@(,@(@{text='✅ استعادة';callback_data="news:restoreconfirm:$i"},@{text='إلغاء';callback_data='news:backups'}))};break
        }
        'news:restoreconfirm:*' {
            if(-not(Test-Admin -ChatId $chatId -UserId $userId)-and -not(Get-Setting 'AllowOperatorsRestoreNews')){break};$i=[int](Get-CallbackArg $data 'news:restoreconfirm:');$files=@(Get-ChildItem -LiteralPath $script:newsBackupDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 10);if($i-ge $files.Count){break}
            $live=Get-NewsTickerConfiguredSnapshot;$result=Restore-NewsTickerBackup -Path ([string](Get-Setting 'NewsFilePath')) -BackupPath $files[$i].FullName -ExpectedHash $live.Hash -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
            if($result.Success){Remove-NewsTickerDraft;Add-AuditEntry "📰 استعادة نسخة شريط الأخبار بواسطة $(Get-UserDisplayName -UserId $userId)"};Send-TelegramMessage -ChatId $chatId -Text $(if($result.Success){'✅ تمت الاستعادة وحفظت الحالة السابقة.'}else{"❌ فشلت الاستعادة: $($result.Error)"}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:cancel' { if(Get-NewsTickerDraft -UserId $userId){Remove-NewsTickerDraft};Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break }
        'news:import' {
            $started=Start-NewsTickerDraft -ChatId $chatId -UserId $userId;if(-not $started.Success){Send-TelegramMessage -ChatId $chatId -Text $started.Error;break}
            Set-PendingState -ChatId $chatId -State @{Mode='news_import_upload';UserId=$userId;StartedAt=(Get-Date)}
            Send-TelegramMessage -ChatId $chatId -Text '📥 أرسل ملف TXT UTF-8. سيُستورد إلى المسودة فقط ثم يمكنك معاينته ونشره.';break
        }
        'menu' {
            Clear-PendingState -ChatId $chatId
            Send-TelegramMessage -ChatId $chatId -Text (Get-MainMenuIntro) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'cancel' {
            Clear-PendingState -ChatId $chatId
            Send-TelegramMessage -ChatId $chatId -Text "تم الإلغاء." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'show:confirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_review' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "انتهت أو تغيّرت مراجعة الإرسال. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $key = [string]$state.Key
            $variables = $state.Values
            $autoHideSeconds = [int]$state.AutoHideSeconds
            Clear-PendingState -ChatId $chatId
            Invoke-ShowTemplateResult -Key $key -Variables $variables -ChatId $chatId -UserId $userId -AutoHideSeconds $autoHideSeconds
            break
        }
        'show:edit' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_review' -or [long]$state.UserId -ne $userId -or @($state.Fields).Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد مراجعة قابلة للتعديل. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $state.Mode = 'show_fields'
            $state.Index = 0
            Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'show:back' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId -or [int]$state.Index -le 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد خطوة سابقة متاحة." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $state.Index = [int]$state.Index - 1
            Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'show:preview' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId -or $state.Values.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد قيم مدخلة لمعاينتها بعد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $preview = "🔎 معاينة المسودة الحالية`n`n$(Format-ShowReviewText -State $state)"
            Send-TelegramMessage -ChatId $chatId -Text $preview -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'hideall:confirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'hide_all_review' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "انتهى أو تغيّر طلب إخفاء الكل. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            Clear-PendingState -ChatId $chatId
            Invoke-HideAllLayers -ChatId $chatId -UserId $userId
            break
        }
        'skip' { Resume-ShowFlow -ChatId $chatId -Skip; break }
        'recent:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "انتهت مسودة الإدخال. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $recentIndex = [int]((Get-CallbackArg $data 'recent:'))
            $fieldName = [string]$state.Fields[[int]$state.Index]
            $values = @(Get-RecentFieldValues -UserId $userId -FieldName $fieldName)
            if ($recentIndex -lt 0 -or $recentIndex -ge $values.Count) {
                Send-TelegramMessage -ChatId $chatId -Text "القيمة الحديثة لم تعد متاحة." -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
                break
            }
            Resume-ShowFlow -ChatId $chatId -Value ([string]$values[$recentIndex])
            break
        }
        'menu:templates' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب لإظهاره أو استخدم البحث والتصنيفات:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'tpl' -BrowseControls)
            break
        }
        'menu:templatesearch' {
            Start-TemplateSearch -ChatId $chatId -UserId $userId
            break
        }
        'menu:templatecategories' {
            Send-TelegramMessage -ChatId $chatId -Text '🗂 اختر تصنيف القوالب:' -ReplyMarkup (Get-TemplateCategoriesKeyboard)
            break
        }
        'tplcat:*' {
            $categories = @(Get-TemplateCategories)
            $categoryIndex = [int](Get-CallbackArg $data 'tplcat:')
            if ($categoryIndex -lt 0 -or $categoryIndex -ge $categories.Count) {
                Send-TelegramMessage -ChatId $chatId -Text 'التصنيف لم يعد متاحًا.' -ReplyMarkup (Get-TemplateCategoriesKeyboard)
                break
            }
            $category = [string]$categories[$categoryIndex]
            Send-TelegramMessage -ChatId $chatId -Text "🗂 قوالب '$category':" -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Category $category -BrowseControls)
            break
        }
        'tplinfo:*' {
            $templateIndex = [int](Get-CallbackArg $data 'tplinfo:')
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template) {
                Send-TelegramMessage -ChatId $chatId -Text 'القالب لم يعد متاحًا.' -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -BrowseControls)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text (Get-TemplatePreviewText -Template $template) -ReplyMarkup (Get-TemplatePreviewKeyboard -TemplateIndex $templateIndex)
            break
        }
        'menu:favorites' {
            Send-TelegramMessage -ChatId $chatId -Text '⭐ اختر القوالب التي تريد إظهارها في مفضلتك:' -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            break
        }
        'favtoggle:*' {
            $template = Get-TemplateByIndex -Index ([int](Get-CallbackArg $data 'favtoggle:'))
            if (-not $template) { break }
            $selected = @(Get-FavoriteTemplateKeys -UserId $userId) -contains [string]$template.Key
            if (Set-UserFavorite -UserId $userId -TemplateKey ([string]$template.Key) -Enabled (-not $selected)) {
                $action = if ($selected) { 'أزيل من' } else { 'أضيف إلى' }
                Add-AuditEntry "⭐ $($template.Key) $action مفضلة $(Get-UserDisplayName -UserId $userId)"
                Send-TelegramMessage -ChatId $chatId -Text "✅ $($template.Key): $action المفضلة." -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            }
            break
        }
        'menu:timed' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب، ثم حدّد مدة الإخفاء التلقائي:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'tplT')
            break
        }
        'menu:hide' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر الطبقة لإخفائها:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'hide')
            break
        }
        'menu:exit' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر الطبقة للخروج من مشهدها:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'exit')
            break
        }
        'menu:hideall' {
            Request-HideAllConfirmation -ChatId $chatId -UserId $userId
            break
        }
        'menu:repeat' { Invoke-RepeatLastShow -ChatId $chatId -UserId $userId; break }
        'menu:myops' { Invoke-MyOperationsCommand -ChatId $chatId -UserId $userId; break }
        'ops:retry' { Invoke-RetryLastShowAttempt -ChatId $chatId -UserId $userId; break }
        'menu:update' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب لتحديث أحد حقوله:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'updtpl')
            break
        }
        'menu:snapshot' { Start-SnapshotJob -ChatId $chatId -UserId $userId; break }
        'menu:status' { Invoke-StatusCommand -ChatId $chatId -UserId $userId; break }
        'menu:fullstatus' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-FullStatusCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:health' {
            # Backward-compatible callback for messages created before 3.0.
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-FullStatusCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:diagnostics' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-DiagnosticsCommand -ChatId $chatId -UserId $userId }
            break
        }
        'diag:bundle' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-DiagnosticBundleCommand -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearruntime' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-DiagnosticLogClear -Kind runtime -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearaudit' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-DiagnosticLogClear -Kind audit -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearconfirm' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -ne 'diagnostic_log_clear' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text 'انتهى أو تغيّر طلب المسح. افتح التشخيص وابدأ من جديد.' -ReplyMarkup (Get-DiagnosticsKeyboard)
                break
            }
            $kind = [string]$state.Kind
            Clear-PendingState -ChatId $chatId
            if (Clear-DiagnosticLog -Kind $kind -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text '✅ تم مسح السجل المحدد بأمان.' -ReplyMarkup (Get-DiagnosticsKeyboard)
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text '❌ تعذر مسح السجل. راجع سجل التشغيل وصلاحيات الملفات.' -ReplyMarkup (Get-DiagnosticsKeyboard)
            }
            break
        }
        'menu:layers' {
            $layerStatuses = @(Get-CinegyLayerDashboard)
            $comparison = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses $layerStatuses `
                -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
            $comparisonText = @(
                "🔎 نتيجة المقارنة: أضيف $(@($comparison.Added).Count) · أزيل $(@($comparison.Removed).Count) · تعذر $(@($comparison.Failed).Count)",
                (Format-CinegyLayerDashboard -LayerStatuses $layerStatuses)
            ) -join "`n`n"
            Send-TelegramMessage -ChatId $chatId -Text $comparisonText -ReplyMarkup (Get-LayerDashboardKeyboard -LayerStatuses $layerStatuses)
            break
        }
        { $_ -in @('اسم', 'alias') } { Invoke-UserAliasCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        'menu:refreshstatus' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Invoke-FullStatusCommand -ChatId $chatId -UserId $userId
            }
            break
        }
        'menu:help' {
            Send-TelegramMessage -ChatId $chatId -Text (Get-HelpText -ChatId $chatId -UserId $userId) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'menu:audit' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-AuditCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:settings' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-SettingsScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:sharestatus' {
            # Sent as its own message with no keyboard, so a long-press copies just
            # the summary rather than the surrounding chrome.
            Send-TelegramMessage -ChatId $chatId -Text (Get-OnAirShareText)
            Send-TelegramMessage -ChatId $chatId -Text 'انسخ الرسالة أعلاه وأرسلها لمن يحتاجها.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'menu:stats' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-BridgeStatsText) -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:whatsnew' {
            Send-TelegramMessage -ChatId $chatId -Text (Get-WhatsNewText) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'menu:restart' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-BridgeRestart -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'restart:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-BridgeRestart -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'menu:cfgexport' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-SettingsExport -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'menu:cfgimport' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'settings_import_upload'; UserId = $userId; StartedAt = (Get-Date) }
                Send-TelegramMessage -ChatId $chatId -Text '📥 أرسل ملف الإعدادات المُصدَّر من هذا الجسر. ستراجع التغييرات قبل تطبيقها.' -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'cfgimport:apply' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-SettingsImport -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'cfgimport:cancel' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-SettingsImport -ChatId $chatId -UserId $userId -Cancel | Out-Null }
            break
        }
        'menu:usagedigest' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-UsageDigestText) -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:selftest' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-BridgeSelfTest -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'menu:admintools' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text '🗂 أدوات الإدارة' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:usersadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-UsersAdminScreen -ChatId $chatId }
            break
        }
        'usr:toggle:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $target = [long](Get-CallbackArg $data 'usr:toggle:'); $disabled = Test-UserDisabled -UserId $target
            if (Set-UserDisabled -TargetUserId $target -Disabled (-not $disabled)) {
                $action = if ($disabled) { 'إعادة تفعيل' } else { 'تعطيل' }
                Write-BridgeLog "Admin $userId changed user $target state: $action"
                Add-AuditEntry "👥 $action المستخدم $target - by $(Get-UserDisplayName -UserId $userId)"
                Show-UsersAdminScreen -ChatId $chatId
            }
            break
        }
        'usr:alias:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Start-UserAliasEdit -TargetUserId ([long](Get-CallbackArg $data 'usr:alias:')) -ChatId $chatId -AdminUserId $userId
            }
            break
        }
        'usr:revoke:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-UserRevocation -TargetUserId ([long](Get-CallbackArg $data 'usr:revoke:')) -ChatId $chatId -AdminUserId $userId }
            break
        }
        'usr:revokeconfirm' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'user_revoke' -or [long]$state.UserId -ne $userId) { break }
            $target = [long]$state.TargetUserId; Clear-PendingState -ChatId $chatId
            $result = Revoke-AuthorizedUser -TargetUserId $target
            if ($result.Success) {
                Write-BridgeLog "Admin $userId revoked user $target" 'WARN'
                Add-AuditEntry "👥 سحب صلاحية المستخدم $target - by $(Get-UserDisplayName -UserId $userId)"
                Send-TelegramMessage -ChatId $chatId -Text "✅ تم سحب صلاحية المستخدم $target." -ReplyMarkup (Get-UsersAdminKeyboard)
            }
            else { Send-TelegramMessage -ChatId $chatId -Text "❌ $($result.Error)" -ReplyMarkup (Get-UsersAdminKeyboard) }
            break
        }
        'menu:layernames' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-LayerNamesScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:hideallsettings' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-HideAllLayerSettings -ChatId $chatId -UserId $userId }
            break
        }
        'menu:schedule' {
            Send-TelegramMessage -ChatId $chatId -Text "📅 جدولة العروض وإدارة الأحداث القادمة:" -ReplyMarkup (Get-ScheduleMenuKeyboard)
            break
        }
        'schedule:new' {
            $clock = Get-SystemClockStatus
            if (-not $clock.Success) {
                Send-TelegramMessage -ChatId $chatId -Text "❌ ساعة الجهاز أو المنطقة الزمنية غير صالحة للجدولة." -ReplyMarkup (Get-ScheduleMenuKeyboard)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب المراد جدولته:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'schtpl')
            break
        }
        'schedule:list' {
            $events = @(Get-UpcomingScheduleEvents)
            $text = if ($events.Count -eq 0) { 'لا توجد أحداث قادمة.' } else { "📋 الأحداث القادمة:`n" + (@($events | ForEach-Object { "• $(Format-ScheduleEvent -ScheduleEntry $_)" }) -join "`n") }
            Send-TelegramMessage -ChatId $chatId -Text $text -ReplyMarkup (Get-UpcomingScheduleKeyboard)
            break
        }
        'schtpl:*' {
            Start-ScheduleShowFlow -TemplateIndex ([int](Get-CallbackArg $data 'schtpl:')) -ChatId $chatId -UserId $userId
            break
        }
        'schrec:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_recurrence' -or [long]$state.UserId -ne $userId) { break }
            $state.Recurrence = (Get-CallbackArg $data 'schrec:')
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schedule:confirm' {
            Confirm-ScheduledShow -ChatId $chatId -UserId $userId
            break
        }
        'schedule:setend' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId -or [string]$state.Recurrence -eq 'once') { break }
            $state.Mode = 'schedule_end_date'; Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text '📆 أرسل آخر تاريخ مسموح للتكرار بصيغة YYYY-MM-DD.' -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'schedule:clearend' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId) { break }
            $state.RecurrenceUntil = ''
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schededit:*' {
            Start-ScheduleMutationFlow -Action edit -EventId (Get-CallbackArg $data 'schededit:') -ChatId $chatId -UserId $userId
            break
        }
        'schedcopy:*' {
            Start-ScheduleMutationFlow -Action copy -EventId (Get-CallbackArg $data 'schedcopy:') -ChatId $chatId -UserId $userId
            break
        }
        'schcancel:*' {
            $eventId = (Get-CallbackArg $data 'schcancel:')
            $scheduleEntry = @(Get-UpcomingScheduleEvents | Where-Object { [string]$_.Id -eq $eventId }) | Select-Object -First 1
            if (-not $scheduleEntry) { break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'schedule_cancel'; EventId = $eventId; UserId = $userId }
            Send-TelegramMessage -ChatId $chatId -Text "هل تريد إلغاء الحدث؟`n$(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)" -ReplyMarkup @{ inline_keyboard = @(, @((New-Button "✅ نعم، إلغاء" 'schedule:cancelconfirm'), (New-Button "❌ رجوع" 'schedule:list'))) }
            break
        }
        'schedule:cancelconfirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_cancel' -or [long]$state.UserId -ne $userId) { break }
            $cancelled = Stop-ScheduledShowEvent -Id ([string]$state.EventId)
            Clear-PendingState -ChatId $chatId
            $text = if ($cancelled) { '✅ تم إلغاء الحدث.' } else { 'تعذر إلغاء الحدث؛ ربما نُفّذ أو أُلغي مسبقًا.' }
            Send-TelegramMessage -ChatId $chatId -Text $text -ReplyMarkup (Get-ScheduleMenuKeyboard)
            break
        }
        'menu:presetsadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "⚡ إدارة النصوص الجاهزة`nاختر القالب:" -ReplyMarkup (Get-PresetAdminTemplatesKeyboard)
            }
            break
        }
        'menu:templatesadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $pendingImport = Get-PendingState -ChatId $chatId
                if ($pendingImport -and [string]$pendingImport.Mode -like 'template_import_*') { Clear-PendingState -ChatId $chatId }
                Send-TelegramMessage -ChatId $chatId -Text '📚 القوالب والإعدادات — اختر قالبًا لقراءة تعريفه:' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
            }
            break
        }
        'timport:export' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-TemplateRegistryExport -ChatId $chatId -UserId $userId }
            break
        }
        'timport:start' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-TemplateRegistryImport -ChatId $chatId -UserId $userId }
            break
        }
        'timport:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-TemplateRegistryImport -ChatId $chatId -UserId $userId }
            break
        }
        'tadm:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $token = (Get-CallbackArg $data 'tadm:')
                if ($token -eq 'create') { Start-TemplateCreateWizard -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'createjson') { Start-TemplateDefinitionPrompt -Action create -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'confirm') { Confirm-TemplateDefinitionChange -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'testconfirm') { Confirm-TemplateTest -ChatId $chatId -UserId $userId }
                elseif ($token -match '^test:(\d+)$') { Start-TemplateTestReview -TemplateIndex ([int]$Matches[1]) -ChatId $chatId -UserId $userId }
                elseif ($token -match '^(edit|delete):(\d+)$') { Start-TemplateDefinitionPrompt -Action $Matches[1] -TemplateIndex ([int]$Matches[2]) -ChatId $chatId -UserId $userId }
                else { Show-TemplateAdminDetail -TemplateIndex ([int]$token) -ChatId $chatId -UserId $userId }
            }
            break
        }
        'padm:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Show-PresetAdminTemplate -TemplateIndex ([int](Get-CallbackArg $data 'padm:')) -ChatId $chatId
            }
            break
        }
        'pa:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template -or $presetIndex -ge @($template.Presets).Count) { break }
            Send-TelegramMessage -ChatId $chatId -Text "⚡ $($template.Presets[$presetIndex].Name)`nاختر العملية المطلوبة:" -ReplyMarkup (Get-PresetActionKeyboard -TemplateIndex $templateIndex -PresetIndex $presetIndex)
            break
        }
        'pac:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Start-PresetAdminCreate -TemplateIndex ([int](Get-CallbackArg $data 'pac:')) -ChatId $chatId -UserId $userId
            }
            break
        }
        'pae:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            Start-PresetAdminEditValues -TemplateIndex ([int]$presetParts[1]) -PresetIndex ([int]$presetParts[2]) -ChatId $chatId -UserId $userId
            break
        }
        'par:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template -or $presetIndex -ge @($template.Presets).Count) { break }
            Set-PendingState -ChatId $chatId -State @{
                Mode = 'preset_admin_name'; Action = 'rename'; TemplateIndex = $templateIndex
                TemplateKey = [string]$template.Key; PresetIndex = $presetIndex; UserId = $userId
                Fields = @($template.Fields); Values = @(); Name = [string]$template.Presets[$presetIndex].Name; Index = 0
            }
            Send-TelegramMessage -ChatId $chatId -Text "أرسل الاسم الجديد لـ '$($template.Presets[$presetIndex].Name)':" -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'pad:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template -or $presetIndex -ge @($template.Presets).Count) { break }
            Show-PresetAdminReview -ChatId $chatId -State @{
                Mode = 'preset_admin_review'; Action = 'delete'; TemplateIndex = $templateIndex
                TemplateKey = [string]$template.Key; PresetIndex = $presetIndex; UserId = $userId
                Fields = @($template.Fields); Values = @($template.Presets[$presetIndex].Values)
                Name = [string]$template.Presets[$presetIndex].Name; Index = 0
            }
            break
        }
        'presetadmin:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Confirm-PresetAdminChange -ChatId $chatId -UserId $userId
            }
            break
        }
        'menu:backups' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "🗄 نسخ الإعدادات المحفوظة:" -ReplyMarkup (Get-ConfigBackupsKeyboard)
            }
            break
        }
        'menu:rawcmd' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "أرسل الأمر بصيغة: /أمر Device Cmd [Op1]" -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'menu:pending' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "طلبات الوصول المعلّقة:" -ReplyMarkup (Get-PendingKeyboard)
            }
            break
        }
        'menu:stream:start' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-LiveRelay -ChatId $chatId -UserId $userId }
            break
        }
        'menu:stream:stop' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Stop-LiveRelay -ChatId $chatId -UserId $userId }
            break
        }
        'menu:stream:seturl' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-StreamUrlPrompt -ChatId $chatId -UserId $userId }
            break
        }
        'tplT:*' {
            # Pick the duration first, then collect the field text; the show
            # fires as soon as the last field is entered.
            $idx = [int]((Get-CallbackArg $data 'tplT:'))
            $t = Get-TemplateByIndex -Index $idx
            $name = if ($t) { $t.Key } else { '' }
            Send-TelegramMessage -ChatId $chatId -Text "المدة قبل الإخفاء التلقائي لـ '$name'`:" -ReplyMarkup (Get-DurationKeyboard -Prefix 'dur' -Token "$idx" -BackData 'menu:timed')
            break
        }
        'dur:*' {
            $parts = $data -split ':'
            $idx = [int]$parts[1]
            if ($parts[2] -eq 'c') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'timed_custom'; TemplateIndex = $idx; UserId = $userId }
                Send-TelegramMessage -ChatId $chatId -Text "أرسل المدة بالثواني (رقم فقط):" -ReplyMarkup (Get-CancelKeyboard)
            }
            else {
                Start-ShowFlow -TemplateIndex $idx -ChatId $chatId -UserId $userId -AutoHideSeconds ([int]$parts[2])
            }
            break
        }
        'timer:*' {
            $layer = [int]((Get-CallbackArg $data 'timer:'))
            Send-TelegramMessage -ChatId $chatId -Text "المدة قبل إخفاء الطبقة $layer`:" -ReplyMarkup (Get-DurationKeyboard -Prefix 'tlay' -Token "$layer")
            break
        }
        'tlay:*' {
            $parts = $data -split ':'
            $layer = [int]$parts[1]
            if ($parts[2] -eq 'c') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'layer_timer_custom'; Layer = $layer; UserId = $userId }
                Send-TelegramMessage -ChatId $chatId -Text "أرسل المدة بالثواني لإخفاء الطبقة $layer (رقم فقط):" -ReplyMarkup (Get-CancelKeyboard)
            }
            else {
                Set-LayerAutoHide -Layer $layer -Seconds ([int]$parts[2]) -ChatId $chatId -UserId $userId
            }
            break
        }
        'tpl:*' {
            $idx = [int]((Get-CallbackArg $data 'tpl:'))
            Start-ShowFlow -TemplateIndex $idx -ChatId $chatId -UserId $userId
            break
        }
        'preset:*' {
            $parts = $data -split ':'
            Invoke-PresetShow -TemplateIndex ([int]$parts[1]) -PresetIndex ([int]$parts[2]) -ChatId $chatId -UserId $userId
            break
        }
        'rollbackconfirm:*' { Confirm-SafeRollback -Layer ([int](Get-CallbackArg $data 'rollbackconfirm:')) -ChatId $chatId -UserId $userId; break }
        'rollback:*' { Start-SafeRollbackReview -Layer ([int](Get-CallbackArg $data 'rollback:')) -ChatId $chatId -UserId $userId; break }
        # A confirmed removal names the template, not just the layer number:
        # a layer number is not something an operator can check against the
        # screen under pressure. Off by default so the emergency path keeps
        # its single tap.
        'hidego:*' { Invoke-HideLayer -Layer ([int](Get-CallbackArg $data 'hidego:')) -ChatId $chatId -UserId $userId | Out-Null; break }
        'exitgo:*' { Invoke-ExitLayer -Layer ([int](Get-CallbackArg $data 'exitgo:')) -ChatId $chatId -UserId $userId; break }
        'hide:*' {
            $targetLayer = [int](Get-CallbackArg $data 'hide:')
            if (Get-Setting 'ConfirmLayerRemoval') {
                Send-TelegramMessage -ChatId $chatId -Text "⚠️ تأكيد الإخفاء`n$(Get-LayerRemovalSummary -Layer $targetLayer)" -ReplyMarkup (Get-LayerRemovalConfirmKeyboard -Layer $targetLayer -Action hide)
            }
            else { Invoke-HideLayer -Layer $targetLayer -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'exit:*' {
            $targetLayer = [int](Get-CallbackArg $data 'exit:')
            if (Get-Setting 'ConfirmLayerRemoval') {
                Send-TelegramMessage -ChatId $chatId -Text "⚠️ تأكيد الخروج من المشهد`n$(Get-LayerRemovalSummary -Layer $targetLayer)" -ReplyMarkup (Get-LayerRemovalConfirmKeyboard -Layer $targetLayer -Action exit)
            }
            else { Invoke-ExitLayer -Layer $targetLayer -ChatId $chatId -UserId $userId }
            break
        }
        'updtpl:*' {
            $idx = [int]((Get-CallbackArg $data 'updtpl:'))
            $t = Get-TemplateByIndex -Index $idx
            if (-not $t -or $t.Fields.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد حقول قابلة للتحديث في هذا القالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text "اختر الحقل لتحديثه:" -ReplyMarkup (Get-FieldsKeyboard -TemplateIndex $idx)
            }
            break
        }
        'updf:*' {
            $parts = $data -split ':'
            $t = Get-TemplateByIndex -Index ([int]$parts[1])
            $fieldIdx = [int]$parts[2]
            if (-not $t -or $fieldIdx -ge $t.Fields.Count) {
                Send-TelegramMessage -ChatId $chatId -Text "الحقل غير موجود (ربما تغيّر ملف القوالب)." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            else {
                $fieldLimit = 0
                if ($fieldIdx -lt @($t.FieldLimits).Count) { $fieldLimit = [int]$t.FieldLimits[$fieldIdx] }
                Start-UpdateFieldPrompt -FieldName ([string]$t.Fields[$fieldIdx]) -ChatId $chatId -UserId $userId -FieldLimit $fieldLimit
            }
            break
        }
        'approve:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Grant-UserAccess -TargetChatId ([long](Get-CallbackArg $data 'approve:')) -ApprovedBy $chatId -ApproverUserId $userId
            }
            break
        }
        'reject:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Deny-UserAccess -TargetChatId ([long](Get-CallbackArg $data 'reject:')) -RejectedBy $chatId -RejecterUserId $userId
            }
            break
        }
        'cfg:restoreconfirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $state = Get-PendingState -ChatId $chatId
                if (-not $state -or $state.Mode -ne 'config_restore' -or [long]$state.UserId -ne $userId) {
                    Send-TelegramMessage -ChatId $chatId -Text "انتهى أو تغيّر طلب الاستعادة. اختر النسخة من جديد." -ReplyMarkup (Get-ConfigBackupsKeyboard)
                    break
                }
                $backupPath = [string]$state.BackupPath
                Clear-PendingState -ChatId $chatId
                $restore = Restore-ConfigBackup -BackupPath $backupPath
                if ($restore.Success) {
                    Write-BridgeLog "Admin user $userId restored configuration backup '$([System.IO.Path]::GetFileName($backupPath))'" "WARN"
                    Add-AuditEntry "🗄 استعادة نسخة إعدادات - user $userId"
                    Send-TelegramMessage -ChatId $chatId -Text "✅ تمت استعادة نسخة الإعدادات. أعد تشغيل البوت لتطبيقها بالكامل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                }
                else {
                    Send-TelegramMessage -ChatId $chatId -Text "❌ فشلت الاستعادة: $($restore.Error)" -ReplyMarkup (Get-ConfigBackupsKeyboard)
                }
            }
            break
        }
        'cfg:restore:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $backupDirectory = "$ConfigPath.backups"
                $files = if (Test-Path -LiteralPath $backupDirectory) {
                    @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' | Sort-Object LastWriteTimeUtc, Name -Descending)
                }
                else { @() }
                $index = [int](Get-CallbackArg $data 'cfg:restore:')
                if ($index -lt 0 -or $index -ge $files.Count) {
                    Send-TelegramMessage -ChatId $chatId -Text "النسخة المحددة لم تعد موجودة." -ReplyMarkup (Get-ConfigBackupsKeyboard)
                    break
                }
                Clear-PendingState -ChatId $chatId
                Set-PendingState -ChatId $chatId -State @{
                    Mode = 'config_restore'; UserId = $userId; BackupPath = $files[$index].FullName
                }
                $differenceSummary = Get-ConfigDifferenceSummary -CurrentPath $ConfigPath -BackupPath $files[$index].FullName
                Send-TelegramMessage -ChatId $chatId -Text "⚠️ تأكيد استعادة النسخة '$($files[$index].Name)'؟`n$differenceSummary`nسيتم حفظ الإعدادات الحالية أولًا، ويجب إعادة تشغيل البوت بعد الاستعادة." -ReplyMarkup (Get-ConfigRestoreConfirmKeyboard)
            }
            break
        }
        'cfg:reset' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Reset-SettingsToDefault -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:all' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -SelectAll -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:none' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -ClearAll -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:toggle:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -Layer ([int](Get-CallbackArg $data 'hideallcfg:toggle:')) -ChatId $chatId -UserId $userId }
            break
        }
        'layername:clear:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $layerText = $data -replace '^layername:clear:', ''
                if ([string]::IsNullOrWhiteSpace($layerText)) { break }
                $layer = 0
                if (-not [int]::TryParse($layerText, [ref]$layer)) { break }
                Clear-PendingState -ChatId $chatId
                Set-LayerName -Layer $layer -Name '' -ChatId $chatId -UserId $userId | Out-Null
            }
            break
        }
        'layername:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $layerText = $data -replace '^layername:', ''
                if ([string]::IsNullOrWhiteSpace($layerText)) { break }
                $layer = 0
                if (-not [int]::TryParse($layerText, [ref]$layer)) { break }
                if (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $layer) { Start-LayerNamePrompt -Layer $layer -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfg:t:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-SettingToggle -Name (Get-CallbackArg $data 'cfg:t:') -ChatId $chatId -UserId $userId }
            break
        }
        'cfgc:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Invoke-SettingToggle -Name (Get-CallbackArg $data 'cfgc:') -ChatId $chatId -UserId $userId -Confirmed
            }
            break
        }
        'cfg:v:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-SettingValuePrompt -Name (Get-CallbackArg $data 'cfg:v:') -ChatId $chatId -UserId $userId }
            break
        }
        'cfg:s:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $settingName = (Get-CallbackArg $data 'cfg:s:')
                if ($settingName -eq 'LayerNames') { Show-LayerNamesScreen -ChatId $chatId -UserId $userId }
                else { Show-SettingChoices -Name $settingName -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfgs:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $parts = $data -split ':'
                Set-SettingChoice -Name $parts[1] -Index ([int]$parts[2]) -ChatId $chatId -UserId $userId
            }
            break
        }
        default {
            Send-TelegramMessage -ChatId $chatId -Text "خيار غير معروف." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
        }
    }
}

