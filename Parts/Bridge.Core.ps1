#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-CallbackArg {
    <# Strips a callback_data prefix and returns the payload that follows it.

       Replaces hand-written $data.Substring(N), where N had to equal the
       prefix length exactly and getting it wrong failed silently: the
       'news:idown:' branch read from offset 10 instead of 11, shipped, and
       broke news item reordering. Passing the prefix itself makes that whole
       class of off-by-N bug unrepresentable, and a renamed prefix now throws
       here instead of quietly slicing the wrong characters.

       The payload is returned verbatim, so values that themselves contain ':'
       survive exactly as Substring used to leave them. #>
    param(
        [Parameter(Mandatory)][string]$Data,
        [Parameter(Mandatory)][string]$Prefix
    )
    if (-not $Data.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "Callback '$Data' does not start with the expected prefix '$Prefix'."
    }
    return $Data.Substring($Prefix.Length)
}

function Get-JsonProp {
    <# Safely reads a possibly-absent property from a ConvertFrom-Json object
       without tripping Set-StrictMode's property-not-found error. Telegram and
       hand-edited JSON both omit optional fields entirely rather than sending
       them as null, so every read of external JSON goes through here. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

function Save-Config {
    <# Persists config changes (approved users, settings, stream URL) back to
       disk. Re-reads the file first and only overwrites the blocks this bot
       manages, so a manual edit made while the bridge is running is not
       clobbered by the next approval - and the in-memory copy picks that
       manual edit up at the same time. #>
    param([string]$Path = $ConfigPath)
    if ($LoadOnly -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($ConfigPath) -and
        [IO.Path]::GetFileName($Path) -eq 'config.example.json') {
        $script:LastConfigSaveFailed = $false
        return
    }
    $configMutex = [Threading.Mutex]::new($false, 'Global\CinegyTelegramBridge.Config')
    $configLockHeld = $false
    try { $configLockHeld = $configMutex.WaitOne([timespan]::FromSeconds(10)) }
    catch [Threading.AbandonedMutexException] { $configLockHeld = $true }
    if (-not $configLockHeld) {
        $script:LastConfigSaveFailed = $true
        $configMutex.Dispose()
        Write-BridgeLog "Timed out waiting for the config write lock. Change applies to this session only." "ERROR"
        return
    }
    $managed = @('AllowedChatIds', 'AdminChatIds', 'AllowedUserIds', 'AdminUserIds', 'Settings', 'LiveStream')
    $target = $null
    try { $target = Get-Content -Path $Path -Raw | ConvertFrom-Json }
    catch {
        # Write-BridgeLog, not Write-Host: this branch overwrites the file on
        # disk with the in-memory copy, discarding anything hand-edited there
        # - including keys the bridge does not manage. It was the one step in
        # this function that left no trace in bridge.log, so the loss was
        # silent and unattributable afterwards.
        $script:LastConfigSaveFailed = $true
        Write-BridgeLog "Could not re-read $Path before saving ($($_.Exception.Message)); writing the in-memory copy. Any edit made to the file by hand since startup is lost." 'ERROR'
    }

    if ($target) {
        foreach ($name in $managed) {
            if ($config.PSObject.Properties.Match($name).Count -gt 0) {
                $target | Add-Member -NotePropertyName $name -NotePropertyValue $config.$name -Force
            }
        }
        # Adopt any unmanaged keys the operator edited on disk into memory.
        foreach ($prop in $target.PSObject.Properties) {
            if ($managed -notcontains $prop.Name) {
                $config | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            }
        }
    }
    else {
        $target = $config
    }
    # A locked config.json (open in an editor, AV scan, roaming profile) must
    # not take down whatever action triggered the save - the in-memory change
    # still applies for this run, so report and continue. The outcome is
    # recorded in a flag rather than returned, because a return value here
    # would leak a stray boolean into the output of every caller.
    # Written atomically via a temp file + Move-Item. A direct Set-Content that
    # is interrupted (power loss, crash) leaves a truncated config.json, and
    # since it holds the bot token and the operator whitelist the bridge would
    # then refuse to start at all. A .bak copy is kept as a second net.
    $tempPath = "$Path.tmp"
    $backupPath = "$Path.bak"
    try {
        if (Test-Path -LiteralPath $Path) {
            $versionedBackupDirectory = "$Path.backups"
            New-Item -ItemType Directory -Path $versionedBackupDirectory -Force -ErrorAction Stop | Out-Null
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            $versionedBackup = Join-Path $versionedBackupDirectory "config-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
            Copy-Item -LiteralPath $Path -Destination $versionedBackup -ErrorAction Stop
            $keep = Get-SettingInt 'ConfigBackupKeepFiles' 1
            $oldBackups = @(Get-ChildItem -LiteralPath $versionedBackupDirectory -Filter '*.json' |
                    Sort-Object LastWriteTimeUtc, Name -Descending | Select-Object -Skip $keep)
            foreach ($oldBackup in $oldBackups) { Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction SilentlyContinue }
        }
        $targetSettings = Get-JsonProp $target 'Settings'
        $dpapiEnabled = $targetSettings -and $targetSettings.PSObject.Properties.Match('EnableDpapiSecrets').Count -gt 0 -and [bool]$targetSettings.EnableDpapiSecrets
        if ($dpapiEnabled) {
            if ($script:SecretReferences.Count -eq 0) {
                $secrets = @{}
                foreach ($entry in @(
                        @{ Path = 'BotToken'; Name = 'BotToken'; Value = [string]$config.BotToken }
                        @{ Path = 'LiveStream.SourceUrl'; Name = 'LiveStream.SourceUrl'; Value = [string]$config.LiveStream.SourceUrl }
                        @{ Path = 'LiveStream.RtmpDestination'; Name = 'LiveStream.RtmpDestination'; Value = [string]$config.LiveStream.RtmpDestination }
                    )) {
                    if ([string]::IsNullOrWhiteSpace($entry.Value)) { continue }
                    $secrets[$entry.Name] = $entry.Value
                    $script:SecretReferences[$entry.Path] = "dpapi:$($entry.Name)"
                }
                Write-BridgeSecretStore -Path $script:SecretStorePath -Secrets $secrets
            }
            else { Update-BridgeReferencedSecrets -Config $config -References $script:SecretReferences -StorePath $script:SecretStorePath }
            $target = ConvertTo-BridgePersistableConfig -Config $target -References $script:SecretReferences
        }
        elseif ($script:SecretReferences.ContainsKey('BotToken')) {
            $target.BotToken = [string]$config.BotToken
        }
        $target | ConvertTo-Json -Depth 20 | Set-Content -Path $tempPath -Encoding utf8 -ErrorAction Stop
        if (Test-Path $Path) { Copy-Item -Path $Path -Destination $backupPath -Force -ErrorAction SilentlyContinue }
        Move-Item -Path $tempPath -Destination $Path -Force -ErrorAction Stop
        Protect-BridgeConfigurationAcl -ConfigPath $Path
        $script:LastConfigSaveFailed = $false
    }
    catch {
        $script:LastConfigSaveFailed = $true
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        Write-BridgeLog "Could not write $Path : $($_.Exception.Message). Change applies to this session only." "ERROR"
    }
    finally {
        if ($configLockHeld) { $configMutex.ReleaseMutex() }
        $configMutex.Dispose()
    }
}

function Restore-ConfigBackup {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$Path = $ConfigPath
    )
    $restoreTempPath = "$Path.restore.tmp"
    try {
        if (-not (Test-Path -LiteralPath $BackupPath)) { throw "ملف النسخة غير موجود." }
        $candidate = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $candidate 'BotToken'))) {
            throw "النسخة لا تحتوي BotToken صالحًا."
        }
        $backupDirectory = "$Path.backups"
        New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $Path) {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            $beforeRestore = Join-Path $backupDirectory "pre-restore-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
            Copy-Item -LiteralPath $Path -Destination $beforeRestore -ErrorAction Stop
        }
        Copy-Item -LiteralPath $BackupPath -Destination $restoreTempPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $restoreTempPath -Destination $Path -Force -ErrorAction Stop
        Protect-BridgeConfigurationAcl -ConfigPath $Path
        return [pscustomobject]@{ Success = $true; Error = '' }
    }
    catch {
        Remove-Item -LiteralPath $restoreTempPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Success = $false; Error = Protect-SensitiveText $_.Exception.Message }
    }
}

function Format-ConfigDiffValue {
    <#
        A configuration value, safe to put in a chat message.

        config.json is the one file the bridge holds that is genuinely secret
        - BotToken lives in it, and so does the sheet write token. A restore
        screen that printed old and new values would publish them to whoever
        is looking at that chat, which is why the settings export refuses to
        write them at all.

        So: anything whose name reads like a credential is shown as its
        length, never its content; a list is shown as a count, because the
        whitelist is a list of people; and everything else is shown, capped.
    #>
    param([string]$Name, $Value)
    if ($Name -match '(?i)token|secret|password|apikey') {
        $text = [string]$Value
        return $(if ($text) { "•••• ($($text.Length) حرفًا)" } else { '(فارغ)' })
    }
    if ($Value -is [array]) { return "$(@($Value).Count) عنصرًا" }
    if ($null -eq $Value) { return '(غير موجود)' }
    $text = ([string]$Value -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrEmpty($text)) { return '(فارغ)' }
    if ($text.Length -gt 40) { return $text.Substring(0, 39) + '…' }
    return $text
}

function Get-ConfigDifferenceRows {
    <#
        Which top-level settings a backup would change, and to what.

        The summary this replaces listed the names only - "الاختلافات:
        NewsFilePath، MaxFieldLength" - so an administrator about to overwrite
        the live configuration could see that something changed but not what
        it would become. That is the same shape as telling an editor three
        items will be replaced without saying which.
    #>
    param([Parameter(Mandatory)][string]$CurrentPath, [Parameter(Mandatory)][string]$BackupPath)
    try {
        $current = Get-Content -LiteralPath $CurrentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $backup = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $null }
    $names = @(@($current.PSObject.Properties.Name) + @($backup.PSObject.Properties.Name) | Sort-Object -Unique)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        # Read through the property directly rather than Get-JsonProp: a
        # one-element list comes back from a function unwrapped into the
        # element, and then a whitelist of one person reads as that person's
        # id instead of as a count.
        $currentProperty = $current.PSObject.Properties[$name]
        $backupProperty = $backup.PSObject.Properties[$name]
        $currentValue = $null
        $backupValue = $null
        if ($currentProperty) { $currentValue = $currentProperty.Value }
        if ($backupProperty) { $backupValue = $backupProperty.Value }
        if (($currentValue | ConvertTo-Json -Depth 20 -Compress) -eq ($backupValue | ConvertTo-Json -Depth 20 -Compress)) { continue }
        $rows.Add([pscustomobject]@{
                Name = $name
                Current = (Format-ConfigDiffValue -Name $name -Value $currentValue)
                Backup = (Format-ConfigDiffValue -Name $name -Value $backupValue)
            })
    }
    # Comma so an empty result stays an empty array: $null is how this
    # function says the JSON would not parse. Assign the call directly -
    # wrapping it in @() would nest the array inside another one.
    return , $rows.ToArray()
}

function Get-ConfigRestoreBlocks {
    <# The restore confirmation as what it would actually change. #>
    param([Parameter(Mandatory)][string]$CurrentPath, [Parameter(Mandatory)][string]$BackupPath, [Parameter(Mandatory)][string]$BackupName)
    $rows = Get-ConfigDifferenceRows -CurrentPath $CurrentPath -BackupPath $BackupPath
    if ($null -eq $rows) { return @() }
    $blocks = @(@{ type = 'heading'; text = "⚠️ استعادة النسخة $BackupName"; size = 3 })
    if ($rows.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لا اختلافات ظاهرة: الاستعادة لن تغيّر شيئًا.' }
        return $blocks
    }
    $blocks += @{ type = 'paragraph'; text = "$($rows.Count) إعدادًا سيتغيّر · تُحفظ الحالة الحالية أولًا" }
    $cells = @(, @(
            @{ text = 'الإعداد'; is_header = $true }
            @{ text = 'الحالي'; is_header = $true }
            @{ text = 'في النسخة'; is_header = $true }
        ))
    foreach ($row in $rows) {
        $cells += , @(@{ text = $row.Name }, @{ text = $row.Current }, @{ text = $row.Backup })
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    return $blocks
}

function Get-ConfigDifferenceSummary {
    param(
        [Parameter(Mandatory)][string]$CurrentPath,
        [Parameter(Mandatory)][string]$BackupPath
    )
    try {
        $current = Get-Content -LiteralPath $CurrentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $backup = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $names = @(@($current.PSObject.Properties.Name) + @($backup.PSObject.Properties.Name) | Sort-Object -Unique)
        $changed = foreach ($name in $names) {
            $currentValue = Get-JsonProp $current $name
            $backupValue = Get-JsonProp $backup $name
            $currentJson = $currentValue | ConvertTo-Json -Depth 20 -Compress
            $backupJson = $backupValue | ConvertTo-Json -Depth 20 -Compress
            if ($currentJson -ne $backupJson) { $name }
        }
        if (@($changed).Count -eq 0) { return 'الاختلافات: لا توجد اختلافات ظاهرة.' }
        return "الاختلافات: $(@($changed) -join '، ')"
    }
    catch { return "الاختلافات: تعذّر حسابها ($($_.Exception.Message))." }
}

function Get-ConfigSaveWarning {
    <# Appended to any confirmation whose change could not be persisted, so an
       operator is never told something was saved when it was not. #>
    if ($script:LastConfigSaveFailed) { return "`n⚠️ تعذّر حفظ config.json - التغيير مؤقّت حتى إعادة التشغيل." }
    return ''
}

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    return Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name
}

function Get-SettingInt {
    param([Parameter(Mandatory)][string]$Name, [int]$Minimum = 0)
    return Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum
}

function Get-LayerName {
    param([Parameter(Mandatory)][int]$Layer)
    foreach ($pair in @([string](Get-Setting 'LayerNames') -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        if ($parts.Count -lt 2) { continue }
        $number = 0
        if ([int]::TryParse($parts[0].Trim(), [ref]$number) -and $number -eq $Layer) {
            $name = $parts[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
            return ''
        }
    }
    return ''
}

function Get-LayerDisplayName {
    param([Parameter(Mandatory)][int]$Layer)
    $name = Get-LayerName -Layer $Layer
    if ([string]::IsNullOrWhiteSpace($name)) { return "طبقة $Layer" }
    return "$name · طبقة $Layer"
}

# How many rows a rich table may carry, whatever is being tabled.
#
# A month of banners once serialised to 45 KB of blocks. Telegram refused it,
# and being the first rich message of a session that refusal disabled heading,
# table, paragraph and details for every screen until the next restart. Forty
# rows keeps any table an order of magnitude below the limit.
$script:RichTableMaxRows = 40

# A small core of Arabic the newsroom writes every day: function words,
# dates, the verbs a wire story is built from, the institutions, the places
# this station covers. Not a dictionary - a full Arabic one is hundreds of
# thousands of surface forms because of the morphology, and shipping that into
# a broadcast bridge buys accuracy nobody asked for at a cost everybody pays.
#
# It exists to answer the cold-start problem: without it the check flagged
# الرئيس and اجتماع on a fresh install, which is noise wearing the costume of a
# warning. Paired with Remove-ArabicClitics below it covers the ordinary
# sentence and leaves the unusual word - which is the one worth a second look.
$script:ArabicCoreWordsSeed = @'
    أبريل أخبار أربعة أسبوع أسعار أسواق أشار أشارت أضاف أضافت أعلن أعلنت
    أغسطس أفاد أفادت أكتوبر أكد أكدت ألف ألمانيا أم أمريكا أمس أمسية
    أمطار أن أنا أنت أنتم أهداف أو أوضح أوضحت أولئك إحصائية إذ
    إذا إسبانيا إصابات إصابة إطلاق إغاثة إلى إن إيران إيطاليا اتفاق اتفاقية
    اثنان اجتماع ارتفع ارتفعت استثمار استمر استمرت اشتباك اشتباكات الآن الأحد الأحمر
    الأربعاء الأردن الأرض الأزمة الأمم الأمن الأمين الأوروبي الأوضاع الإثنين الإعلام الإمارات
    الاتحاد الاقتصاد البحرين البرلمان التطورات التعليم التقت التقى التي الثلاثاء الجامعة الجزائر
    الجمعة الجيش الحكومة الخارجية الخليل الخميس الداخلية الدفاع الذي الذين الرئاسة الرئيس
    الرسمي الزراعة السبت السعودية السفارة السفير السودان الشرطة الصحة الصليب الصومال الصين
    الضفة العام العراق العربية القدس القدم القوات القيادة الكويت اللاتي اللجنة الله
    المالية المتحدة المتحدث المجلس المدني المسؤول المسؤولون المستجدات المغرب الميدان النار الناطق
    الهلال الوزراء الوزير الوضع الوفد اليمن اليوم انتهت انتهى انخفض انخفضت بث
    بدأ بدأت بريطانيا بطولة بعد بعض بل بيان بين تجارة تركيا تسعة
    تصريح تصعيد تغطية تقرير تكون تلك تونس ثانية ثلاثة ثم ثمانية جامعة
    جرحى جريح جميع جنين جولة جيبوتي حتى حرارة حول حيث خانيونس خبر
    خسارة خطاب خلال خمسة دراسة درجة دعا دعت دقيقة دوري دولار دون
    ديسمبر ذكر ذكرت ذلك رام رسالة رفح رفض رفضت روسيا رياح زاد
    زادت زيارة ساعة سبتمبر سبعة ستة سجل سجلت سنة سوريا سوق سوى
    شهد شهداء شهدت شهر شهيد صباح ضحايا ضمن طالب طالبت طقس طولكرم
    عاجل عاصفة عام عدوان عشرة على عمان عملة عن عند غادر غادرت
    غارة غدا غزة غير فبراير فرنسا فريق فلسطين فوز في قال قالت
    قبل قتلى قد قرار قرارات قصف قطر قمة كان كانت كرة كشف
    كشفت كل كلمة لا لاجئ لاجئون لاعب لبنان لدى لقاء لقد لكن
    لم لن ليبيا ليس ليست ليل مؤتمر مئة مئوية ما مارس مايو
    مباحثات مباراة مباشر مجلس محادثات مخيم مدرب مدرسة مراسل مراسلنا مساء مساعدات
    مستشفى مشاريع مشروع مصر مع مفاوضات مفقود مفقودون مليار مليون من منتخب
    مندوب منذ منظمة موجز موريتانيا نابلس نازحون نتائج نحن نحو نزوح نشرة
    نهار نوفمبر هؤلاء هدف هدنة هذا هذه هم هن هنا هناك هو
    هي واحد وافق وافقت وصل وصلت وقف يكون يناير يوليو يوم يونيو
'@.Split([char[]]" `t`r`n", [StringSplitOptions]::RemoveEmptyEntries)

# Both forms of every ال- word. The list is written the way a newsroom writes
# it, and Remove-ArabicClitics strips ال off the text it is checking - so
# without the bare stem here, للحكومة reduces to حكومة and matches nothing.
$script:ArabicCoreWords = [System.Collections.Generic.HashSet[string]]::new()
foreach ($coreWord in $script:ArabicCoreWordsSeed) {
    [void]$script:ArabicCoreWords.Add($coreWord)
    if ($coreWord.Length -gt 4 -and $coreWord.StartsWith('ال')) { [void]$script:ArabicCoreWords.Add($coreWord.Substring(2)) }
}

function Remove-ArabicClitics {
    <#
        The word without what Arabic glues to it.

        A list of stems cannot match والرئيس or بالمستشفى or اجتماعهم, and
        stripping the handful of clitics that attach to almost everything
        turns one modest core list into a much larger effective one. Returns
        the candidates in order, longest strip last, so a caller stops at the
        first hit.
    #>
    param([Parameter(Mandatory)][string]$Word)
    $forms = [System.Collections.Generic.List[string]]::new()
    $forms.Add($Word)
    $prefixes = @('وال', 'فال', 'بال', 'كال', 'لل', 'ال', 'و', 'ف', 'ب', 'ك', 'ل', 'س')
    $suffixes = @('هما', 'هنّ', 'كما', 'هم', 'هن', 'ها', 'كم', 'كن', 'نا', 'ية', 'ه', 'ك', 'ي', 'ا', 'ت', 'ن')
    foreach ($prefix in $prefixes) {
        if ($Word.Length -gt ($prefix.Length + 2) -and $Word.StartsWith($prefix)) {
            $stem = $Word.Substring($prefix.Length)
            $forms.Add($stem)
            foreach ($suffix in $suffixes) {
                if ($stem.Length -gt ($suffix.Length + 2) -and $stem.EndsWith($suffix)) { $forms.Add($stem.Substring(0, $stem.Length - $suffix.Length)) }
            }
        }
    }
    foreach ($suffix in $suffixes) {
        if ($Word.Length -gt ($suffix.Length + 2) -and $Word.EndsWith($suffix)) { $forms.Add($Word.Substring(0, $Word.Length - $suffix.Length)) }
    }
    return @($forms | Select-Object -Unique)
}

function Test-BridgeWordKnown {
    <# Whether any stripped form of the word is one the station has written or
       the core list carries. #>
    param([Parameter(Mandatory)][string]$Word, [Parameter(Mandatory)]$Lexicon)
    foreach ($form in @(Remove-ArabicClitics -Word $Word)) {
        if ($Lexicon.Contains($form) -or $script:ArabicCoreWords.Contains($form)) { return $true }
    }
    return $false
}

function Get-BridgeStationLexicon {
    <#
        Every word this station has already put on air, near enough.

        Built from what the bridge already keeps - the values operators
        recently typed into template fields, and the ticker as it stands - so
        it needs no dictionary file, no download and no dependency. It is not
        an Arabic lexicon and does not pretend to be: it is a record of this
        newsroom's own vocabulary, which is the thing a proper-noun typo fails
        against.

        Cached for a minute. Rebuilding it per keystroke would read the ticker
        file on every field a person fills.
    #>
    param([switch]$Force)
    if ($null -ne $script:StationLexicon -and -not $Force -and ((Get-Date) - $script:StationLexiconAt).TotalSeconds -lt 60) {
        return , $script:StationLexicon
    }
    $words = [System.Collections.Generic.HashSet[string]]::new()
    $add = {
        param([string]$Text)
        foreach ($word in @([regex]::Split([string]$Text, '[^\p{L}\p{N}]+'))) {
            if ($word.Length -ge 3) { [void]$words.Add($word) }
        }
    }
    foreach ($key in @($script:RecentFieldValues.Keys)) {
        foreach ($value in @($script:RecentFieldValues[$key])) { & $add ([string]$value) }
    }
    try {
        $path = [string](Get-Setting 'NewsFilePath')
        if ($path -and (Test-Path -LiteralPath $path)) {
            & $add ((Get-Content -LiteralPath $path -Raw -ErrorAction Stop))
        }
    }
    catch {
        # The ticker is one of two sources and the other already loaded, so a
        # failure here narrows the lexicon rather than breaking the check. Said
        # once at debug level: this runs on every review screen, and an
        # unreadable ticker file would otherwise fill the log.
        Write-BridgeLog "Could not read the ticker for the station lexicon: $($_.Exception.Message)" 'DEBUG'
    }
    $script:StationLexicon = $words
    $script:StationLexiconAt = Get-Date
    # The comma is load-bearing. PowerShell enumerates a collection on return,
    # so a bare `return $words` hands back the strings one by one and the
    # caller receives Object[] - and an EMPTY set returns nothing at all,
    # which is how .Count threw on $null under Set-StrictMode.
    return , $words
}

function Get-BridgeLexiconOrEmpty {
    <# Never $null: a caller that reaches for .Count on nothing throws under
       Set-StrictMode, and this one is on the path to air. #>
    $lexicon = Get-BridgeStationLexicon
    if ($lexicon -is [System.Collections.Generic.HashSet[string]]) { return , $lexicon }
    return , ([System.Collections.Generic.HashSet[string]]::new())
}

function Get-BridgeTextWarnings {
    <#
        What looks wrong in a line about to go on air.

        Advisory, never blocking, and that is the whole design: a breaking
        headline held back over a proper noun no checker knows is worse than
        the typo it was guarding against. Everything here returns a sentence
        for the operator to judge, and the publish button stays live either
        way.

        Two levels, both local, because the text must not leave the network -
        an outside checking service means sending unbroadcast headlines to a
        third party.

        Level one needs no vocabulary at all: shapes that are almost always a
        slip on a phone keyboard. Level two asks whether this station has ever
        written the word before, which is what catches a mistyped name - the
        expensive kind, because a wrong name is wrong in a way a reader
        notices and a spell checker would have passed.
    #>
    param([AllowEmptyString()][string]$Text)
    $warnings = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $warnings }

    if ($Text -match '(\p{L})\1\1') { $warnings += "حرف مكرّر ثلاث مرات: «$($Matches[0])»" }
    if ($Text -match '  ') { $warnings += 'مسافتان متتاليتان' }
    # A comma or full stop with no space after it is the commonest phone slip
    # in Arabic, and it closes up two words into one on screen.
    if ($Text -match '[،,.؟!:](?=\p{L})') { $warnings += 'علامة ترقيم بلا مسافة بعدها' }
    if ($Text -match '\s[،,.؟!]') { $warnings += 'مسافة قبل علامة ترقيم' }
    # Latin digits inside Arabic reorder against the text around them.
    if ($Text -match '\p{IsArabic}' -and $Text -match '[0-9]') { $warnings += 'أرقام لاتينية داخل نصّ عربي' }
    if ($Text -ne $Text.Trim()) { $warnings += 'مسافة في أول النصّ أو آخره' }

    # A lexicon too small to know the language has no business judging a word.
    # Before this gate the check flagged الرئيس and اجتماع on a fresh install,
    # which is not a typo warning - it is noise wearing one, and it would have
    # taught operators to skip the whole section within a shift.
    # The two lists do different jobs, and conflating them is what made the
    # first build noisy. The core list SUPPRESSES: it stops ordinary Arabic
    # being reported. The station's own words QUALIFY: only when the newsroom
    # has written enough for its vocabulary to mean something does "you have
    # never written this word" carry information.
    #
    # So the gate counts the station's words alone. On a fresh install this
    # level stays silent and the shape checks above do the work - they are
    # precise and need no vocabulary at all. It wakes up on its own once the
    # bridge has seen a few hundred real headlines, which is the point at
    # which an unfamiliar word is genuinely unusual rather than merely
    # missing from a list I wrote by hand.
    $lexicon = Get-BridgeLexiconOrEmpty
    if ($lexicon.Count -lt $script:StationLexiconMinimum) { return $warnings }

    $unseen = @()
    foreach ($word in @([regex]::Split($Text, '[^\p{L}\p{N}]+'))) {
        if ($word.Length -lt 4) { continue }
        if ($word -match '^\p{N}+$') { continue }
        if (-not (Test-BridgeWordKnown -Word $word -Lexicon $lexicon)) { $unseen += $word }
    }
    # Two at most. A genuinely new story is full of new words, and a warning
    # naming twenty of them is a wall; naming one or two is a question.
    $unseen = @($unseen | Select-Object -Unique)
    if ($unseen.Count -gt 0 -and $unseen.Count -le 2) {
        $warnings += "كلمة لم تكتبها المحطة من قبل: $($unseen -join '، ') — تأكّد من هجائها"
    }
    return $warnings
}

function Select-RichTableRows {
    <#
        The newest rows a table may show, and how many were left out.

        Its own function because three screens had no cap at all and each
        would have grown into the same outage on a different station: a
        bulletin report over a month, a library nothing prunes, a ticker
        rewritten whole. A cap written four times is a cap that will be
        raised in three places and forgotten in the fourth.

        The newest, because every one of these screens is read for what
        happened most recently; the text version of each still carries the
        whole window for anyone who needs it.
    #>
    param([AllowNull()][object[]]$Items, [int]$Maximum = 0)
    if ($Maximum -le 0) { $Maximum = $script:RichTableMaxRows }
    $all = @($Items)
    if ($all.Count -le $Maximum) {
        return [pscustomobject]@{ Rows = $all; Hidden = 0 }
    }
    return [pscustomobject]@{ Rows = @($all | Select-Object -Last $Maximum); Hidden = ($all.Count - $Maximum) }
}

function Get-RichTableTrimNote {
    <# The line that admits what the table left out. Said on the screen, not
       only in a log: a table silently missing its oldest rows is a table that
       will be read as the whole story. #>
    param([Parameter(Mandatory)][int]$Hidden, [Parameter(Mandatory)][int]$Shown)
    if ($Hidden -le 0) { return '' }
    return "⚠️ عُرض أحدث $Shown صفًّا فقط؛ $Hidden صفًّا أقدم غير معروضة."
}

function Format-AuditTrailStamp {
    <#
        The stamp on one line of the 📜 screen.

        A clock time alone, which is what this was, is only unambiguous within
        a day - and the screen restores fifty entries from audit.jsonl, which
        on a quiet week reaches back several days. "07:22" then means one of
        four mornings, and the reader has no way to tell which.

        Today keeps the bare time, because that is the common case and a date
        on every line would be noise; anything older carries its date.
    #>
    param([Parameter(Mandatory)][datetime]$At)
    if ($At.Date -eq (Get-Date).Date) { return $At.ToString('HH:mm:ss') }
    return $At.ToString('MM-dd HH:mm:ss')
}

function Format-DurationMinutes {
    <#
        Minutes as something a person reads at a glance.

        "1200 دقيقة" makes the reader do arithmetic to discover it means
        twenty hours, and a setting nobody can read is a setting nobody
        adjusts. Only whole hours and days are named: 90 minutes stays
        "ساعة و30 دقيقة" rather than becoming a decimal nobody wants.

        Arabic counts its own way - dual for two, the plural form for three to
        ten, the singular again from eleven - so the number and the noun are
        chosen together instead of gluing an "s" on the end.
    #>
    param([int]$Minutes)
    $name = { param([int]$Count, [string]$One, [string]$Two, [string]$Few, [string]$Many)
        switch ($Count) {
            1 { $One }
            2 { $Two }
            default { if ($Count -le 10) { "$Count $Few" } else { "$Count $Many" } }
        } }

    if ($Minutes -le 0) { return '0 دقيقة' }
    if ($Minutes -lt 60) { return (& $name $Minutes 'دقيقة' 'دقيقتان' 'دقائق' 'دقيقة') }

    # Months and weeks as well as days. Idle time and how long a banner stayed
    # up are open-ended: an account last seen a fortnight ago read as "20160
    # دقيقة", and once days were named it still read as "14 يومًا" where
    # "أسبوعان" is what a person would say.
    #
    # A month here is thirty days and a week is seven. Neither is exact and
    # neither pretends to be: this answers "how long ago", not a calendar, and
    # an exact month would make the same elapsed time read differently
    # depending on which month it happened to fall in.
    $units = @(
        @{ Size = 43200; One = 'شهر'; Two = 'شهران'; Few = 'أشهر'; Many = 'شهرًا' }
        @{ Size = 10080; One = 'أسبوع'; Two = 'أسبوعان'; Few = 'أسابيع'; Many = 'أسبوعًا' }
        @{ Size = 1440; One = 'يوم'; Two = 'يومان'; Few = 'أيام'; Many = 'يومًا' }
        @{ Size = 60; One = 'ساعة'; Two = 'ساعتان'; Few = 'ساعات'; Many = 'ساعة' }
        @{ Size = 1; One = 'دقيقة'; Two = 'دقيقتان'; Few = 'دقائق'; Many = 'دقيقة' }
    )
    # The two largest units only. "شهر و12 يومًا و7 ساعات و20 دقيقة" is precise
    # and unreadable, and nobody deciding whether an account is dormant cares
    # about the minutes.
    $parts = @()
    $remaining = $Minutes
    foreach ($unit in $units) {
        if ($parts.Count -ge 2) { break }
        $count = [math]::Floor($remaining / $unit.Size)
        if ($count -le 0) { continue }
        $parts += (& $name $count $unit.One $unit.Two $unit.Few $unit.Many)
        $remaining = $remaining % $unit.Size
    }
    return ($parts -join ' و')
}

function Format-DurationSeconds {
    <# Seconds, handed up to the minutes formatter once there are enough of
       them. Same counting rules, so "5 ثانية" stops happening. #>
    param([int]$Seconds)
    $second = { param([int]$Count)
        switch ($Count) {
            1 { 'ثانية' }
            2 { 'ثانيتان' }
            default { if ($Count -le 10) { "$Count ثوانٍ" } else { "$Count ثانية" } }
        } }

    if ($Seconds -le 0) { return '0 ثانية' }
    if ($Seconds -lt 60) { return (& $second $Seconds) }

    # Promoted whenever there are enough seconds, not only when they divide
    # exactly by sixty. That guard meant an uptime of 3661 read as "3661
    # ثانية" - which is the very thing this was written to stop, surviving in
    # every value that is not a round minute, and uptime almost never is.
    if ($Seconds -ge 3600) {
        # Leftover seconds are noise beside an hour, let alone a day.
        return (Format-DurationMinutes -Minutes ([int][math]::Floor($Seconds / 60)))
    }
    $minutes = [int][math]::Floor($Seconds / 60)
    $rest = $Seconds % 60
    $text = Format-DurationMinutes -Minutes $minutes
    if ($rest -gt 0) { $text += " و$(& $second $rest)" }
    return $text
}

function Get-ArabicCountNoun {
    <#
        A counted noun with its right Arabic form, so a report never prints
        "8 مرة" or "1 مرات" again.

        1 keeps its number ("1 مرة" reads better than a bare "مرة" inside a
        ranked list), 2 takes the bare dual ("مرتين"), 3-10 the plural
        ("8 مرات"), and 0 and 11+ the singular ("0 مرة"، "359 مرة").
    #>
    param([int]$Count, [Parameter(Mandatory)][string]$One, [Parameter(Mandatory)][string]$Two, [Parameter(Mandatory)][string]$Few, [Parameter(Mandatory)][string]$Many)
    switch ($Count) {
        1 { return "1 $One" }
        2 { return $Two }
        default {
            if ($Count -ge 3 -and $Count -le 10) { return "$Count $Few" }
            return "$Count $Many"
        }
    }
}

function Format-CappedTail {
    <# How many list items the cap hid: "" when nothing was hidden, so callers
       can append it blindly. The settings notice capped at ten names and
       dropped the rest silently. #>
    param([int]$Total, [int]$Shown)
    if ($Total -gt $Shown) { return " (+$($Total - $Shown) أخرى)" }
    return ''
}

function Format-SettingDisplay {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $metadata = Get-JsonProp $script:SettingDisplayMetadata $Name
    $unit = if ($metadata) { [string](Get-JsonProp $metadata 'Unit') } else { '' }
    # A duration is spelled out; every other unit is simply appended.
    if ($unit -eq 'دقيقة') {
        $minutes = 0
        if ([int]::TryParse([string]$Value, [ref]$minutes)) { return (Format-DurationMinutes -Minutes $minutes) }
    }
    if ($unit) { return "$Value $unit" }
    return [string]$Value
}

function Get-SettingPromptText {
    param([Parameter(Mandatory)][string]$Name)
    $metadata = Get-JsonProp $script:SettingDisplayMetadata $Name
    $description = if ($metadata) { [string](Get-JsonProp $metadata 'Description') } else { 'قيمة الإعداد' }
    $current = Format-SettingDisplay -Name $Name -Value (Get-Setting $Name)
    $default = Format-SettingDisplay -Name $Name -Value $script:DefaultSettings[$Name]
    # parse_mode=HTML. The two values are what the operator is comparing, so
    # both are <code>: monospace lines them up under one another and keeps the
    # digits left-to-right beside the Arabic. Description and formatted values
    # come from the settings metadata, so all three are escaped.
    return "$(ConvertTo-TelegramHtmlText $description).`nالقيمة الحالية: <code>$(ConvertTo-TelegramHtmlText ([string]$current))</code>`nالقيمة الافتراضية: <code>$(ConvertTo-TelegramHtmlText ([string]$default))</code>`nأرسل رقمًا صحيحًا غير سالب:"
}

function Set-Setting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    # The range, checked here because this is the one door: two screens, an
    # import and a restore all arrive through it, and a rule enforced at one
    # of them is a rule with three ways round it. Refused rather than
    # clamped - a caller that means "as high as it goes" says so by asking
    # for the maximum, and silently changing a number somebody typed is worse
    # than telling them it is out of range.
    if ($script:SettingConstraints -and $script:SettingConstraints.ContainsKey($Name)) {
        $bounds = $script:SettingConstraints[$Name]
        $number = 0
        if ([int]::TryParse([string]$Value, [ref]$number)) {
            if ($null -ne $bounds.Minimum -and $number -lt [int]$bounds.Minimum) { throw "$Name لا يقلّ عن $($bounds.Minimum)." }
            if ($null -ne $bounds.Maximum -and $number -gt [int]$bounds.Maximum) { throw "$Name لا يزيد عن $($bounds.Maximum)." }
        }
    }
    $settings = Get-JsonProp $config 'Settings'
    if (-not $settings) {
        $settings = [pscustomobject]@{}
        $config | Add-Member -NotePropertyName 'Settings' -NotePropertyValue $settings -Force
    }
    $settings | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Save-Config
}

function Initialize-Settings {
    <# Fills in any setting missing from config.json with its default, so the
       file is self-documenting after first run and older configs upgrade
       cleanly. #>
    $added = Initialize-BridgeSettings -Config $config -Defaults $script:DefaultSettings
    if ($added) { Save-Config }
}

function Invoke-LogRotation {
    <# Renames bridge.log -> bridge.1.log -> bridge.2.log ... keeping
       LogKeepFiles generations, so an always-on playout box does not grow an
       unbounded log file. #>
    $keep = Get-SettingInt 'LogKeepFiles' 1
    $base = [System.IO.Path]::GetFileNameWithoutExtension($logPath)
    $ext = [System.IO.Path]::GetExtension($logPath)
    $oldest = Join-Path $logDir "$base.$keep$ext"
    if (Test-Path $oldest) { Remove-Item $oldest -Force -ErrorAction SilentlyContinue }
    for ($i = $keep - 1; $i -ge 1; $i--) {
        $from = Join-Path $logDir "$base.$i$ext"
        $to = Join-Path $logDir "$base.$($i + 1)$ext"
        if (Test-Path $from) { Move-Item $from $to -Force -ErrorAction SilentlyContinue }
    }
    Move-Item $logPath (Join-Path $logDir "$base.1$ext") -Force -ErrorAction SilentlyContinue
}

function Register-BridgeStartup {
    <#
        Notices a restart storm. Release days legitimately restart often (23
        startups on 2026-09-07), so this never blocks - it says once, when
        the StartupStormThreshold-th startup lands inside 24 hours, and
        leaves the operator to judge planned work from a crash loop. History
        is a small timestamp file beside the other state files, pruned to 48
        hours on every write; a corrupt entry is skipped, never fatal.
    #>
    try {
        $now = Get-Date
        $stamps = @()
        if (Test-Path -LiteralPath $script:startupHistoryFile) {
            $raw = Get-Content -LiteralPath $script:startupHistoryFile -Raw | ConvertFrom-Json
            foreach ($entry in @($raw)) {
                $moment = [datetime]::MinValue
                if ([datetime]::TryParse([string]$entry, [ref]$moment)) { $stamps += $moment }
            }
        }
        $stamps += $now
        $stamps = @($stamps | Where-Object { $_ -gt $now.AddHours(-48) } | Sort-Object)
        $json = ($stamps | ForEach-Object { $_.ToString('o') } | ConvertTo-Json)
        Write-BridgeValidatedJson -Path $script:startupHistoryFile -Json $json | Out-Null
        $threshold = Get-SettingInt 'StartupStormThreshold' 4
        $dayCount = @($stamps | Where-Object { $_ -gt $now.AddHours(-24) }).Count
        if ($threshold -gt 0 -and $dayCount -eq $threshold) {
            Write-BridgeLog "$threshold bridge startups inside 24 hours - notifying administrators once" 'WARN'
            Add-AuditEntry "🔁 الجسر أُعيد تشغيله $threshold مرات خلال 24 ساعة — عمل إصدارات أم حلقة عطل؟"
            Send-AdminBroadcast -Text "🔁 الجسر أُعيد تشغيله $threshold مرات خلال 24 ساعة. إن كان عمل إصدارات مخططًا فتجاهل هذا — وإلا راجع آخر أسطر bridge.log."
        }
    }
    catch { Write-BridgeLog "Could not record bridge startup: $($_.Exception.Message)" 'WARN' }
}

function Protect-SensitiveText {
    <# Strips credentials out of anything headed for the log or for chat.

       ffmpeg echoes its output URL in most error messages, and that URL is
       rtmp://<host>/s/<Telegram stream key> - so surfacing raw ffmpeg stderr
       would publish the stream key into the operators' chat and into
       bridge.log. Bot tokens and SRT passphrases get the same treatment. #>
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safe = $Text
    $safe = [regex]::Replace($safe, '(?i)(rtmps?://)[^\s"''<>]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(srt://)[^\s"''<>]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(passphrase=)[^\s&"'']+', '$1***')
    $safe = [regex]::Replace($safe, '\d{6,}:[A-Za-z0-9_\-]{25,}', '***BOT_TOKEN***')
    return $safe
}

function Protect-DiagnosticText {
    <# Diagnostic exports are more restrictive than the private runtime log:
       redact stable actor identifiers as well as credentials. #>
    param([AllowEmptyString()][string]$Text)
    $safe = Protect-SensitiveText $Text
    if ([string]::IsNullOrEmpty($safe)) { return $safe }
    return [regex]::Replace($safe, '(?i)\b(user|chat|from|admin|actor)(?:Id)?(=|\s+)\d+\b', '$1$2***')
}

function Write-BridgeLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $(Protect-SensitiveText $Message)"
    Write-Host $line
    try {
        $maxMB = Get-SettingInt 'LogMaxSizeMB' 0
        if ($maxMB -gt 0 -and (Test-Path $logPath) -and (Get-Item $logPath).Length -gt ($maxMB * 1MB)) {
            Invoke-LogRotation
        }
        Add-Content -Path $logPath -Value $line
    }
    catch {
        Write-Host "(logging failed: $($_.Exception.Message))"
    }
}

function Write-BridgeLivenessStamp {
    <# Rewrites logs/bridge.liveness with the current UTC time, once per poll
       loop, so BridgeManager.exe can tell a working bridge from a hung one.

       Neither of the two obvious signals works. The process staying alive says
       nothing: a long poll that never returns keeps it alive forever, which is
       exactly the failure worth catching. And silence on stdout is worse than
       useless - on this installation's own bridge.log a perfectly healthy
       bridge printed nothing between 22:30 and 09:00 night after night, once
       for a stretch of 17.8 hours, so a supervisor watching for silence would
       have restarted a working bridge on air every night.

       Best effort by design. A locked file, a full disk or a read-only log
       folder must never be able to interrupt polling: the worst outcome of a
       failed write here is that the manager reports the watchdog inactive. #>
    if (-not $script:livenessFile) { return }
    # Two lines: the stamp, then this process id. The id is what lets a manager
    # started after the bridge adopt it instead of reporting "stopped" beside a
    # bridge that is plainly on air - which is what an operator saw after the
    # manager was closed and reopened. A reader that only knows the old
    # single-line file still reads the first line.
    $value = @([datetime]::UtcNow.ToString('o'), [string]$PID)
    $lastError = ''
    # Retried once before anything is said, because the failure this file
    # actually sees is a reader landing on the instant of the write. Four of
    # them in a fortnight on this installation, every one gone by the next
    # loop, and each logged as though the watchdog had stopped - which teaches
    # an operator reviewing the log that this line means nothing.
    foreach ($attempt in 1, 2) {
        try {
            Set-Content -LiteralPath $script:livenessFile -Encoding utf8 -ErrorAction Stop -Value $value
            $script:LivenessWriteFailed = $false
            return
        }
        catch {
            $lastError = [string]$_.Exception.Message
            if ($attempt -eq 1) { Start-Sleep -Milliseconds 120 }
        }
    }
    # Said once per run, not once per loop: a read-only log folder would
    # otherwise repeat this every thirty seconds for as long as the bridge
    # lives, and drown the log it is complaining about.
    if (-not $script:LivenessWriteFailed) {
        $script:LivenessWriteFailed = $true
        Write-BridgeLog "Could not write the liveness stamp, twice ($lastError) - if it keeps failing the manager reports its hang watchdog inactive." 'WARN'
    }
}

function Get-AuditArchiveFiles {
    <# Rotated audit files, newest first. Named by the moment they were
       closed, so the order is the name's order and nothing has to be renamed
       on every rotation the way bridge.N.log is. #>
    if (-not $script:auditFile) { return @() }
    $dir = Split-Path -Parent $script:auditFile
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    # Only the exact stamped shape this rotation writes, and never the active
    # file. A loose audit-*.jsonl glob adopts anything that happens to sit in
    # the log folder and reads it as history.
    return @(Get-ChildItem -LiteralPath $dir -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^audit-\d{8}-\d{6}\.jsonl$' -and $_.FullName -ne $script:auditFile } |
            Sort-Object Name -Descending)
}

function Invoke-AuditRotation {
    <#
        Closes audit.jsonl once it passes AuditMaxSizeMB and starts a new one.

        Archives, never deletes. bridge.log rotates through five generations
        and drops the oldest, which is right for a diagnostic log and wrong
        here: audit.jsonl is the permanent record of who put what on air, and
        the one question it exists to answer is always about the past.
        AuditArchiveKeepFiles is 0 by default, meaning keep everything; set it
        only if the disk genuinely demands it, and know what is being traded.

        The active file stays small so the digest and /who keep reading a
        bounded tail rather than a year of history.
    #>
    $maxMB = Get-SettingInt 'AuditMaxSizeMB' 0
    if ($maxMB -le 0) { return $false }
    if (-not (Test-Path -LiteralPath $script:auditFile)) { return $false }
    if ((Get-Item -LiteralPath $script:auditFile).Length -le ($maxMB * 1MB)) { return $false }

    $dir = Split-Path -Parent $script:auditFile
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $archive = Join-Path $dir "audit-$stamp.jsonl"
    try {
        Move-Item -LiteralPath $script:auditFile -Destination $archive -Force -ErrorAction Stop
        Write-BridgeLog "Audit trail reached $maxMB MB and was archived to $(Split-Path -Leaf $archive)" 'WARN'
    }
    catch {
        Write-BridgeLog "Could not archive the audit trail: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    $keep = Get-SettingInt 'AuditArchiveKeepFiles' 0
    if ($keep -gt 0) {
        foreach ($old in @(Get-AuditArchiveFiles | Select-Object -Skip $keep)) {
            Write-BridgeLog "Deleting audit archive $($old.Name) - AuditArchiveKeepFiles is $keep" 'WARN'
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Write-ValidatedJsonState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    $success = Write-BridgeValidatedJson -Path $Path -Json $Json
    if (-not $success) { Write-BridgeLog "Validated JSON state write failed for '$([IO.Path]::GetFileName($Path))'" 'ERROR' }
    return $success
}

function Read-ValidatedJsonState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AsHashtable
    )
    $result = Read-BridgeValidatedJson -Path $Path -AsHashtable:$AsHashtable
    if ($result -and $result.Recovered) {
        Write-BridgeLog "Recovered '$([IO.Path]::GetFileName($Path))' from its last validated backup" 'WARN'
    }
    return $result
}

function Add-UserOperationHistory {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [Parameter(Mandatory)][long]$UserId,
        [int]$Layer = 0,
        [string]$Target = '',
        [string]$Values = ''
    )
    $key = [string]$UserId
    $history = [System.Collections.Generic.List[object]]::new()
    if ($script:UserOperationHistory.ContainsKey($key)) {
        foreach ($existing in @($script:UserOperationHistory[$key])) { $history.Add($existing) }
    }
    $history.Add([pscustomobject]@{
        At = Get-Date; OperationId = $OperationId; Action = $Action; Result = $Result
        DurationMs = $DurationMs; Layer = $Layer; Target = $Target; Values = $Values
    })
    while ($history.Count -gt 20) { $history.RemoveAt(0) }
    $script:UserOperationHistory[$key] = $history.ToArray()
}

function Get-UserOperationHistory {
    param([Parameter(Mandatory)][long]$UserId)
    $key = [string]$UserId
    if (-not $script:UserOperationHistory.ContainsKey($key)) { return @() }
    return @($script:UserOperationHistory[$key])
}

function Write-AuditRecord {
    <# Permanent machine-readable security and control audit trail. This is
       intentionally separate from bridge.log (runtime diagnostics) and from
       the short in-memory list displayed in Telegram. #>
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][string]$Result,
        [long]$UserId = 0,
        [string]$UserName = '',
        [long]$ChatId = 0,
        [string]$Action = '',
        [int]$Layer = 0,
        [string]$Target = '',
        [long]$DurationMs = 0,
        [string]$Message = '',
        [string]$Values = '',
        [int]$Count = 0
    )
    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        operationId  = Protect-SensitiveText (($OperationId -replace '[\r\n]+', ' ').Trim())
        event        = Protect-SensitiveText (($EventName -replace '[\r\n]+', ' ').Trim())
        result       = Protect-SensitiveText (($Result -replace '[\r\n]+', ' ').Trim())
        userId       = $UserId
        userName     = Protect-SensitiveText (($UserName -replace '[\r\n]+', ' ').Trim())
        chatId       = $ChatId
        action       = Protect-SensitiveText (($Action -replace '[\r\n]+', ' ').Trim())
        layer        = $Layer
        target       = Protect-SensitiveText (($Target -replace '[\r\n]+', ' ').Trim())
        durationMs   = $DurationMs
        message      = Protect-SensitiveText (($Message -replace '[\r\n]+', ' ').Trim())
    }
    # Only carried when there is something to carry: audit.jsonl is permanent
    # and archived, so an empty key on every record is pure growth.
    if (-not [string]::IsNullOrWhiteSpace($Values)) {
        $record.values = Protect-SensitiveText (($Values -replace '[\r\n]+', ' ').Trim())
    }
    if ($Count -gt 0) { $record.count = $Count }
    try {
        # Out-Null, or the rotation's true/false joins this function's output
        # and lands in whatever the caller returns - Invoke-ShowTemplateResult
        # came back as an array and lost its .Success.
        Invoke-AuditRotation | Out-Null
        Add-Content -LiteralPath $script:auditFile -Value ($record | ConvertTo-Json -Compress -Depth 4) -Encoding utf8
    }
    catch {
        Write-BridgeLog "AUDIT_WRITE_FAILED id=$OperationId event=$EventName error=$($_.Exception.Message)" 'ERROR'
    }
}

function Add-AuditEntry {
    <# Short in-memory history surfaced by the admin's 📜 button, so "who put
       that on air?" can be answered from Telegram without opening the log. #>
    param([Parameter(Mandatory)][string]$Message)
    $script:AuditTrail.Add("$(Format-AuditTrailStamp -At (Get-Date)) $Message")
    $max = Get-SettingInt 'AuditTrailSize' 1
    while ($script:AuditTrail.Count -gt $max) { $script:AuditTrail.RemoveAt(0) }
    Write-AuditRecord -OperationId "audit-$([guid]::NewGuid().ToString('N'))" -EventName activity -Result success -Message $Message
}

function Get-AuditRecordField {
    <# Audit records are written by a dozen call sites and only carry the
       fields each one cares about, so under StrictMode a direct read of a
       missing key would take down a whole restore. #>
    param($Record, [Parameter(Mandatory)][string]$Name)
    if ($Record -and $Record.PSObject.Properties[$Name]) { return [string]$Record.PSObject.Properties[$Name].Value }
    return ''
}

function Read-AuditRecordStamp {
    <# RoundtripKind, or a 'Z' stamp parses as Local and ToLocalTime() then
       shifts it a second time. #>
    param($Record)
    $at = [datetime]::MinValue
    if ([datetime]::TryParse((Get-AuditRecordField $Record 'timestampUtc'), $null,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) {
        return $at.ToLocalTime()
    }
    return $null
}

function Import-AuditTrail {
    <# Rehydrates the 📜 screen's in-memory history from audit.jsonl, which
       already holds every entry Add-AuditEntry ever wrote - only the display
       cache was lost with the process.

       Restored lines carry the redacted message that was persisted, which is
       never less safe than the live in-memory one. #>
    try {
        $max = Get-SettingInt 'AuditTrailSize' 1
        $restored = [System.Collections.Generic.List[string]]::new()
        # Over-read: air_control records interleave with the activity ones
        # this screen shows, so $max lines would rarely yield $max entries.
        foreach ($record in @(Read-AuditRecords -MaxLines ($max * 10))) {
            if ((Get-AuditRecordField $record 'event') -ne 'activity') { continue }
            $at = Read-AuditRecordStamp -Record $record
            $stamp = if ($at) { Format-AuditTrailStamp -At $at } else { '--:--:--' }
            $restored.Add("$stamp $(Get-AuditRecordField $record 'message')")
        }
        while ($restored.Count -gt $max) { $restored.RemoveAt(0) }
        $script:AuditTrail = $restored
        if ($restored.Count -gt 0) { Write-BridgeLog "Restored $($restored.Count) audit entry(ies) for the 📜 screen." }
    }
    catch { Write-BridgeLog "Could not restore the audit trail display: $($_.Exception.Message)" 'WARN' }
}

function Import-UserOperationHistory {
    <# Rebuilds 🧾 عملياتي from the same permanent audit file, so an operator
       whose shift outlives a restart still sees their own recent control
       actions instead of an empty screen. #>
    try {
        $perUser = @{}
        foreach ($record in @(Read-AuditRecords -MaxLines 1500)) {
            if ((Get-AuditRecordField $record 'event') -ne 'air_control') { continue }
            $userId = 0L
            if (-not [long]::TryParse((Get-AuditRecordField $record 'userId'), [ref]$userId) -or $userId -eq 0) { continue }
            $at = Read-AuditRecordStamp -Record $record
            if (-not $at) { continue }
            $duration = 0L
            [void][long]::TryParse((Get-AuditRecordField $record 'durationMs'), [ref]$duration)
            $layer = 0
            [void][int]::TryParse((Get-AuditRecordField $record 'layer'), [ref]$layer)
            $key = [string]$userId
            if (-not $perUser.ContainsKey($key)) { $perUser[$key] = [System.Collections.Generic.List[object]]::new() }
            $perUser[$key].Add([pscustomobject]@{
                    At = $at; OperationId = (Get-AuditRecordField $record 'operationId')
                    Action = (Get-AuditRecordField $record 'action'); Result = (Get-AuditRecordField $record 'result')
                    DurationMs = $duration; Layer = $layer; Target = (Get-AuditRecordField $record 'target')
                    Values = (Get-AuditRecordField $record 'values')
                })
        }
        $total = 0
        foreach ($key in @($perUser.Keys)) {
            $list = $perUser[$key]
            # Same 20-entry ceiling Add-UserOperationHistory keeps.
            while ($list.Count -gt 20) { $list.RemoveAt(0) }
            $script:UserOperationHistory[$key] = $list.ToArray()
            $total += $list.Count
        }
        if ($total -gt 0) { Write-BridgeLog "Restored $total operation(s) for $($perUser.Count) user(s) on the 🧾 screen." }
    }
    catch { Write-BridgeLog "Could not restore per-user operation history: $($_.Exception.Message)" 'WARN' }
}

function Get-TextElementCount {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return [Globalization.StringInfo]::ParseCombiningCharacters($Text).Count
}

function Get-SafeTextPrefixLength {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][int]$MaximumCodeUnits)
    if ($Text.Length -le $MaximumCodeUnits) { return $Text.Length }
    $boundaries = [Globalization.StringInfo]::ParseCombiningCharacters($Text)
    $prefixLength = 0
    foreach ($boundary in $boundaries) {
        if ($boundary -gt $MaximumCodeUnits) { break }
        $prefixLength = $boundary
    }
    if ($prefixLength -gt 0) { return $prefixLength }
    # An exceptionally large combining sequence can exceed the whole Telegram
    # chunk. Fall back to a code-point-safe cut so progress is still made.
    $prefixLength = [math]::Min($MaximumCodeUnits, $Text.Length)
    if ($prefixLength -gt 0 -and [char]::IsHighSurrogate($Text[$prefixLength - 1])) { $prefixLength-- }
    return [math]::Max(1, $prefixLength)
}

function Split-TelegramText {
    <# Telegram rejects messages over 4096 characters outright. Long template
       listings and audit dumps are chunked on line boundaries.

       Always returns a flat [string[]]. Do NOT "optimise" the short-message
       path to `return , @($Text)`: the unary comma wraps the array, the
       function then emits a single *array* object, and the caller ends up
       putting an array into the message body - which Telegram receives as the
       literal text "System.Object[]". #>
    param([Parameter(Mandatory)][string]$Text)
    $limit = $script:TelegramTextLimit
    $chunks = [System.Collections.Generic.List[string]]::new()

    if ($Text.Length -le $limit) {
        $chunks.Add($Text)
        return $chunks.ToArray()
    }

    $current = [System.Text.StringBuilder]::new()
    foreach ($rawLine in ($Text -split "`n")) {
        $line = [string]$rawLine
        # A single line longer than the whole limit has to be hard-split.
        while ($line.Length -gt $limit) {
            if ($current.Length -gt 0) {
                $chunks.Add($current.ToString())
                $current.Clear() | Out-Null
            }
            $prefixLength = Get-SafeTextPrefixLength -Text $line -MaximumCodeUnits $limit
            $chunks.Add($line.Substring(0, $prefixLength))
            $line = $line.Substring($prefixLength)
        }
        $separator = if ($current.Length -gt 0) { 1 } else { 0 }
        if (($current.Length + $separator + $line.Length) -gt $limit) {
            $chunks.Add($current.ToString())
            $current.Clear() | Out-Null
            $separator = 0
        }
        if ($separator -eq 1) { $current.Append("`n") | Out-Null }
        $current.Append($line) | Out-Null
    }
    if ($current.Length -gt 0) { $chunks.Add($current.ToString()) }
    return $chunks.ToArray()
}
