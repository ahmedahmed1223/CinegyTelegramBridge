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
    $managed = @('AllowedChatIds', 'AdminChatIds', 'AllowedUserIds', 'AdminUserIds', 'Settings', 'LiveStream')
    $target = $null
    try { $target = Get-Content -Path $Path -Raw | ConvertFrom-Json }
    catch { Write-Host "Save-Config: could not re-read $Path, writing in-memory copy." }

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

function Format-SettingDisplay {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $metadata = Get-JsonProp $script:SettingDisplayMetadata $Name
    if ($metadata -and (Get-JsonProp $metadata 'Unit')) { return "$Value $((Get-JsonProp $metadata 'Unit'))" }
    return [string]$Value
}

function Get-SettingPromptText {
    param([Parameter(Mandatory)][string]$Name)
    $metadata = Get-JsonProp $script:SettingDisplayMetadata $Name
    $description = if ($metadata) { [string](Get-JsonProp $metadata 'Description') } else { 'قيمة الإعداد' }
    $current = Format-SettingDisplay -Name $Name -Value (Get-Setting $Name)
    $default = Format-SettingDisplay -Name $Name -Value $script:DefaultSettings[$Name]
    return "$description.`nالقيمة الحالية: $current`nالقيمة الافتراضية: $default`nأرسل رقمًا صحيحًا غير سالب:"
}

function Set-Setting {
    param([Parameter(Mandatory)][string]$Name, $Value)
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
        [string]$Target = ''
    )
    $key = [string]$UserId
    $history = [System.Collections.Generic.List[object]]::new()
    if ($script:UserOperationHistory.ContainsKey($key)) {
        foreach ($existing in @($script:UserOperationHistory[$key])) { $history.Add($existing) }
    }
    $history.Add([pscustomobject]@{
        At = Get-Date; OperationId = $OperationId; Action = $Action; Result = $Result
        DurationMs = $DurationMs; Layer = $Layer; Target = $Target
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
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][string]$Result,
        [long]$UserId = 0,
        [long]$ChatId = 0,
        [string]$Action = '',
        [int]$Layer = 0,
        [string]$Target = '',
        [long]$DurationMs = 0,
        [string]$Message = ''
    )
    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        operationId  = Protect-SensitiveText (($OperationId -replace '[\r\n]+', ' ').Trim())
        event        = Protect-SensitiveText (($Event -replace '[\r\n]+', ' ').Trim())
        result       = Protect-SensitiveText (($Result -replace '[\r\n]+', ' ').Trim())
        userId       = $UserId
        chatId       = $ChatId
        action       = Protect-SensitiveText (($Action -replace '[\r\n]+', ' ').Trim())
        layer        = $Layer
        target       = Protect-SensitiveText (($Target -replace '[\r\n]+', ' ').Trim())
        durationMs   = $DurationMs
        message      = Protect-SensitiveText (($Message -replace '[\r\n]+', ' ').Trim())
    }
    try {
        Add-Content -LiteralPath $script:auditFile -Value ($record | ConvertTo-Json -Compress -Depth 4) -Encoding utf8
    }
    catch {
        Write-BridgeLog "AUDIT_WRITE_FAILED id=$OperationId event=$Event error=$($_.Exception.Message)" 'ERROR'
    }
}

function Add-AuditEntry {
    <# Short in-memory history surfaced by the admin's 📜 button, so "who put
       that on air?" can be answered from Telegram without opening the log. #>
    param([Parameter(Mandatory)][string]$Message)
    $script:AuditTrail.Add("$(Get-Date -Format 'HH:mm:ss') $Message")
    $max = Get-SettingInt 'AuditTrailSize' 1
    while ($script:AuditTrail.Count -gt $max) { $script:AuditTrail.RemoveAt(0) }
    Write-AuditRecord -OperationId "audit-$([guid]::NewGuid().ToString('N'))" -Event activity -Result success -Message $Message
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

