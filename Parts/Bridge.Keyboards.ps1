#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function ConvertTo-OneHandLayout {
    <#
        Splits every row into single, full-width buttons.

        An operator holding the phone in one hand, thumb only, cannot reliably
        hit one of three buttons sharing a row - and the row that matters most
        is the live-layer row, pressed under time pressure. Applied as a final
        pass over a finished keyboard so no individual screen has to know
        about it.
    #>
    param([Parameter(Mandatory)][hashtable]$Keyboard)
    if (-not (Get-Setting 'OneHandMode')) { return $Keyboard }
    $rows = @()
    foreach ($row in @($Keyboard.inline_keyboard)) {
        foreach ($button in @($row)) { $rows += , @($button) }
    }
    return @{ inline_keyboard = $rows }
}

function New-Button {
    <#
        -Style is Bot API 9.4's button colour. Where it is used is a policy,
        not a taste, because a screen where everything is coloured says
        nothing:

          danger  - the press takes something off air, destroys typed work,
                    or overwrites live state: hide, exit scene, delete,
                    clear, revoke, restore, restart, and the affirming half
                    of any confirmation of those.
          success - the press commits what the operator just authored: send
                    on air, save, apply, confirm an import or a schedule.
          (none)  - navigation, cancel, and every menu entry that only opens
                    the screen where the act actually happens.

        A cancel stays uncoloured on purpose: colouring both halves of a
        confirmation leaves the thumb with no signal at all.

        The setting that turns colours off is honoured at send time, in
        ConvertTo-TelegramReplyMarkupJson, not here.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Data,
        [int]$MaxTextLength = -1,
        [ValidateSet('', 'danger', 'success', 'primary')][string]$Style = ''
    )
    $maxLength = if ($MaxTextLength -ge 0) { $MaxTextLength } else { Get-SettingInt 'ButtonTextMaxLength' }
    $displayText = $Text
    if ($maxLength -gt 1 -and (Get-TextElementCount -Text $Text) -gt $maxLength) {
        $info = [Globalization.StringInfo]::new($Text)
        $displayText = $info.SubstringByTextElements(0, $maxLength - 1).TrimEnd() + '…'
    }
    $button = @{ text = $displayText; callback_data = $Data }
    if ($Style) { $button.style = $Style }
    return $button
}

function Get-MainMenuKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @()

    # What is on air comes FIRST, before anything that puts more on air.
    # This menu is what an operator opens when a wrong graphic is live, and
    # every row above the fix is a row they must scroll past to reach it.
    if ($script:OnAir.Count -gt 0) {
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $liveRow = @( (New-Button "🔴 إخفاء $layer · $($script:OnAir[$layer].Key)" "hide:$layer" -Style danger) )
            # A timer can be attached to something already live, not just at
            # the moment it is put on air.
            if (Get-Setting 'EnableTimedShow') {
                $pending = @($script:AutoHideQueue | Where-Object { [int]$_.Layer -eq [int]$layer })
                $label = if ($pending.Count -gt 0) {
                    "⏱ $([int](($pending[0].At - (Get-Date)).TotalSeconds)) ث"
                }
                else { "⏱ مؤقت" }
                $liveRow += (New-Button $label "timer:$layer")
            }
            $rows += , $liveRow
        }
        # A frame from the actual output, next to what the bridge believes is
        # on air - so the operator can check the claim without leaving the chat.
        $onAirTools = @()
        if (Get-Setting 'EnableHideAll') { $onAirTools += (New-Button "🚨 إخفاء الكل" "menu:hideall") }
        if (Get-Setting 'EnableSnapshot') { $onAirTools += (New-Button "📷 لقطة الآن" "menu:snapshot") }
        $onAirTools += (New-Button "📋 نسخ الحالة" "menu:sharestatus")
        $rows += , $onAirTools
    }

    # A rollback used to be reachable only from the message that offered it,
    # so navigating away lost it for the rest of its window. The fastest human
    # error is pressing the wrong template; undo has to survive a tap on the
    # wrong thing afterwards.
    foreach ($layer in ($script:RollbackCandidates.Keys | Sort-Object)) {
        $candidate = Get-RollbackCandidate -Layer ([int]$layer) -UserId $UserId
        if (-not $candidate) { continue }
        $secondsLeft = [int](([datetime]$candidate.ExpiresAt) - (Get-Date)).TotalSeconds
        if ($secondsLeft -le 0) { continue }
        $rows += , @( (New-Button "↩️ تراجع طبقة $layer ($secondsLeft ث)" "rollback:$layer") )
    }

    $rows += , @( (New-Button "📋 القوالب" "menu:templates"), (New-Button "🎚 الطبقات" "menu:layers") )
    $rows += , @( (New-Button "ℹ️ الحالة" "menu:status") )
    if (Test-StatusViewer -ChatId $ChatId -UserId $UserId) {
        $rows += , @( (New-Button "📊 الحالة الكاملة" "menu:fullstatus") )
    }

    if (Get-Setting 'EnableFavorites') {
        # @() is mandatory, not decoration: a PowerShell function that returns
        # an empty array emits ZERO objects, so an unwrapped assignment yields
        # $null and $null.Count throws under Set-StrictMode. Same rule applies
        # to every array-returning helper called below.
        $favs = @(Get-FavoriteTemplateKeys -UserId $UserId)
        if ($favs.Count -gt 0) {
            $favRow = @()
            foreach ($key in $favs) {
                $idx = Get-TemplateIndex -Key $key
                if ($idx -ge 0) { $favRow += (New-Button "⭐ $key" "tpl:$idx") }
            }
            if ($favRow.Count -gt 0) { $rows += , $favRow }
        }
        $rows += , @( (New-Button "⭐ إدارة المفضلة" "menu:favorites") )
    }

    $rows += , @( (New-Button "🙈 اخفاء طبقة" "menu:hide"), (New-Button "🚪 خروج من المشهد" "menu:exit") )

    # Live layers and the emergency hide are rendered at the top of this
    # keyboard instead of here; see the on-air block above.
    $thirdRow = @()
    if ((Get-Setting 'EnableHideAll') -and $script:OnAir.Count -eq 0) {
        $thirdRow += (New-Button "🚨 إخفاء الكل" "menu:hideall")
    }
    if ($script:LastShow.ContainsKey($ChatId)) { $thirdRow += (New-Button "🔁 تكرار مع تعديل" "menu:repeat") }
    if ($thirdRow.Count -gt 0) { $rows += , $thirdRow }

    $fourthRow = @( (New-Button "✏️ تحديث نص" "menu:update") )
    if (Get-Setting 'EnableTimedShow') { $fourthRow += (New-Button "⏱ عرض مؤقّت" "menu:timed") }
    $rows += , $fourthRow
    $rows += , @( (New-Button "📅 الجدولة" 'menu:schedule') )
    $rows += , @( (New-Button "🧾 عملياتي" 'menu:myops'), (New-Button "🕘 ماذا فاتني" 'menu:digest') )
    $rows += , @( (New-Button "📊 تقارير" 'menu:reports') )
    if (Get-Setting 'EnableNewsTickerManagement') {
        $rows += , @( (New-Button "📰 إدارة شريط الأخبار" 'menu:news') )
    }

    if (Get-Setting 'EnableSnapshot') {
        $rows += , @( (New-Button "📸 صورة من البث" "menu:snapshot"), (New-Button "❓ مساعدة" "menu:help") )
        $rows += , @( (New-Button "🆕 ما الجديد" "menu:whatsnew") )
    }
    else {
        $rows += , @( (New-Button "❓ مساعدة" "menu:help"), (New-Button "🆕 ما الجديد" "menu:whatsnew") )
    }

    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $pendingCount = $script:PendingApprovals.Count
        $pendingLabel = if ($pendingCount -gt 0) { "👤 طلبات الوصول ($pendingCount)" } else { "👤 طلبات الوصول" }
        # Settings and access requests stay one tap away because they are used
        # during a shift. The rest is configuration an operator opens rarely,
        # and five permanent rows of it pushed the live controls off screen.
        $rows += , @( (New-Button "⚙️ الإعدادات" "menu:settings"), (New-Button $pendingLabel "menu:pending") )
        $rows += , @( (New-Button "🗂 أدوات الإدارة" "menu:admintools") )
    }
    return (ConvertTo-OneHandLayout -Keyboard @{ inline_keyboard = $rows })
}

function Get-RoleMainKeyboard {
    <# Stable Version 6 entry point; authorization remains in the compatible
       menu builder so existing role and owner rules stay authoritative. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
}

function Get-BridgeNavigationContext {
    param([int]$Page = 0, [string]$Filter = '', [string]$ReturnCallback = 'menu')
    return [pscustomobject]@{ Page = [math]::Max(0, $Page); Filter = $Filter; ReturnCallback = $ReturnCallback }
}

function Get-BridgeReadinessSummary {
    <# Summarizes an already captured snapshot. This function intentionally
       performs no Telegram, Cinegy, disk, or relay probe. #>
    param([Parameter(Mandatory)]$Snapshot)
    $telegram = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('Telegram')) { [string]$Snapshot['Telegram'] } elseif ($Snapshot.PSObject.Properties['Telegram']) { [string]$Snapshot.Telegram } else { 'unknown' }
    $cinegy = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('Cinegy')) { [string]$Snapshot['Cinegy'] } elseif ($Snapshot.PSObject.Properties['Cinegy']) { [string]$Snapshot.Cinegy } else { 'unknown' }
    $diskFree = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('DiskFreeGB')) { [double]$Snapshot['DiskFreeGB'] } elseif ($Snapshot.PSObject.Properties['DiskFreeGB']) { [double]$Snapshot.DiskFreeGB } else { 0 }
    $lastError = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('LastError')) { [string]$Snapshot['LastError'] } elseif ($Snapshot.PSObject.Properties['LastError']) { [string]$Snapshot.LastError } else { '' }
    $ready = $telegram -eq 'connected' -and $cinegy -eq 'healthy' -and $diskFree -gt 1 -and [string]::IsNullOrWhiteSpace($lastError)
    $label = if ($ready) { '🟢 جاهز للتشغيل' } else { '🟠 يحتاج مراجعة' }
    return [pscustomobject]@{ Ready = $ready; Text = "$label · Telegram: $telegram · Cinegy: $cinegy · القرص: $diskFree GB" }
}

function Get-MainMenuIntro {
    <# The line above the main menu. It used to read "اختر من القائمة:", which
       tells the operator nothing they cannot already see. Saying what is on
       air instead answers the question they actually opened the menu with,
       without spending a tap on ℹ️ الحالة. #>
    $freshness = Get-CinegyStateFreshness `
        -LastSuccessfulAt $(if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }) `
        -StaleAfterSeconds ([math]::Max(1, (Get-SettingInt 'CinegyStateCheckSeconds' 1) * 3))
    # How old the claim is matters as much as the claim: a stale 'on air' that
    # looks identical to a fresh one is what let an exited scene go unnoticed.
    $age = switch ($freshness.State) {
        'connected' { "تحقّق قبل $($freshness.AgeSeconds) ث" }
        'stale' { "⚠️ آخر تحقّق قبل $($freshness.AgeSeconds) ث" }
        'unavailable' { '⚠️ تعذّر التحقّق من Cinegy' }
        default { 'لم يتم التحقّق بعد' }
    }
    if ($script:OnAir.Count -eq 0) { return "⚫️ لا شيء على الهواء — $age" }
    $names = foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
        "$layer · $($script:OnAir[$layer].Key)"
    }
    return "🔴 على الهواء ($($script:OnAir.Count)): $((@($names)) -join ' | ')`n$age"
}

function Get-LayerRemovalSummary {
    <# Describes exactly what is about to be taken off air, so a confirmation
       says "lower-third, on air 4 د, pushed by Ahmed" rather than the layer
       number alone. A layer number is not something an operator can check
       against the screen under pressure; a template name is. #>
    param([Parameter(Mandatory)][int]$Layer)
    if (-not $script:OnAir.ContainsKey([int]$Layer)) {
        return "الطبقة $Layer — لا يوجد سجل لدى الجسر"
    }
    $record = $script:OnAir[[int]$Layer]
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("الطبقة $Layer · $($record.Key)")
    if ($record.At -is [datetime]) {
        $parts.Add("على الهواء منذ $(Format-Duration -Seconds ([int]((Get-Date) - $record.At).TotalSeconds))")
    }
    $source = if ($record.ContainsKey('Source')) { [string]$record.Source } else { 'bridge' }
    $parts.Add($(switch ($source) {
                'cinegy' { 'المصدر: Cinegy (خارج الجسر)' }
                'BotTest' { 'المصدر: اختبار قالب' }
                default { "أرسله: $(Get-UserDisplayName -UserId ([long]$record.UserId))" }
            }))
    return ($parts -join "`n")
}

function Get-LayerRemovalConfirmKeyboard {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][ValidateSet('hide', 'exit')][string]$Action)
    $label = if ($Action -eq 'hide') { '✅ نعم، أخفِ' } else { '✅ نعم، اخرج' }
    return @{ inline_keyboard = @(
            # Red here too, or turning ConfirmLayerRemoval ON - the safer
            # setting - would hand the operator the weaker screen.
            , @( (New-Button $label "${Action}go:$Layer" -Style danger), (New-Button '❌ إلغاء' 'menu') )
        ) }
}

function Get-AdminToolsKeyboard {
    <# The rarely-used administrator surface, split out of the main menu so a
       live-layer row is never pushed below the fold by configuration. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @()
    $rows += , @( (New-Button "👥 إدارة المستخدمين" "menu:usersadmin") )
    $rows += , @( (New-Button "🟢 نشاط المستخدمين" "menu:userpresence") )
    $rows += , @( (New-Button "⚡ إدارة النصوص الجاهزة" "menu:presetsadmin") )
    $rows += , @( (New-Button "📚 القوالب والإعدادات" "menu:templatesadmin") )

    if (Get-Setting 'EnableLiveRelay') {
        $relayRunning = [bool](Get-RunningRelayProcess)
        $relayLabel = if ($relayRunning) { "⏹ إيقاف البث" } else { "▶️ بدء البث" }
        $relayData = if ($relayRunning) { "menu:stream:stop" } else { "menu:stream:start" }
        $rows += , @( (New-Button $relayLabel $relayData), (New-Button "🔗 رابط البث" "menu:stream:seturl") )
    }

    $rows += , @( (New-Button "🧪 فحص المسار الحي" "menu:selftest"), (New-Button "📊 ملخص الاستخدام" "menu:usagedigest") )
    $rows += , @( (New-Button "🩺 صحة النظام" "menu:healthcenter"), (New-Button "📈 أرقام التشغيل" "menu:stats") )
    $rows += , @( (New-Button "📤 تصدير الإعدادات" "menu:cfgexport"), (New-Button "📥 استيراد الإعدادات" "menu:cfgimport") )
    if (Get-Setting 'AllowRemoteRestart') { $rows += , @( (New-Button "♻️ إعادة تشغيل الجسر" "menu:restart") ) }
    $adminRow = @( (New-Button "📜 السجل" "menu:audit"), (New-Button "🧪 التشخيص" "menu:diagnostics") )
    if (Get-Setting 'EnableRawCommand') { $adminRow += (New-Button "🛠 أمر خام" "menu:rawcmd") }
    $rows += , $adminRow
    $rows += , @( (New-Button "⬅️ الرئيسية" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-HealthCenterKeyboard {
    return @{ inline_keyboard = @(
            , @((New-Button '🔄 تحديث' 'menu:healthcenter'), (New-Button '📊 الحالة الكاملة' 'menu:fullstatus'))
            , @((New-Button '🧪 التشخيص' 'menu:diagnostics'), (New-Button '🗂 ملفات التشغيل' 'health:files'))
            , @((New-Button '⬅️ أدوات الإدارة' 'menu:admintools'))
        ) }
}

function Get-TemplateCategories {
    $store = Get-TemplateStore
    return @($store.Order | ForEach-Object { ([string]$store.Map[$_].Category).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TemplateLastUsedLabel {
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:TemplateLastUsed.ContainsKey($Key)) { return '' }
    return " · 🕘 $(([datetime]$script:TemplateLastUsed[$Key]).ToLocalTime().ToString('MM-dd HH:mm'))"
}

function Get-TemplatesKeyboard {
    <# Prefix selects what tapping a template does: tpl = show now,
       tplT = show with auto-hide, updtpl = pick a field to update. #>
    param([string]$Prefix = 'tpl', [string]$Category = '', [string]$Query = '', [switch]$BrowseControls)
    $store = Get-TemplateStore
    $rows = @()
    if ($BrowseControls -and $Prefix -eq 'tpl') {
        $rows += , @((New-Button '🔎 بحث' 'menu:templatesearch'), (New-Button '🗂 التصنيفات' 'menu:templatecategories'))
    }
    $matched = 0
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $t = $store.Map[$store.Order[$i]]
        if ($Category -and -not ([string]$t.Category).Equals($Category, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($Query) {
            $haystack = "$($t.Key) $($t.Description) $($t.Category)"
            if ($haystack.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $matched++
        # A lock badge here is the early warning: the operator sees the clash
        # before typing a single field, instead of after.
        $lockBadge = if ((Get-Setting 'ShowLayerLockBadge') -and $script:LayerLocks.ContainsKey([int]$t.Layer)) { '🔒 ' } else { '' }
        # The name only. The label used to carry the layer number and a
        # timestamp, which pushed it past ButtonTextMaxLength and left the
        # button reading "News-Ticker (طبقة 8) · 🕘 08-25…" - a half-cut date
        # that looks like noise. Layer, category and last use are all on the
        # ℹ️ screen, which has room for them.
        $templateRow = @((New-Button "$lockBadge$($t.Key)" "$Prefix`:$i"))
        if ($Prefix -eq 'tpl') { $templateRow += (New-Button 'ℹ️' "tplinfo:$i") }
        $rows += , $templateRow
        # Presets are only meaningful for an immediate show.
        if ($Prefix -eq 'tpl') {
            $presetRow = @()
            for ($p = 0; $p -lt $t.Presets.Count; $p++) {
                $presetRow += (New-Button "  ⚡ $($t.Presets[$p].Name)" "preset:$i`:$p")
                if ($presetRow.Count -eq 2) { $rows += , $presetRow; $presetRow = @() }
            }
            if ($presetRow.Count -gt 0) { $rows += , $presetRow }
        }
    }
    if ($matched -eq 0) {
        $rows += , @( (New-Button $(if ($Query -or $Category) { 'لا توجد نتائج مطابقة' } else { 'لا توجد قوالب معرّفة' }) "menu:templates") )
    }
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateCategoriesKeyboard {
    $categories = @(Get-TemplateCategories)
    $rows = @()
    for ($i = 0; $i -lt $categories.Count; $i++) { $rows += , @((New-Button "🗂 $($categories[$i])" "tplcat:$i")) }
    if ($categories.Count -eq 0) { $rows += , @((New-Button 'لا توجد تصنيفات معرّفة' 'menu:templates')) }
    $rows += , @((New-Button '📋 كل القوالب' 'menu:templates'), (New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Get-TemplatePreviewText {
    param([Parameter(Mandatory)]$Template)
    $category = if ([string]::IsNullOrWhiteSpace([string]$Template.Category)) { 'غير مصنف' } else { [string]$Template.Category }
    $description = if ([string]::IsNullOrWhiteSpace([string]$Template.Description)) { 'لا يوجد وصف.' } else { [string]$Template.Description }
    $fields = if (@($Template.Fields).Count -eq 0) { 'بلا حقول تحريرية' } else { @($Template.Fields) -join '، ' }
    $lastUsed = if ($script:TemplateLastUsed.ContainsKey([string]$Template.Key)) {
        ([datetime]$script:TemplateLastUsed[[string]$Template.Key]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    else { 'لم يُستخدم بعد' }
    $device = [string](Get-JsonProp $Template 'Device')
    # A device-backed template has no meaningful layer number - the number is
    # only the bridge's internal key - so showing it would be the same noise
    # the button just lost.
    $where = if ($device) { "طبقة الجهاز: $device" } else { "الطبقة: $($Template.Layer)" }
    $uses = if ($script:UsageCounts.ContainsKey([string]$Template.Key)) { "$($script:UsageCounts[[string]$Template.Key]) مرة" } else { 'لم يُستخدم' }
    $live = if ($script:OnAir.ContainsKey([int]$Template.Layer)) { '🔴 على الهواء الآن' } else { '⚫️ غير معروض' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("ℹ️ $($Template.Key)")
    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add($live)
    $lines.Add($where)
    $lines.Add("التصنيف: $category")
    $lines.Add("الحقول: $fields")
    $lines.Add('')
    $lines.Add($description)
    $lines.Add('')
    $lines.Add("الاستخدام: $uses · آخر مرة: $lastUsed")
    return ($lines -join "`n")
}

function Get-TemplatePreviewKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    return @{ inline_keyboard = @(
        , @((New-Button '▶️ اختيار هذا القالب' "tpl:$TemplateIndex"))
        , @((New-Button '⬅️ القوالب' 'menu:templates'))
    ) }
}

function Start-TemplateSearch {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'template_search'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text '🔎 أرسل جزءًا من اسم القالب أو وصفه أو تصنيفه:' -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-TemplateSearch {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_search') { return }
    Clear-PendingState -ChatId $ChatId
    $query = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($query)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لم تُدخل عبارة بحث.' -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -BrowseControls)
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text "🔎 نتائج البحث عن '$query':" -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Query $query -BrowseControls)
}

function Get-RetryDelaySeconds {
    param([int]$BaseSeconds, [int]$Attempt, [int]$Factor = 2, [int]$MaxSeconds = 300)
    $base = [math]::Max(1, $BaseSeconds)
    $safeAttempt = [math]::Min(31, [math]::Max(1, $Attempt))
    $safeFactor = [math]::Max(1, $Factor)
    $cap = [math]::Max(1, $MaxSeconds)
    $calculated = [double]$base * [math]::Pow([double]$safeFactor, [double]($safeAttempt - 1))
    return [int][math]::Min([double]$cap, $calculated)
}

function Get-ScheduleLayerConflicts {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [int]$WindowMinutes = 2,
        [string]$ExcludeId = ''
    )
    if ($Layer -le 0) { return @() }
    $window = [math]::Max(0, $WindowMinutes)
    foreach ($entry in @($script:ScheduleEvents)) {
        if ([string]$entry.Status -ne 'pending' -or ([string]$entry.Id -eq $ExcludeId -and $ExcludeId)) { continue }
        $entryLayer = 0
        [int]::TryParse([string](Get-JsonProp $entry 'Layer'), [ref]$entryLayer) | Out-Null
        if ($entryLayer -le 0) {
            $store = Get-TemplateStore
            $entryKey = [string]$entry.TemplateKey
            if ($store.Map.ContainsKey($entryKey)) { $entryLayer = [int]$store.Map[$entryKey].Layer }
        }
        if ($entryLayer -ne $Layer) { continue }
        $distance = [math]::Abs((([datetimeoffset]$entry.ScheduledAt) - $ScheduledAt).TotalMinutes)
        if ($distance -le $window) { Write-Output $entry }
    }
}

function Get-UsersAdminKeyboard {
    <# The promote/demote row is drawn only for an owner. An administrator who
       cannot use it should not be looking at it: a button that always answers
       "not allowed" is worse than no button at all. #>
    param(
        [long]$ViewerUserId = 0,
        [int]$Page = 0,
        [ValidateRange(1, 15)][int]$PageSize = 10
    )
    $isOwner = $ViewerUserId -gt 0 -and (Test-Owner -ChatId $ViewerUserId -UserId $ViewerUserId)
    $rows = @()
    $users = @(Get-AuthorizedUsers)
    $window = Get-BridgePageWindow -ItemCount $users.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
        $user = $users[$index]
        $role = switch ($user.Role) { 'owner' { '👑 مالك' } 'admin' { 'مشرف' } default { 'مشغّل' } }
        $state = if ($user.Disabled) { '⛔ معطّل' } else { '✅ نشط' }
        $rows += , @((New-Button "$state · $($user.Alias) · $role" "usr:toggle:$($user.UserId)"))
        $rows += , @((New-Button "✏️ Alias · $($user.Alias)" "usr:alias:$($user.UserId)"))
        $activityWindow = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
        $activity = Get-UserActivityStatus -LastActivityAt ([string]$user.LastActivityAt) -ActiveWithinMinutes $activityWindow
        $rows += , @((New-Button $activity.Label "usr:activity:$($user.UserId)"))
        # No role button on the owner's own row: there is nothing to promote
        # them to, and demoting them is refused anyway.
        if ($isOwner -and $user.Role -ne 'owner') {
            $rows += , @($(if ($user.Role -eq 'admin') {
                        (New-Button "⬇️ خفض $($user.Alias) إلى مشغّل" "usr:demote:$($user.UserId)")
                    }
                    else {
                        (New-Button "⬆️ ترقية $($user.Alias) إلى مشرف" "usr:promote:$($user.UserId)")
                    }))
        }
        $rows += , @((New-Button "🗑 سحب صلاحية $($user.Alias)" "usr:revoke:$($user.UserId)"))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "userspage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "userspage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "userspage:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @((New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Show-UsersAdminScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -le 0) { $UserId = $ChatId }
    $roleLine = if (Test-Owner -ChatId $ChatId -UserId $UserId) {
        "`n👑 بصفتك المالك يمكنك ترقية مشغّل إلى مشرف أو خفضه."
    }
    else { '' }
    Send-TelegramMessage -ChatId $ChatId -Text ("👥 المستخدمون المصرح لهم`nاضغط المستخدم لتعطيله أو إعادة تفعيله، واستخدم ✏️ Alias لتعديل اسمه التشغيلي، أو زر السحب مع التأكيد.`nحالة النشاط تقريبية حسب آخر تفاعل؛ Telegram لا يوفّر اتصالًا لحظيًا للبوت.$roleLine") `
        -ReplyMarkup (Get-UsersAdminKeyboard -ViewerUserId $UserId -Page $Page)
}

function Start-UserAliasEdit {
    param(
        [Parameter(Mandatory)][long]$TargetUserId,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$AdminUserId
    )
    if (-not (Test-Admin -ChatId $ChatId -UserId $AdminUserId)) { return }
    if (@(Get-AuthorizedUsers | Where-Object UserId -eq $TargetUserId).Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'المستخدم لم يعد ضمن قائمة المصرح لهم.' -ReplyMarkup (Get-UsersAdminKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode='user_alias_edit'; TargetUserId=$TargetUserId; UserId=$AdminUserId }
    $current = Get-UserDisplayName -UserId $TargetUserId
    Send-TelegramMessage -ChatId $ChatId -Text "✏️ الاسم التشغيلي للمستخدم $TargetUserId`nالحالي: $current`n`nأرسل الاسم الجديد، أو أرسل - لحذف الـAlias." -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-UserAliasEdit {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$AdminUserId,
        [AllowEmptyString()][string]$Value = ''
    )
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'user_alias_edit' -or [long]$state.UserId -ne $AdminUserId) { return $false }
    $target = [long]$state.TargetUserId
    $alias = $Value.Trim()
    if ($alias -eq '-') { $alias = '' }
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = '' }
    if (-not (Set-UserAlias -TargetUserId $target -Alias $alias)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر حفظ الاسم التشغيلي.' -ReplyMarkup (Get-UsersAdminKeyboard)
        return $false
    }
    Clear-PendingState -ChatId $ChatId
    $action = if ($alias) { "تعيين اسم بديل '$alias'" } else { 'حذف الاسم البديل' }
    Write-BridgeLog "Admin $AdminUserId updated alias for user ${target}: $action"
    Add-AuditEntry "👤 $action للمستخدم $(Format-UserAuditActor -UserId ([long]$target)) - بواسطة $(Format-UserAuditActor -UserId $AdminUserId)"
    Show-UsersAdminScreen -ChatId $ChatId
    return $true
}

function Get-FavoritesManagementKeyboard {
    param([Parameter(Mandatory)][long]$UserId)
    $store = Get-TemplateStore; $selected = @(Get-FavoriteTemplateKeys -UserId $UserId); $rows = @()
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $key = [string]$store.Order[$i]
        $mark = if ($selected -contains $key) { '✅' } else { '▫️' }
        $rows += , @((New-Button "$mark $key" "favtoggle:$i"))
    }
    $rows += , @((New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Get-LayersKeyboard {
    param([Parameter(Mandatory)][string]$Prefix)
    $rows = @()
    $row = @()
    foreach ($l in (Get-KnownLayers)) {
        $row += (New-Button (Get-LayerDisplayName -Layer $l) "$Prefix`:$l")
        if ($row.Count -eq 4) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-PresetAdminTemplatesKeyboard {
    $store = Get-TemplateStore
    $rows = @()
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $template = $store.Map[$store.Order[$i]]
        $rows += , @( (New-Button "$($template.Key) ($(@($template.Presets).Count))" "padm:$i") )
    }
    $rows += , @( (New-Button "⬅️ القائمة" 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-PresetAdminKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    $rows = @()
    if ($template) {
        for ($i = 0; $i -lt @($template.Presets).Count; $i++) {
            $rows += , @( (New-Button "⚡ $($template.Presets[$i].Name)" "pa:$TemplateIndex`:$i") )
        }
        $rows += , @( (New-Button "➕ إنشاء نص جاهز" "pac:$TemplateIndex") )
    }
    $rows += , @( (New-Button "⬅️ القوالب" 'menu:presetsadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-PresetActionKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex)
    return @{ inline_keyboard = @(
            , @( (New-Button "✏️ تعديل القيم" "pae:$TemplateIndex`:$PresetIndex"), (New-Button "🏷 إعادة تسمية" "par:$TemplateIndex`:$PresetIndex") )
            , @( (New-Button "🗑 حذف" "pad:$TemplateIndex`:$PresetIndex" -Style danger), (New-Button "⬅️ رجوع" "padm:$TemplateIndex") )
        ) }
}

function Get-PresetReviewKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "✅ حفظ التغيير" 'presetadmin:confirm' -Style success), (New-Button "❌ إلغاء" 'cancel') )
        ) }
}

function Get-ScheduleMenuKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "➕ جدولة عرض" 'schedule:new'), (New-Button "📋 الأحداث القادمة" 'schedule:list') )
            , @( (New-Button "⬅️ القائمة" 'menu') )
        ) }
}

function Get-ScheduleRecurrenceKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "مرة واحدة" 'schrec:once'), (New-Button "يومي" 'schrec:daily'), (New-Button "أسبوعي" 'schrec:weekly') )
            , @( (New-Button "❌ إلغاء" 'cancel') )
        ) }
}

function Get-ScheduleReviewKeyboard {
    param([hashtable]$State)
    $rows = @()
    if ($State -and [string]$State.Recurrence -ne 'once') {
        $rows += , @((New-Button '📆 تحديد نهاية التكرار' 'schedule:setend'), (New-Button '♾ بدون انتهاء' 'schedule:clearend'))
    }
    $rows += , @((New-Button "✅ تأكيد الجدولة" 'schedule:confirm' -Style success), (New-Button "❌ إلغاء" 'cancel'))
    return @{ inline_keyboard = $rows }
}

function Get-UpcomingScheduleKeyboard {
    $rows = @()
    foreach ($scheduleEntry in @(Get-UpcomingScheduleEvents)) {
        $at = [datetimeoffset]$scheduleEntry.ScheduledAt
        $rows += , @(
            (New-Button "✏️ $($scheduleEntry.TemplateKey) $($at.ToString('MM-dd HH:mm'))" "schededit:$($scheduleEntry.Id)"),
            (New-Button '📄 نسخ' "schedcopy:$($scheduleEntry.Id)"),
            (New-Button '🗑' "schcancel:$($scheduleEntry.Id)")
        )
    }
    $rows += , @( (New-Button "⬅️ الجدولة" 'menu:schedule') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerDashboardKeyboard {
    param([Parameter(Mandatory)][object[]]$LayerStatuses)
    $rows = @()
    $row = @()
    foreach ($status in @($LayerStatuses | Sort-Object Layer)) {
        $layer = [int]$status.Layer
        if (-not $status.Success) {
            $button = New-Button "🔄 فحص ومقارنة · $(Get-LayerDisplayName -Layer $layer)" 'menu:layers'
        }
        elseif ($status.IsOnAir) {
            $button = New-Button "🙈 إخفاء $(Get-LayerDisplayName -Layer $layer)" "hide:$layer" -Style danger
        }
        else {
            $button = New-Button "🔄 تحديث · $(Get-LayerDisplayName -Layer $layer) مخفية" 'menu:layers'
        }
        $row += $button
        if ($row.Count -eq 2) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button "🔎 فحص ومقارنة مع Cinegy" 'menu:layers'), (New-Button "⬅️ رجوع" 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-FieldsKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $t = Get-TemplateByIndex -Index $TemplateIndex
    $rows = @()
    if ($t) {
        for ($f = 0; $f -lt $t.Fields.Count; $f++) {
            $label = [string]$t.Fields[$f]
            if ($f -lt @($t.FieldLabels).Count -and $t.FieldLabels[$f]) { $label = [string]$t.FieldLabels[$f] }
            $rows += , @( (New-Button $label "updf:$TemplateIndex`:$f") )
        }
    }
    $rows += , @( (New-Button "⬅️ رجوع" "menu:update") )
    return @{ inline_keyboard = $rows }
}

function Get-AfterShowKeyboard {
    <# Shown with the "on air" confirmation: hide/exit that exact layer without
       hunting through menus, plus the usual main menu underneath. #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $first = @( (New-Button "🙈 إخفاء هذا (طبقة $Layer)" "hide:$Layer" -Style danger), (New-Button "🚪 خروج" "exit:$Layer" -Style danger) )
    if (Get-Setting 'EnableTimedShow') { $first += (New-Button "⏱ مؤقت" "timer:$Layer") }
    $rows = @( , $first )
    if (Get-RollbackCandidate -Layer $Layer -UserId $UserId) { $rows += , @((New-Button '↩️ تراجع آمن' "rollback:$Layer")) }
    $rows += $menu.inline_keyboard
    return @{ inline_keyboard = $rows }
}

function Get-AfterLayerRemovalKeyboard {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $rows = @()
    if (Get-RollbackCandidate -Layer $Layer -UserId $UserId) { $rows += , @((New-Button '↩️ استعادة المشهد السابق' "rollback:$Layer")) }
    $rows += $menu.inline_keyboard
    return @{ inline_keyboard=$rows }
}

function Get-RollbackReviewKeyboard {
    param([Parameter(Mandatory)][int]$Layer)
    return @{ inline_keyboard=@(
        , @((New-Button '✅ تأكيد التراجع' "rollbackconfirm:$Layer" -Style success), (New-Button '❌ إلغاء' 'menu'))
    ) }
}

function Get-CancelKeyboard {
    return @{ inline_keyboard = @( , @( (New-Button "❌ إلغاء" "cancel") ) ) }
}

function Get-FieldPromptKeyboard {
    param([hashtable]$State)
    $rows = @()
    if ($State -and $State.Fields -and [int]$State.Index -lt @($State.Fields).Count) {
        $index = [int]$State.Index
        $fieldName = [string]$State.Fields[$index]
        $isSensitive = Test-SensitiveFieldName -FieldName $fieldName
        if ($State.ContainsKey('Sensitives') -and $index -lt @($State.Sensitives).Count) {
            $isSensitive = $isSensitive -or [bool]$State.Sensitives[$index]
        }
        if (-not $isSensitive) {
            $recent = @(Get-RecentFieldValues -UserId ([long]$State.UserId) -FieldName $fieldName)
            for ($i = 0; $i -lt $recent.Count; $i++) {
                $label = [string]$recent[$i]
                if ($label.Length -gt 32) { $label = $label.Substring(0, 29) + '...' }
                $rows += , @( (New-Button "🕘 $label" "recent:$i") )
            }
        }
    }
    $row = @()
    if ($State -and [int]$State.Index -gt 0) { $row += (New-Button "⬅️ السابق" "show:back") }
    if ($State -and $State.Values.Count -gt 0) { $row += (New-Button "🔎 معاينة" "show:preview") }
    $row += (New-Button "⏭ تخطي" "skip")
    $row += (New-Button "❌ إلغاء" "cancel")
    $rows += , $row
    return @{ inline_keyboard = $rows }
}

function Get-ShowReviewKeyboard {
    param([switch]$HasFields)
    $row = @( (New-Button "✅ تأكيد الإرسال" "show:confirm" -Style success) )
    if ($HasFields) { $row += (New-Button "✏️ تعديل" "show:edit") }
    return @{ inline_keyboard = @( , $row; , @( (New-Button "❌ إلغاء" "cancel") ) ) }
}

function Get-HideAllConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "🚨 نعم، إخفاء الكل" "hideall:confirm" -Style danger), (New-Button "❌ إلغاء" "cancel") )
        ) }
}

function Get-ApprovalKeyboard {
    param([Parameter(Mandatory)][long]$TargetChatId)
    return @{ inline_keyboard = @(
            , @( (New-Button "✅ موافقة" "approve:$TargetChatId" -Style success), (New-Button "❌ رفض" "reject:$TargetChatId") )
            , @( (New-Button "⬅️ الرئيسية" "menu") )
        ) }
}

function Get-PendingKeyboard {
    param([int]$Page = 0, [ValidateRange(1, 40)][int]$PageSize = 20)
    $rows = @()
    $ids = @($script:PendingApprovals.Keys | Sort-Object { [long]$_ })
    $window = Get-BridgePageWindow -ItemCount $ids.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
        $id = $ids[$index]
        $info = $script:PendingApprovals[$id]
        $label = if ($info.Name) { "$($info.Name)" } else { "$id" }
        $rows += , @( (New-Button "✅ $label" "approve:$id"), (New-Button "❌" "reject:$id") )
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "pendingpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "pendingpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "pendingpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button "لا توجد طلبات معلّقة حاليًا" "menu") ) }
    else { $rows += , @( (New-Button "⬅️ رجوع" "menu") ) }
    return @{ inline_keyboard = $rows }
}

function Get-SettingCategoryDefinitions {
    return @($script:SettingCategoryDefinitions)
}

function Get-SettingNavigationMetadata {
    param([Parameter(Mandatory)][string]$Name)
    $record = @($script:SettingSchema | Where-Object Name -eq $Name)
    if ($record.Count -eq 1) { return $record[0] }
    return [pscustomobject]@{ Name = $Name; Category = 'advanced'; Label = $Name }
}

function Get-SettingsInCategory {
    param([Parameter(Mandatory)][string]$Category)
    foreach ($record in @($script:SettingSchema)) {
        if ($record.Category -eq $Category) { $record.Name }
    }
}

function Get-SettingsKeyboard {
    $rows = @()
    $categoryRow = @()
    foreach ($category in @(Get-SettingCategoryDefinitions)) {
        $categoryRow += (New-Button "$($category.Icon) $($category.Label)" "cfgcat:$($category.Key):0")
        if ($categoryRow.Count -eq 2) {
            $rows += , $categoryRow
            $categoryRow = @()
        }
    }
    if ($categoryRow.Count -gt 0) { $rows += , $categoryRow }

    $rows += , @((New-Button '🔎 بحث' 'cfg:search'), (New-Button '📝 المعدّل فقط' 'cfglist:modified:0'))
    $rows += , @((New-Button '🧭 مبسّط' 'cfglist:simple:0'), (New-Button '🛠 متقدم' 'cfglist:advanced:0'))

    $scope = [string](Get-Setting 'HideAllLayers')
    $scopeLabel = if ($scope.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { 'كل الطبقات المعروفة' } elseif ($scope.Trim()) { "طبقات: $scope" } else { 'لا توجد طبقات محددة' }
    $rows += , @( (New-Button "🚨 طبقات إخفاء الكل: $scopeLabel" 'menu:hideallsettings') )
    $rows += , @( (New-Button '🏷️ أسماء الطبقات' 'menu:layernames') )
    $rows += , @( (New-Button "🗄 نسخ الإعدادات" "menu:backups"), (New-Button "♻️ استعادة الافتراضي" "cfg:reset" -Style danger) )
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-SettingsListKeyboard {
    param([AllowEmptyCollection()][object[]]$Records = @(), [string]$Mode = 'simple', [int]$Page = 0, [int]$PageSize = 8)
    $items = @($Records)
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize $PageSize
    $rows = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $record = $items[$index]
            $name = [string]$record.Name
            $value = Get-Setting $name
            $action = if ($script:DefaultSettings[$name] -is [bool]) { "cfg:t:$name" } elseif ($script:DefaultSettings[$name] -is [string]) { "cfg:s:$name" } else { "cfg:v:$name" }
            $rows += , @((New-Button "$($record.Label) = $value" $action), (New-Button '↩️' "cfgr:$name"))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️' "cfglist:${Mode}:$($window.Page - 1)") }
        if ($window.HasNext) { $pager += (New-Button '➡️' "cfglist:${Mode}:$($window.Page + 1)") }
        $rows += , $pager
    }
    if ($items.Count -eq 0) { $rows += , @((New-Button 'لا توجد نتائج' 'menu:settings')) }
    $rows += , @((New-Button '⬅️ الإعدادات' 'menu:settings'))
    return @{ inline_keyboard = $rows }
}

function Get-SingleSettingResetConfirmKeyboard {
    param([Parameter(Mandatory)][string]$Name)
    return @{ inline_keyboard = @(, @((New-Button '✅ إعادة هذا الإعداد' "cfgrgo:$Name" -Style danger), (New-Button '❌ إلغاء' 'menu:settings'))) }
}

function Get-SettingsCategoryKeyboard {
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateRange(0, [int]::MaxValue)][int]$Page = 0,
        [ValidateRange(1, 20)][int]$PageSize = 8
    )
    $definition = @($script:SettingCategoryDefinitions | Where-Object { $_.Key -eq $Category })
    if ($definition.Count -ne 1) { return (Get-SettingsKeyboard) }

    $names = @(Get-SettingsInCategory -Category $Category)
    $pageCount = [math]::Max(1, [int][math]::Ceiling($names.Count / [double]$PageSize))
    $safePage = [math]::Min($Page, $pageCount - 1)
    $start = $safePage * $PageSize
    $end = [math]::Min($start + $PageSize - 1, $names.Count - 1)
    $rows = @()

    if ($names.Count -gt 0) {
        foreach ($name in @($names[$start..$end])) {
            $value = Get-Setting $name
            $metadata = Get-SettingNavigationMetadata -Name $name
            if ($name -eq 'HideAllLayers') {
                $scope = [string]$value
                $scopeLabel = if ($scope.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) {
                    'كل الطبقات المعروفة'
                }
                elseif ($scope.Trim()) { "طبقات: $scope" }
                else { 'لا توجد طبقات محددة' }
                $rows += , @( (New-Button "🚨 $($metadata.Label) · $scopeLabel" 'menu:hideallsettings' -MaxTextLength 64) )
            }
            elseif ($name -eq 'LayerNames') {
                $namedLayers = @([string]$value -split ';' | Where-Object { $_.Trim() -match '^\d+\s*=\s*.+$' }).Count
                $rows += , @( (New-Button "🏷️ $($metadata.Label) · $namedLayers تسمية" 'menu:layernames' -MaxTextLength 64) )
            }
            elseif ($script:DefaultSettings[$name] -is [bool]) {
                $mark = if ($value) { '✅' } else { '❌' }
                $state = if ($value) { 'مفعّل' } else { 'معطّل' }
                $lock = if ($script:ProtectedSettings -contains $name) { '🔒 ' } else { '' }
                $rows += , @( (New-Button "$mark $lock$($metadata.Label) · $state" "cfg:t:$name" -MaxTextLength 64) )
            }
            elseif ($script:DefaultSettings[$name] -is [string]) {
                $prefix = if ($name -eq 'NewsFilePath') { '📰 ملف الأخبار' } else { "🔤 $($metadata.Label)" }
                $rows += , @( (New-Button "$prefix · $value" "cfg:s:$name" -MaxTextLength 64) )
            }
            else {
                $display = Format-SettingDisplay -Name $name -Value $value
                $rows += , @( (New-Button "🔢 $($metadata.Label) · $display" "cfg:v:$name" -MaxTextLength 64) )
            }
        }
    }

    if ($pageCount -gt 1) {
        $navigation = @()
        if ($safePage -gt 0) { $navigation += (New-Button '⬅️ السابق' "cfgcat:$Category`:$($safePage - 1)") }
        $navigation += (New-Button "$($safePage + 1)/$pageCount" "cfgcat:$Category`:$safePage")
        if ($safePage + 1 -lt $pageCount) { $navigation += (New-Button 'التالي ➡️' "cfgcat:$Category`:$($safePage + 1)") }
        $rows += , $navigation
    }
    $rows += , @( (New-Button '⬅️ أقسام الإعدادات' 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminCatalogueKeyboard {
    param(
        [long]$ChatId = 0,
        [long]$UserId = 0,
        [int]$Page = 0,
        [ValidateRange(1, 40)][int]$PageSize = 20
    )
    if ($UserId -eq 0 -and $ChatId -ne 0) { $UserId = $ChatId }
    $canAdminister = ($ChatId -eq 0) -or (Test-Admin -ChatId $ChatId -UserId $UserId)
    $store = Get-TemplateStore
    $rows = @()
    $window = Get-BridgePageWindow -ItemCount $store.Order.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
    for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) {
        $template = $store.Map[$store.Order[$i]]
        $rows += , @( (New-Button "$($template.Key) (طبقة $($template.Layer))" "tadm:$i") )
    }
    }
    if ($canAdminister) {
        $transferRow = @((New-Button '📤 تصدير JSON' 'timport:export'))
        if (Get-Setting 'EnableFullTemplateManagement') { $transferRow += (New-Button '📥 استيراد JSON' 'timport:start') }
        $rows += , $transferRow
    }
    if ($canAdminister -and (Get-Setting 'EnableFullTemplateManagement')) {
        $rows += , @( (New-Button '➕ إضافة قالب' 'tadm:create') )
        $rows += , @( (New-Button '📄 إضافة عبر JSON' 'tadm:createjson') )
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "tadmpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "tadmpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "tadmpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button 'لا توجد قوالب صالحة' 'menu') ) }
    $rows += , @( (New-Button '⬅️ القائمة' 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminDetailKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex, [long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0 -and $ChatId -ne 0) { $UserId = $ChatId }
    $canAdminister = ($ChatId -eq 0) -or (Test-Admin -ChatId $ChatId -UserId $UserId)
    $canManageReminder = ($ChatId -eq 0) -or (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId)
    $rows = @()
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if ($canManageReminder -and $template -and -not [bool](Get-JsonProp $template 'LongRunning')) {
        $rows += , @( (New-Button '🔔 تنبيه الظهور' "tadm:reminder:$TemplateIndex") )
    }
    if ($canAdminister -and (Get-Setting 'EnableFullTemplateManagement')) {
        $rows += , @( (New-Button '✏️ تعديل التعريف' "tadm:edit:$TemplateIndex"), (New-Button '🗑 حذف القالب' "tadm:delete:$TemplateIndex" -Style danger) )
        if ((Get-SettingInt 'TemplateTestLayer' 0) -gt 0) { $rows += , @((New-Button '🧪 اختبار على طبقة التجربة' "tadm:test:$TemplateIndex")) }
    }
    $rows += , @( (New-Button '⬅️ القوالب' 'menu:templatesadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateDefinitionReviewKeyboard {
    return @{ inline_keyboard = @(
        , @( (New-Button '✅ حفظ التغيير' 'tadm:confirm' -Style success), (New-Button '❌ إلغاء' 'menu:templatesadmin') )
    ) }
}

function Get-HideAllLayerSettingsKeyboard {
    $selected = @(Get-HideAllTargetLayers)
    $allMode = ([string](Get-Setting 'HideAllLayers')).Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)
    $rows = @()
    foreach ($layer in @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
        $mark = if ($allMode -or $selected -contains $layer) { '✅' } else { '⬜' }
        $rows += , @( (New-Button "$mark طبقة $layer" "hideallcfg:toggle:$layer") )
    }
    $rows += , @( (New-Button "☑️ اختيار كل الطبقات" 'hideallcfg:all'), (New-Button "🚫 إلغاء اختيار الكل" 'hideallcfg:none') )
    $rows += , @( (New-Button "⬅️ الإعدادات" 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerNamesKeyboard {
    $rows = @()
    foreach ($layer in @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
        $rows += , @( (New-Button "🏷️ $(Get-LayerDisplayName -Layer $layer)" "layername:$layer") )
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button 'لا توجد طبقات معرفة' 'menu:settings') ) }
    $rows += , @( (New-Button '⬅️ الإعدادات' 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerNameEditKeyboard {
    param([Parameter(Mandatory)][int]$Layer)
    return @{ inline_keyboard = @(
            , @( (New-Button '🗑️ مسح الاسم' "layername:clear:$Layer" -Style danger) )
            , @( (New-Button '⬅️ أسماء الطبقات' 'menu:layernames'), (New-Button '❌ إلغاء' 'menu:settings') )
        ) }
}

function Get-ConfigBackupsKeyboard {
    param([string]$Path = $ConfigPath)
    $backupDirectory = "$Path.backups"
    $files = if (Test-Path -LiteralPath $backupDirectory) {
        @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' | Sort-Object LastWriteTimeUtc, Name -Descending)
    }
    else { @() }
    $rows = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $label = $files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $rows += , @( (New-Button "🗄 $label" "cfg:restore:$i") )
    }
    if ($files.Count -eq 0) { $rows += , @( (New-Button "لا توجد نسخ محفوظة" 'menu:settings') ) }
    $rows += , @( (New-Button "⬅️ رجوع" 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-ConfigRestoreConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "⚠️ نعم، استعادة النسخة" 'cfg:restoreconfirm' -Style danger), (New-Button "❌ إلغاء" 'menu:backups') )
        ) }
}

function Get-SettingConfirmKeyboard {
    param([Parameter(Mandatory)][string]$Name)
    return @{ inline_keyboard = @( , @( (New-Button "⚠️ نعم، عطّل الحماية" "cfgc:$Name" -Style danger), (New-Button "❌ إلغاء" "menu:settings") ) ) }
}

function Get-AutoHideChoices {
    <# Quick-pick durations, parsed from the AutoHidePresetSeconds setting so
       an admin can retune them without touching code. Bad entries are ignored
       rather than breaking the keyboard. #>
    $raw = [string](Get-Setting 'AutoHidePresetSeconds')
    $values = @()
    foreach ($part in ($raw -split '[,;\s]+')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -gt 0) { $values += $n }
    }
    if ($values.Count -eq 0) { $values = @(5, 10, 15, 30, 60) }
    return @($values | Sort-Object -Unique)
}

function Format-Duration {
    <# Kept for its callers, but it no longer counts in minutes for ever: a
       ticker on air since yesterday read as "1560 د", a number the reader has
       to divide twice. Format-DurationSeconds does the counting now. #>
    param([int]$Seconds)
    return (Format-DurationSeconds -Seconds $Seconds)
}

function Get-DurationKeyboard {
    <# Shared duration picker. Prefix 'dur' targets a template about to be
       shown; 'tlay' targets a layer that is already on air. The default is
       marked so the common case stays one tap. #>
    param(
        [Parameter(Mandatory)][ValidateSet('dur', 'tlay')][string]$Prefix,
        [Parameter(Mandatory)][string]$Token,
        [string]$BackData = 'menu'
    )
    $default = Get-SettingInt 'AutoHideDefaultSeconds' 0
    $rows = @()
    $row = @()
    foreach ($sec in (Get-AutoHideChoices)) {
        $mark = if ($sec -eq $default) { "⭐ " } else { "" }
        $row += (New-Button "$mark$(Format-Duration -Seconds $sec)" "$Prefix`:$Token`:$sec")
        if ($row.Count -eq 3) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button "⌨️ مدة أخرى" "$Prefix`:$Token`:c") )
    $rows += , @( (New-Button "⬅️ رجوع" $BackData) )
    return @{ inline_keyboard = $rows }
}

function Get-SettingChoiceKeyboard {
    <# String settings are picked from a fixed list rather than typed, so a
       typo cannot quietly break graphics. Index-based callback data keeps it
       inside the 64-byte budget. #>
    param([Parameter(Mandatory)][string]$Name)
    $rows = @()
    $choices = @($script:SettingChoices[$Name])
    $current = [string](Get-Setting $Name)
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $mark = if ($choices[$i] -eq $current) { "✅ " } else { "" }
        $rows += , @( (New-Button "$mark$($choices[$i])" "cfgs:$Name`:$i") )
    }
    $rows += , @( (New-Button "⬅️ رجوع" "menu:settings") )
    return @{ inline_keyboard = $rows }
}

function Show-SettingChoices {
    <# String settings come in two flavours: a constrained list (AirVariableType)
       gets a pick-list, anything else gets a free-text prompt. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:SettingChoices.ContainsKey($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text "اختر قيمة $Name`:" -ReplyMarkup (Get-SettingChoiceKeyboard -Name $Name)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'setting_text'; Name = $Name; UserId = $UserId }
    $prompt = if ($Name -eq 'NewsFilePath') {
        "أرسل المسار المطلق لملف الأخبار بصيغة TXT.`nالحالي: $(Get-Setting $Name)`nالافتراضي: $($script:DefaultSettings[$Name])`nلن يتم إنشاء الملف أو تعديله في هذه الخطوة."
    }
    else { "أرسل القيمة الجديدة لـ $Name (الحالية: $(Get-Setting $Name)، الافتراضية: $($script:DefaultSettings[$Name])):" }
    Send-TelegramMessage -ChatId $ChatId -Text $prompt -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-SettingText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ القيمة فارغة، لم يتغيّر شيء." -ReplyMarkup (Get-SettingsKeyboard)
        Clear-PendingState -ChatId $ChatId
        return
    }
    if ($state.Name -eq 'NewsFilePath' -and -not (Test-NewsTickerFilePathSetting -Path $trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ يجب إدخال مسار مطلق ينتهي بـ .txt، مثل:`nD:\cingy cg\ticker msg\news.txt`nلم يتغيّر الإعداد." -ReplyMarkup (Get-SettingsKeyboard)
        Clear-PendingState -ChatId $ChatId
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-Setting -Name $state.Name -Value $trimmed
    Write-BridgeLog "User $($state.UserId) set $($state.Name) = $trimmed"
    Add-AuditEntry "⚙️ $($state.Name) = $trimmed - بواسطة $(Format-UserAuditActor -UserId ([long]$state.UserId))"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $($state.Name) = $trimmed$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}

function Set-SettingChoice {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $choices = @($script:SettingChoices[$Name])
    if ($Index -lt 0 -or $Index -ge $choices.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "خيار غير صالح." -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    if ($Name -eq 'SceneMode' -and [string]$choices[$Index] -eq 'Multi') {
        try {
            $statuses = @(Get-CinegyLayerDashboard)
            $capabilities = Get-CinegySceneCapabilities -SceneItems $statuses -LayerTargetSupported $true
            $mode = Test-BridgeSceneMode -RequestedMode Multi -Capabilities $capabilities
            if ($mode.Mode -ne 'Multi') {
                Send-TelegramMessage -ChatId $ChatId -Text "⛔ $($mode.Error)" -ReplyMarkup (Get-SettingsKeyboard)
                return
            }
        }
        catch {
            Send-TelegramMessage -ChatId $ChatId -Text "⛔ وضع المشاهد المتعددة غير متاح: تعذّر التحقق من Cinegy." -ReplyMarkup (Get-SettingsKeyboard)
            return
        }
    }
    Set-Setting -Name $Name -Value $choices[$Index]
    Write-BridgeLog "User $UserId set $Name = $($choices[$Index])"
    Add-AuditEntry "⚙️ $Name = $($choices[$Index]) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $Name = $($choices[$Index])$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}
