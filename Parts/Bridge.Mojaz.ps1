#requires -Version 7
<#
    Bridge.Mojaz.ps1 - the Mojaz playlist.

    The Mojaz scene is one graphic that stays on air and changes its contents:
    it animates in over its first 30 frames, loops between frames 30 and 285,
    and animates out on EXIT. So a bulletin of several stories is ONE show
    followed by a value update per story - not a show per story, which would
    replay the entrance animation and flash the screen between them.

    That shape is the whole reason this screen exists rather than the ordinary
    template flow: the operator writes a table of rows (image, title, text),
    says how long each row stays, and presses play. The first row gets extra
    time because the entrance animation is playing over it, and the last row
    is taken off with EXIT after half the dwell so the outro is not clipped.
#>

# The scene's own variable names, from mojaz.cintitle. Hard-coded on purpose:
# this screen is that template's, and a rename there is a change here.
$script:MojazImageVariable = 'mojaz_img'
$script:MojazTitleVariable = 'title.Text'
$script:MojazTextVariable = 'Subject.Text'

function Get-MojazTemplate {
    <# The registry entry, or $null when this bridge has no Mojaz template -
       which is how the menu knows not to offer the screen at all. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazTemplateKey)) { return $null }
    return $store.Map[$script:MojazTemplateKey]
}

function Test-MojazAvailable {
    return $null -ne (Get-MojazTemplate)
}

function Get-MojazStateFile {
    return (Join-Path $logDir 'mojaz.json')
}

function Get-MojazUploadDirectory {
    <# Beside the scene, not in the bridge's own upload folder: Cinegy reads
       the file off disk when the graphic goes up, and the bridge's uploads are
       swept on a timer - which would delete a picture that is still on air. #>
    $template = Get-MojazTemplate
    if (-not $template) { return '' }
    $root = Split-Path -Parent ([string]$template.Path)
    if ([string]::IsNullOrWhiteSpace($root)) { return '' }
    return (Join-Path (Join-Path $root 'Mojaz') 'bot')
}

function Import-MojazPlaylist {
    <# Reads the saved table. A missing or unreadable file is an empty table,
       never an error: the screen must open. #>
    $path = Get-MojazStateFile
    $script:MojazRows = @()
    $script:MojazDelaySeconds = Get-SettingInt 'MojazRowSeconds' 1
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $delay = 0
        if ([int]::TryParse([string](Get-JsonProp $saved 'DelaySeconds'), [ref]$delay) -and $delay -ge 1) {
            $script:MojazDelaySeconds = $delay
        }
        $script:MojazRows = @(foreach ($row in @(Get-JsonProp $saved 'Rows')) {
                if (-not $row) { continue }
                @{
                    Image = [string](Get-JsonProp $row 'Image')
                    Title = [string](Get-JsonProp $row 'Title')
                    Text  = [string](Get-JsonProp $row 'Text')
                }
            })
    }
    catch { Write-BridgeLog "Could not read mojaz.json: $($_.Exception.Message)" 'WARN' }
}

function Save-MojazPlaylist {
    <# Atomic, like every other state file here: a half-written table read at
       the next start would lose the whole bulletin. #>
    $path = Get-MojazStateFile
    try {
        $payload = @{ DelaySeconds = $script:MojazDelaySeconds; Rows = @($script:MojazRows) }
        $temporary = "$path.tmp"
        $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write mojaz.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Get-MojazRows { return @($script:MojazRows) }

function Add-MojazRow {
    param([string]$Image = '', [string]$Title = '', [string]$Text = '')
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($script:MojazRows)) { $rows.Add($row) }
    $rows.Add(@{ Image = $Image; Title = $Title; Text = $Text })
    $script:MojazRows = $rows.ToArray()
    return (Save-MojazPlaylist)
}

function Remove-MojazRow {
    param([Parameter(Mandatory)][int]$Index)
    $rows = @($script:MojazRows)
    if ($Index -lt 0 -or $Index -ge $rows.Count) { return $false }
    # Rebuilt by position, not by value: two identical rows are legitimate and
    # a value match would drop both.
    $kept = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rows.Count; $i++) { if ($i -ne $Index) { $kept.Add($rows[$i]) } }
    $script:MojazRows = $kept.ToArray()
    return (Save-MojazPlaylist)
}

function Clear-MojazRows {
    $script:MojazRows = @()
    return (Save-MojazPlaylist)
}

function Set-MojazDelaySeconds {
    param([Parameter(Mandatory)][int]$Seconds)
    if ($Seconds -lt 1 -or $Seconds -gt 600) { return $false }
    $script:MojazDelaySeconds = $Seconds
    return (Save-MojazPlaylist)
}

function Get-MojazRowVariables {
    <# One row as the scene's variables. A row without a picture omits the
       image variable entirely rather than sending an empty path, so the
       graphic keeps the picture it already has instead of blanking. #>
    param([Parameter(Mandatory)]$Row)
    $values = @{
        $script:MojazTitleVariable = [string]$Row.Title
        $script:MojazTextVariable  = [string]$Row.Text
    }
    $image = [string]$Row.Image
    if (-not [string]::IsNullOrWhiteSpace($image)) { $values[$script:MojazImageVariable] = $image }
    return $values
}

function Format-MojazCell {
    param([string]$Text, [int]$Limit = 40)
    $value = ([string]$Text -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return '—' }
    if ($value.Length -gt $Limit) { return $value.Substring(0, $Limit - 1) + '…' }
    return $value
}

function Get-MojazPlanText {
    <# How long the bulletin runs, in the same words the screen used to ask
       for the dwell. #>
    $rows = @(Get-MojazRows)
    if ($rows.Count -eq 0) { return '' }
    $delay = [int]$script:MojazDelaySeconds
    $intro = Get-SettingInt 'MojazIntroExtraSeconds' 0
    $half = [math]::Max(1, [int][math]::Floor($delay / 2))
    $total = ($delay * [math]::Max(0, $rows.Count - 1)) + $delay + $intro + $half
    return "كل صف $delay ث · الأول +$intro ث لحركة الدخول · الأخير يخرج بعد $half ث · الإجمالي ≈ $(Format-DurationSeconds -Seconds $total)"
}

function Get-MojazBlocks {
    <# The table the operator asked for: a row per story, four columns, with
       the copy itself trimmed to fit beside them. #>
    $rows = @(Get-MojazRows)
    $blocks = @(@{ type = 'heading'; text = '📑 الموجز'; size = 3 })
    if ($rows.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'الجدول فارغ. أضف صفًّا: صورة، عنوان، خبر.' }
        return $blocks
    }
    $blocks += @{ type = 'paragraph'; text = "$($rows.Count) صفًّا · $(Get-MojazPlanText)" }
    $cells = @(, @(
            @{ text = '#'; is_header = $true }
            @{ text = '🖼'; is_header = $true }
            @{ text = 'العنوان'; is_header = $true }
            @{ text = 'الخبر'; is_header = $true }
        ))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $cells += , @(
            @{ text = [string]($i + 1) }
            @{ text = $(if ([string]::IsNullOrWhiteSpace([string]$rows[$i].Image)) { '—' } else { '✅' }) }
            @{ text = (Format-MojazCell -Text ([string]$rows[$i].Title) -Limit 24) }
            @{ text = (Format-MojazCell -Text ([string]$rows[$i].Text) -Limit 60) }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    if ($script:MojazPlayback) {
        $blocks += @{ type = 'paragraph'; text = "▶️ يعمل الآن: الصف $([int]$script:MojazPlayback.Index + 1) من $($rows.Count)" }
    }
    return $blocks
}

function Get-MojazText {
    <# The same table as text, for a Telegram that refuses rich blocks. #>
    $rows = @(Get-MojazRows)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<b>📑 الموجز</b>')
    if ($rows.Count -eq 0) {
        $lines.Add('<i>الجدول فارغ. أضف صفًّا: صورة، عنوان، خبر.</i>')
        return ($lines -join "`n")
    }
    $lines.Add("<i>$($rows.Count) صفًّا · $(ConvertTo-TelegramHtmlText -Text (Get-MojazPlanText))</i>")
    $lines.Add('')
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $picture = if ([string]::IsNullOrWhiteSpace([string]$rows[$i].Image)) { '— بلا صورة' } else { '🖼 صورة' }
        $lines.Add("$($i + 1). <b>$(ConvertTo-TelegramHtmlText -Text (Format-MojazCell -Text ([string]$rows[$i].Title) -Limit 40))</b> · $picture")
        $lines.Add("   $(ConvertTo-TelegramHtmlText -Text (Format-MojazCell -Text ([string]$rows[$i].Text) -Limit 90))")
    }
    if ($script:MojazPlayback) {
        $lines.Add('')
        $lines.Add("▶️ يعمل الآن: الصف $([int]$script:MojazPlayback.Index + 1) من $($rows.Count)")
    }
    return ($lines -join "`n")
}

function Get-MojazKeyboard {
    $rows = @(Get-MojazRows)
    $keyboard = @()
    if ($script:MojazPlayback) {
        $keyboard += , @((New-Button '⏹ إيقاف وخروج' 'mojaz:stop' -Style danger))
    }
    elseif ($rows.Count -gt 0) {
        $keyboard += , @((New-Button "▶️ تشغيل ($($rows.Count) صفًّا)" 'mojaz:play' -Style success))
    }
    $keyboard += , @((New-Button '➕ إضافة صف' 'mojaz:add'), (New-Button "⏱ المدة: $([int]$script:MojazDelaySeconds) ث" 'mojaz:delay'))
    # One delete button per row, numbered like the table above it.
    $deleteRow = @()
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $deleteRow += (New-Button "🗑 $($i + 1)" "mojaz:del:$i" -Style danger)
        if ($deleteRow.Count -eq 5) { $keyboard += , $deleteRow; $deleteRow = @() }
    }
    if ($deleteRow.Count -gt 0) { $keyboard += , $deleteRow }
    if ($rows.Count -gt 0) { $keyboard += , @((New-Button '🧹 مسح الجدول' 'mojaz:clear' -Style danger)) }
    $keyboard += , @((New-Button '🔄 تحديث' 'mojaz:refresh'), (New-Button '🏠 القائمة' 'menu:main'))
    return @{ inline_keyboard = $keyboard }
}

function Show-MojazScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-MojazAvailable)) {
        Send-TelegramMessage -ChatId $ChatId -Text "قالب '$($script:MojazTemplateKey)' غير موجود في سجل القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $keyboard = Get-MojazKeyboard
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-MojazBlocks) -ReplyMarkup $keyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazText) -ParseMode HTML -ReplyMarkup $keyboard
}

function Start-MojazRowAdd {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_row_image'; UserId = $UserId; Image = ''; Title = '' }
    Send-TelegramMessage -ChatId $ChatId -Text "🖼 أرسل صورة الصف (كصورة أو كملف)، أو أرسل مسارًا مثل ‎.\Mojaz\Pic01.png‎`nأو اضغط ⏭ تخطٍّ لإبقاء صورة القالب." `
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '⏭ تخطٍّ' 'mojaz:skipimage'), (New-Button '❌ إلغاء' 'mojaz:refresh'))) }
}

function Complete-MojazRowImage {
    <# The typed-path branch. A picture sent as a photo arrives in
       Receive-MojazPhoto instead and lands here with a path already on disk. #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '', [switch]$Skip)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_row_image') { return }
    $image = if ($Skip) { '' } else { ([string]$Value).Trim() }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_row_title'; UserId = $state.UserId; Image = $image; Title = '' }
    Send-TelegramMessage -ChatId $ChatId -Text '📝 أرسل عنوان الصف (مثل: قطاع غزة).' -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazRowTitle {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_row_title') { return }
    $title = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($title)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ العنوان فارغ. أرسل عنوانًا.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_row_text'; UserId = $state.UserId; Image = [string]$state.Image; Title = $title }
    Send-TelegramMessage -ChatId $ChatId -Text '📰 أرسل نص الخبر.' -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazRowText {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_row_text') { return }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ نص الخبر فارغ. أرسل النص.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $userId = [long]$state.UserId
    Clear-PendingState -ChatId $ChatId
    Add-MojazRow -Image ([string]$state.Image) -Title ([string]$state.Title) -Text $text | Out-Null
    Add-AuditEntry "📑 أُضيف صف للموجز - بواسطة $(Format-UserAuditActor -UserId $userId)"
    Show-MojazScreen -ChatId $ChatId -UserId $userId
}

function Receive-MojazPhoto {
    <#
        A picture sent from the phone, saved beside the scene so Cinegy can
        read it, and handed to the row as the relative path the template's own
        pictures already use.
    #>
    param([Parameter(Mandatory)][string]$FileId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Extension = '.jpg')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $directory = Get-MojazUploadDirectory
    if (-not $directory) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ لا يمكن تحديد مجلد الصور: القالب غير موجود.' -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    $safeExtension = if ($Extension -match '^\.[A-Za-z0-9]{1,5}$') { $Extension.ToLowerInvariant() } else { '.jpg' }
    $name = "mojaz-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))$safeExtension"
    $destination = Join-Path $directory $name
    try {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        Receive-TelegramDocument -FileId $FileId -DestinationPath $destination -MaximumBytes (10 * 1024 * 1024) | Out-Null
    }
    catch {
        Write-BridgeLog "Mojaz photo download failed: $($_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ الصورة: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    # Relative to the scene's root folder, the way the template's own picture
    # paths are written - an absolute path would break if the project moves.
    Complete-MojazRowImage -ChatId $ChatId -Value ".\Mojaz\bot\$name"
    return $true
}

function Start-MojazDelayPrompt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_delay'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "⏱ كم ثانية يبقى كل صف على الهواء؟ (1-600)`nالحالي: $([int]$script:MojazDelaySeconds) ث" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazDelay {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_delay') { return }
    $seconds = 0
    if (-not [int]::TryParse((ConvertTo-BridgeLatinDigits -Text ([string]$Value).Trim()), [ref]$seconds) -or -not (Set-MojazDelaySeconds -Seconds $seconds)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ أرسل رقمًا بين 1 و600.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $userId = [long]$state.UserId
    Clear-PendingState -ChatId $ChatId
    Show-MojazScreen -ChatId $ChatId -UserId $userId
}

function Start-MojazPlayback {
    <#
        Shows the first row, then leaves the rest to the tick.

        The show goes through the ordinary pipeline so this screen cannot skip
        maintenance mode, the layer policy, the live Cinegy check or the audit
        trail - a bulletin is still a graphic going on air.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @(Get-MojazRows)
    if ($rows.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الجدول فارغ.' -ReplyMarkup (Get-MojazKeyboard)
        return $false
    }
    if ($script:MojazPlayback) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز يعمل بالفعل.' -ReplyMarkup (Get-MojazKeyboard)
        return $false
    }
    $result = Invoke-ShowTemplateResult -Key $script:MojazTemplateKey -Variables (Get-MojazRowVariables -Row $rows[0]) -ChatId $ChatId -UserId $UserId
    if (-not $result -or -not $result.Success) {
        $reason = if ($result) { [string](Get-JsonProp $result 'Error') } else { 'تعذّر العرض' }
        Send-TelegramMessage -ChatId $ChatId -Text "❌ لم يبدأ الموجز: $reason" -ReplyMarkup (Get-MojazKeyboard)
        return $false
    }
    $delay = [int]$script:MojazDelaySeconds
    # The first row carries the entrance animation, so it stays for the dwell
    # plus that animation - otherwise its text is replaced while the graphic is
    # still sliding in.
    $extra = Get-SettingInt 'MojazIntroExtraSeconds' 0
    $script:MojazPlayback = @{
        Index = 0; ChatId = $ChatId; UserId = $UserId
        NextAt = (Get-Date).AddSeconds($delay + $extra)
        Rows = $rows.Count
    }
    Write-BridgeLog "Mojaz playback started by $UserId ($($rows.Count) rows, $delay s each)"
    Add-AuditEntry "📑 تشغيل الموجز ($($rows.Count) صفًّا) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Stop-MojazPlayback {
    <# Ends the bulletin the way it ends itself: EXIT, so the scene plays its
       outro instead of being cut. #>
    param([long]$ChatId = 0, [long]$UserId = 0, [switch]$Quiet)
    if (-not $script:MojazPlayback) { return $false }
    $playback = $script:MojazPlayback
    $script:MojazPlayback = $null
    $template = Get-MojazTemplate
    if ($template) {
        $chat = if ($ChatId -gt 0) { $ChatId } else { [long]$playback.ChatId }
        $user = if ($UserId -gt 0) { $UserId } else { [long]$playback.UserId }
        Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $chat -UserId $user | Out-Null
    }
    if (-not $Quiet -and $ChatId -gt 0) { Show-MojazScreen -ChatId $ChatId -UserId $UserId }
    return $true
}

function Update-MojazPlayback {
    <#
        One step of the bulletin, called from the tick.

        Rows after the first are pushed through the postbox, which is what
        changes a running scene's values without restarting it. The last row is
        followed by EXIT after half the dwell, so the outro has time to run.
    #>
    if (-not $script:MojazPlayback) { return }
    if ((Get-Date) -lt [datetime]$script:MojazPlayback.NextAt) { return }
    $rows = @(Get-MojazRows)
    $index = [int]$script:MojazPlayback.Index
    if ($index -ge ($rows.Count - 1)) {
        Write-BridgeLog "Mojaz playback finished after $($rows.Count) row(s)"
        Stop-MojazPlayback -Quiet | Out-Null
        return
    }
    $index++
    $values = Get-MojazRowVariables -Row $rows[$index]
    $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Values $values -TimeoutSec (Get-AirTimeout)
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Mojaz POSTBOX XML: $($result.Xml)" }
    if (-not $result.Success) {
        Write-BridgeLog "Mojaz row $($index + 1) failed: $($result.Error)" 'WARN'
        Send-TelegramMessage -ChatId ([long]$script:MojazPlayback.ChatId) -Text "❌ توقّف الموجز عند الصف $($index + 1): $($result.Error)"
        Stop-MojazPlayback -Quiet | Out-Null
        return
    }
    $delay = [int]$script:MojazDelaySeconds
    # Half the dwell on the last row: the EXIT that follows plays the outro,
    # and a full dwell before it would leave the last story sitting there.
    $wait = if ($index -ge ($rows.Count - 1)) { [math]::Max(1, [int][math]::Floor($delay / 2)) } else { $delay }
    $script:MojazPlayback.Index = $index
    $script:MojazPlayback.NextAt = (Get-Date).AddSeconds($wait)
}
