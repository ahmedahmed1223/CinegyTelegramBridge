#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function New-Button {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Data)
    $maxLength = Get-SettingInt 'ButtonTextMaxLength'
    $displayText = $Text
    if ($maxLength -gt 1 -and (Get-TextElementCount -Text $Text) -gt $maxLength) {
        $info = [Globalization.StringInfo]::new($Text)
        $displayText = $info.SubstringByTextElements(0, $maxLength - 1).TrimEnd() + '…'
    }
    return @{ text = $displayText; callback_data = $Data }
}

function Get-MainMenuKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @()
    $rows += , @( (New-Button "📋 القوالب" "menu:templates"), (New-Button "🎚 الطبقات" "menu:layers") )
    $rows += , @( (New-Button "ℹ️ الحالة" "menu:status") )
    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
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

    # One tap per live layer, so taking a wrong graphic off air is immediate
    # and the operator can see at a glance what the bridge believes is up.
    if ($script:OnAir.Count -gt 0) {
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $liveRow = @( (New-Button "🔴 إخفاء $layer · $($script:OnAir[$layer].Key)" "hide:$layer") )
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
    }

    $thirdRow = @()
    if (Get-Setting 'EnableHideAll') { $thirdRow += (New-Button "🚨 إخفاء الكل" "menu:hideall") }
    if ($script:LastShow.ContainsKey($ChatId)) { $thirdRow += (New-Button "🔁 تكرار مع تعديل" "menu:repeat") }
    if ($thirdRow.Count -gt 0) { $rows += , $thirdRow }

    $fourthRow = @( (New-Button "✏️ تحديث نص" "menu:update") )
    if (Get-Setting 'EnableTimedShow') { $fourthRow += (New-Button "⏱ عرض مؤقّت" "menu:timed") }
    $rows += , $fourthRow
    $rows += , @( (New-Button "📅 الجدولة" 'menu:schedule') )
    $rows += , @( (New-Button "🧾 عملياتي" 'menu:myops') )
    if (Get-Setting 'EnableNewsTickerManagement') {
        $rows += , @( (New-Button "📰 إدارة شريط الأخبار" 'menu:news') )
    }

    if (Get-Setting 'EnableSnapshot') {
        $rows += , @( (New-Button "📸 صورة من البث" "menu:snapshot"), (New-Button "❓ مساعدة" "menu:help") )
    }
    else {
        $rows += , @( (New-Button "❓ مساعدة" "menu:help") )
    }

    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $pendingCount = $script:PendingApprovals.Count
        $pendingLabel = if ($pendingCount -gt 0) { "👤 طلبات الوصول ($pendingCount)" } else { "👤 طلبات الوصول" }
        $rows += , @( (New-Button "⚙️ الإعدادات" "menu:settings"), (New-Button $pendingLabel "menu:pending") )
        $rows += , @( (New-Button "👥 إدارة المستخدمين" "menu:usersadmin") )
        $rows += , @( (New-Button "⚡ إدارة النصوص الجاهزة" "menu:presetsadmin") )
        $rows += , @( (New-Button "📚 القوالب والإعدادات" "menu:templatesadmin") )

        if (Get-Setting 'EnableLiveRelay') {
            $relayRunning = [bool](Get-RunningRelayProcess)
            $relayLabel = if ($relayRunning) { "⏹ إيقاف البث" } else { "▶️ بدء البث" }
            $relayData = if ($relayRunning) { "menu:stream:stop" } else { "menu:stream:start" }
            $rows += , @( (New-Button $relayLabel $relayData), (New-Button "🔗 رابط البث" "menu:stream:seturl") )
        }

        $adminRow = @( (New-Button "📜 السجل" "menu:audit"), (New-Button "🧪 التشخيص" "menu:diagnostics") )
        if (Get-Setting 'EnableRawCommand') { $adminRow += (New-Button "🛠 أمر خام" "menu:rawcmd") }
        $rows += , $adminRow
    }
    return @{ inline_keyboard = $rows }
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
        $categoryLabel = if ([string]::IsNullOrWhiteSpace([string]$t.Category)) { '' } else { " · $($t.Category)" }
        $templateRow = @((New-Button "$($t.Key) (طبقة $($t.Layer))$categoryLabel$(Get-TemplateLastUsedLabel -Key ([string]$t.Key))" "$Prefix`:$i"))
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
    return "ℹ️ $($Template.Key)`nالتصنيف: $category`nالطبقة: $($Template.Layer)`nالوصف: $description`nالحقول: $fields`nآخر استخدام: $lastUsed"
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
    $rows = @()
    foreach ($user in @(Get-AuthorizedUsers)) {
        $role = if ($user.Role -eq 'admin') { 'مشرف' } else { 'مشغّل' }
        $state = if ($user.Disabled) { '⛔ معطّل' } else { '✅ نشط' }
        $rows += , @((New-Button "$state · $($user.Alias) · $role" "usr:toggle:$($user.UserId)"))
        $rows += , @((New-Button "✏️ Alias · $($user.Alias)" "usr:alias:$($user.UserId)"))
        $lastActivity = if ($user.LastActivityAt) { ([datetime]$user.LastActivityAt).ToString('MM-dd HH:mm') } else { 'غير معروف' }
        $rows += , @((New-Button "🕒 آخر نشاط: $lastActivity" "usr:revoke:$($user.UserId)"))
        $rows += , @((New-Button "🗑 سحب صلاحية $($user.Alias)" "usr:revoke:$($user.UserId)"))
    }
    $rows += , @((New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Show-UsersAdminScreen {
    param([Parameter(Mandatory)][long]$ChatId)
    Send-TelegramMessage -ChatId $ChatId -Text "👥 المستخدمون المصرح لهم`nاضغط المستخدم لتعطيله أو إعادة تفعيله، واستخدم ✏️ Alias لتعديل اسمه التشغيلي، أو زر السحب مع التأكيد." -ReplyMarkup (Get-UsersAdminKeyboard)
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
    $action = if ($alias) { "تعيين Alias '$alias'" } else { 'حذف Alias' }
    Write-BridgeLog "Admin $AdminUserId updated alias for user ${target}: $action"
    Add-AuditEntry "👤 $action للمستخدم $target - by $(Get-UserDisplayName -UserId $AdminUserId)"
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
            , @( (New-Button "🗑 حذف" "pad:$TemplateIndex`:$PresetIndex"), (New-Button "⬅️ رجوع" "padm:$TemplateIndex") )
        ) }
}

function Get-PresetReviewKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "✅ حفظ التغيير" 'presetadmin:confirm'), (New-Button "❌ إلغاء" 'cancel') )
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
    $rows += , @((New-Button "✅ تأكيد الجدولة" 'schedule:confirm'), (New-Button "❌ إلغاء" 'cancel'))
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
            $button = New-Button "🙈 إخفاء $(Get-LayerDisplayName -Layer $layer)" "hide:$layer"
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
    $first = @( (New-Button "🙈 إخفاء هذا (طبقة $Layer)" "hide:$Layer"), (New-Button "🚪 خروج" "exit:$Layer") )
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
        , @((New-Button '✅ تأكيد التراجع' "rollbackconfirm:$Layer"), (New-Button '❌ إلغاء' 'menu'))
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
    $row = @( (New-Button "✅ تأكيد الإرسال" "show:confirm") )
    if ($HasFields) { $row += (New-Button "✏️ تعديل" "show:edit") }
    return @{ inline_keyboard = @( , $row; , @( (New-Button "❌ إلغاء" "cancel") ) ) }
}

function Get-HideAllConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "🚨 نعم، إخفاء الكل" "hideall:confirm"), (New-Button "❌ إلغاء" "cancel") )
        ) }
}

function Get-ApprovalKeyboard {
    param([Parameter(Mandatory)][long]$TargetChatId)
    return @{ inline_keyboard = @( , @( (New-Button "✅ موافقة" "approve:$TargetChatId"), (New-Button "❌ رفض" "reject:$TargetChatId") ) ) }
}

function Get-PendingKeyboard {
    $rows = @()
    foreach ($id in @($script:PendingApprovals.Keys)) {
        $info = $script:PendingApprovals[$id]
        $label = if ($info.Name) { "$($info.Name)" } else { "$id" }
        $rows += , @( (New-Button "✅ $label" "approve:$id"), (New-Button "❌" "reject:$id") )
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button "لا توجد طلبات معلّقة حاليًا" "menu") ) }
    else { $rows += , @( (New-Button "⬅️ رجوع" "menu") ) }
    return @{ inline_keyboard = $rows }
}

function Get-SettingsKeyboard {
    <# One row per setting. Booleans toggle in place (cfg:t:), numbers open a
       "send me a value" prompt (cfg:v:). Setting names are ASCII and short, so
       they stay well inside the 64-byte callback_data budget. #>
    $rows = @()
    foreach ($name in $script:DefaultSettings.Keys) {
        if ($name -in @('HideAllLayers', 'LayerNames')) { continue }
        $value = Get-Setting $name
        if ($script:DefaultSettings[$name] -is [bool]) {
            $mark = if ($value) { "✅" } else { "❌" }
            $lock = if ($script:ProtectedSettings -contains $name) { "🔒 " } else { "" }
            $rows += , @( (New-Button "$mark $lock$name" "cfg:t:$name") )
        }
        elseif ($script:DefaultSettings[$name] -is [string]) {
            $label = if ($name -eq 'NewsFilePath') { "📰 ملف الأخبار = $value" } else { "🔤 $name = $value" }
            $rows += , @( (New-Button $label "cfg:s:$name") )
        }
        else {
            $rows += , @( (New-Button "🔢 $name = $(Format-SettingDisplay -Name $name -Value $value)" "cfg:v:$name") )
        }
    }
    $scope = [string](Get-Setting 'HideAllLayers')
    $scopeLabel = if ($scope.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { 'كل الطبقات المعروفة' } elseif ($scope.Trim()) { "طبقات: $scope" } else { 'لا توجد طبقات محددة' }
    $rows += , @( (New-Button "🚨 طبقات إخفاء الكل: $scopeLabel" 'menu:hideallsettings') )
    $rows += , @( (New-Button '🏷️ أسماء الطبقات' 'menu:layernames') )
    $rows += , @( (New-Button "🗄 نسخ الإعدادات" "menu:backups"), (New-Button "♻️ استعادة الافتراضي" "cfg:reset") )
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminCatalogueKeyboard {
    $store = Get-TemplateStore
    $rows = @()
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $template = $store.Map[$store.Order[$i]]
        $rows += , @( (New-Button "$($template.Key) (طبقة $($template.Layer))" "tadm:$i") )
    }
    $transferRow = @((New-Button '📤 تصدير JSON' 'timport:export'))
    if (Get-Setting 'EnableFullTemplateManagement') { $transferRow += (New-Button '📥 استيراد JSON' 'timport:start') }
    $rows += , $transferRow
    if (Get-Setting 'EnableFullTemplateManagement') {
        $rows += , @( (New-Button '➕ إضافة قالب' 'tadm:create') )
        $rows += , @( (New-Button '📄 إضافة عبر JSON' 'tadm:createjson') )
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button 'لا توجد قوالب صالحة' 'menu') ) }
    $rows += , @( (New-Button '⬅️ القائمة' 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminDetailKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $rows = @()
    if (Get-Setting 'EnableFullTemplateManagement') {
        $rows += , @( (New-Button '✏️ تعديل التعريف' "tadm:edit:$TemplateIndex"), (New-Button '🗑 حذف القالب' "tadm:delete:$TemplateIndex") )
        if ((Get-SettingInt 'TemplateTestLayer' 0) -gt 0) { $rows += , @((New-Button '🧪 اختبار على طبقة التجربة' "tadm:test:$TemplateIndex")) }
    }
    $rows += , @( (New-Button '⬅️ القوالب' 'menu:templatesadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateDefinitionReviewKeyboard {
    return @{ inline_keyboard = @(
        , @( (New-Button '✅ حفظ التغيير' 'tadm:confirm'), (New-Button '❌ إلغاء' 'menu:templatesadmin') )
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
            , @( (New-Button '🗑️ مسح الاسم' "layername:clear:$Layer") )
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
            , @( (New-Button "⚠️ نعم، استعادة النسخة" 'cfg:restoreconfirm'), (New-Button "❌ إلغاء" 'menu:backups') )
        ) }
}

function Get-SettingConfirmKeyboard {
    param([Parameter(Mandatory)][string]$Name)
    return @{ inline_keyboard = @( , @( (New-Button "⚠️ نعم، عطّل الحماية" "cfgc:$Name"), (New-Button "❌ إلغاء" "menu:settings") ) ) }
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
    param([int]$Seconds)
    if ($Seconds -ge 60 -and $Seconds % 60 -eq 0) { return "$([int]($Seconds / 60)) د" }
    if ($Seconds -ge 60) { return "$([int]($Seconds / 60)) د $($Seconds % 60) ث" }
    return "$Seconds ث"
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
    Add-AuditEntry "⚙️ $($state.Name) = $trimmed - user $($state.UserId)"
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
    Set-Setting -Name $Name -Value $choices[$Index]
    Write-BridgeLog "User $UserId set $Name = $($choices[$Index])"
    Add-AuditEntry "⚙️ $Name = $($choices[$Index]) - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $Name = $($choices[$Index])$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}

