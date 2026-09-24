Set-StrictMode -Version Latest

function Get-CleanNewsItemText {
    <#
        One headline as it may safely reach the ticker file and the screen.

        Text pasted from WhatsApp, a browser or Word carries characters nobody
        typed. Direction marks and embeddings (U+200E/F, U+202A-E, U+2066-9)
        reorder the words on air; a BOM, zero-width space or soft hyphen is
        invisible here and a gap or a stray glyph there; a tab, non-breaking
        space or line break inside a headline breaks the strap. They go, and
        whitespace runs become one space.

        U+200D stays: it is what holds an emoji sequence - a family, a flag -
        together, and without it one picture becomes several. U+200C stays
        with it: it is meaningful in Persian and Urdu text.
    #>
    param([AllowEmptyString()][string]$Text = '')
    $clean = [regex]::Replace($Text, '[\u200B\u200E\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF\u00AD]', '')
    # Every other control and every kind of space: tab, CR/LF, NBSP, the
    # thin and figure spaces a typesetter uses.
    $clean = [regex]::Replace($clean, '[\p{Cc}\p{Zs}\u2028\u2029]+', ' ')
    return $clean.Trim()
}

function ConvertFrom-NewsTickerText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator,
        [int]$MaxItemLength = 0,
        [int]$MaxItems = 0
    )
    $usesSeparator = $Text.Contains($Separator, [StringComparison]::Ordinal)
    [string[]]$parts = @(if ($usesSeparator) {
        @($Text.Split([string[]]@($Separator), [StringSplitOptions]::None))
    }
    else {
        @([regex]::Split($Text, '\r?\n'))
    })
    $items = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $emptyCount = 0
    $duplicateCount = 0
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $item = Get-CleanNewsItemText -Text ([string]$parts[$index])
        $isStructuralTail = $index -eq ($parts.Count - 1) -and $item.Length -eq 0 -and
            (($usesSeparator -and $Text.TrimEnd().EndsWith($Separator, [StringComparison]::Ordinal)) -or
             (-not $usesSeparator -and $Text -match '(?:\r?\n)$'))
        if ($item.Length -eq 0) {
            if (-not $isStructuralTail) { $emptyCount++ }
            continue
        }
        if ($MaxItemLength -gt 0 -and [Globalization.StringInfo]::ParseCombiningCharacters($item).Count -gt $MaxItemLength) {
            $errors.Add("يتجاوز الخبر رقم $($index + 1) الحد الأقصى $MaxItemLength.")
            continue
        }
        if (-not $seen.Add($item)) { $duplicateCount++; continue }
        $items.Add($item)
    }
    if ($MaxItems -gt 0 -and $items.Count -gt $MaxItems) {
        $errors.Add("عدد الأخبار $($items.Count) يتجاوز الحد الأقصى $MaxItems.")
    }
    return [pscustomobject]@{
        Success = $errors.Count -eq 0
        Items = @($items)
        EmptyCount = $emptyCount
        DuplicateCount = $duplicateCount
        Errors = @($errors)
    }
}

function ConvertFrom-NewsPasteText {
    <#
        Several headlines pasted at once, split and set aside rather than
        refused.

        ConvertFrom-NewsTickerText refuses the whole text when one item is too
        long - right for a file that must publish whole, wrong for a paste,
        where one long line should not cost the other nine. So the long ones
        come back by name in TooLong, and the rest go on.

        A copied list brings its numbering and bullets: "1.", "2)", "٣-",
        "-", "•", "*", "▪️". A marker is stripped only when punctuation or a
        bullet follows it and a space follows that, so "3 شهداء" and
        "2026 عام" stay news. \d matches Arabic-Indic digits too.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator,
        [int]$MaxItemLength = 0
    )
    $parsed = ConvertFrom-NewsTickerText -Text $Text -Separator $Separator
    $items = [Collections.Generic.List[string]]::new()
    $tooLong = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $duplicates = [int]$parsed.DuplicateCount
    foreach ($raw in @($parsed.Items)) {
        $item = ([regex]::Replace([string]$raw, '^(?:\d{1,3}\s*[.)\-\u2013\u2014:]|[-\u2013\u2014\u2022*\u00B7\u25CF\u25AA\u25FE\u25A0\u25BA\u25B6\uFE0F]+)\s+', '')).Trim()
        if ($item.Length -eq 0) { continue }
        if (-not $seen.Add($item)) { $duplicates++; continue }
        if ($MaxItemLength -gt 0 -and [Globalization.StringInfo]::ParseCombiningCharacters($item).Count -gt $MaxItemLength) {
            $tooLong.Add($item); continue
        }
        $items.Add($item)
    }
    return [pscustomobject]@{ Items = @($items); TooLong = @($tooLong); DuplicateCount = $duplicates }
}

function ConvertTo-NewsTickerText {
    [CmdletBinding()]
    param(
        [string[]]$Items = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator
    )
    if (@($Items).Count -eq 0) { return '' }
    return (@($Items | ForEach-Object { "$(([string]$_).Trim()) $Separator" }) -join "`r`n") + "`r`n"
}

function ConvertFrom-NewsSheetCsv {
    <# One ticker item per sheet row, taken from the first column.

       Parsed as real CSV rather than as lines of text. A Google Sheets export
       quotes any cell containing a comma, so the previous line-based approach
       put the quotes themselves on air; it also split a cell that the sheet
       had wrapped across lines into two half-headlines. Columns after the
       first are the editor's own notes and never reach the ticker. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Csv = '')
    if ([string]::IsNullOrWhiteSpace($Csv)) { return @() }
    $rows = @()
    try { $rows = @($Csv | ConvertFrom-Csv -Header 'Item' -ErrorAction Stop) }
    catch { return @() }
    $items = [Collections.Generic.List[string]]::new()
    foreach ($row in $rows) {
        $item = ([string]$row.Item).Trim()
        if ($item.Length -gt 0) { $items.Add($item) }
    }
    return @($items)
}

function Get-NewsTickerFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-NewsTickerUtf8 {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $decoder = [Text.UTF8Encoding]::new($false, $true)
    return $decoder.GetString($bytes, $offset, $bytes.Length - $offset)
}

function Get-NewsTickerSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator,
        [int]$MaxItemLength = 0,
        [int]$MaxItems = 0
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{Success=$true;Exists=$false;Items=@();Hash='';LastWriteTime=$null;Error='';EmptyCount=0;DuplicateCount=0}
    }
    try {
        $text = Read-NewsTickerUtf8 -Path $Path
        if ($text.IndexOf([char]0) -ge 0) { throw 'الملف يحتوي بيانات ثنائية غير صالحة.' }
        $parsed = ConvertFrom-NewsTickerText -Text $text -Separator $Separator -MaxItemLength $MaxItemLength -MaxItems $MaxItems
        if (-not $parsed.Success) { throw ($parsed.Errors -join ' ') }
        $item = Get-Item -LiteralPath $Path
        return [pscustomobject]@{
            Success=$true;Exists=$true;Items=@($parsed.Items);Hash=(Get-NewsTickerFileHash -Path $Path)
            LastWriteTime=$item.LastWriteTime;Error='';EmptyCount=$parsed.EmptyCount;DuplicateCount=$parsed.DuplicateCount
        }
    }
    catch {
        return [pscustomobject]@{Success=$false;Exists=$true;Items=@();Hash='';LastWriteTime=$null;Error=$_.Exception.Message;EmptyCount=0;DuplicateCount=0}
    }
}

function Remove-OldNewsTickerBackups {
    param([Parameter(Mandatory)][string]$BackupDirectory,[int]$KeepFiles=10)
    if ($KeepFiles -le 0 -or -not (Test-Path -LiteralPath $BackupDirectory)) { return }
    $files = @(Get-ChildItem -LiteralPath $BackupDirectory -File -Filter '*.txt' | Sort-Object LastWriteTimeUtc,Name -Descending)
    foreach ($file in @($files | Select-Object -Skip $KeepFiles)) { Remove-Item -LiteralPath $file.FullName -Force }
}

function Publish-NewsTickerFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Items = @(),
        [AllowEmptyString()][string]$ExpectedHash = '',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [int]$BackupKeepFiles = 10,
        [int]$MaxItemLength = 0,
        [int]$MaxItems = 0
    )
    $currentHash = Get-NewsTickerFileHash -Path $Path
    if ($currentHash -ne $ExpectedHash) {
        return [pscustomobject]@{Success=$false;Conflict=$true;BackupPath='';Hash=$currentHash;Error='تغير ملف الأخبار خارجيًا منذ إنشاء المسودة.'}
    }
    $validation = ConvertFrom-NewsTickerText -Text (ConvertTo-NewsTickerText -Items $Items -Separator $Separator) `
        -Separator $Separator -MaxItemLength $MaxItemLength -MaxItems $MaxItems
    if (-not $validation.Success) {
        return [pscustomobject]@{Success=$false;Conflict=$false;BackupPath='';Hash=$currentHash;Error=($validation.Errors -join ' ')}
    }
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $directory (".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp")
    $backupPath = ''
    try {
        if (-not (Test-Path -LiteralPath $directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
            $backupPath = Join-Path $BackupDirectory ("news-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt")
            Copy-Item -LiteralPath $Path -Destination $backupPath -ErrorAction Stop
        }
        $text = ConvertTo-NewsTickerText -Items $validation.Items -Separator $Separator
        [IO.File]::WriteAllText($temporary, $text, [Text.UTF8Encoding]::new($true))
        $verify = Get-NewsTickerSnapshot -Path $temporary -Separator $Separator -MaxItemLength $MaxItemLength -MaxItems $MaxItems
        if (-not $verify.Success -or (@($verify.Items) -join "`u{001F}") -cne (@($validation.Items) -join "`u{001F}")) {
            throw 'فشل التحقق من ملف الأخبار المؤقت.'
        }
        [IO.File]::Move($temporary, $Path, $true)
        Remove-OldNewsTickerBackups -BackupDirectory $BackupDirectory -KeepFiles $BackupKeepFiles
        return [pscustomobject]@{Success=$true;Conflict=$false;BackupPath=$backupPath;Hash=(Get-NewsTickerFileHash -Path $Path);Error=''}
    }
    catch {
        return [pscustomobject]@{Success=$false;Conflict=$false;BackupPath=$backupPath;Hash=$currentHash;Error=$_.Exception.Message}
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-NewsTickerBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupPath,
        [AllowEmptyString()][string]$ExpectedHash = '',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [int]$BackupKeepFiles = 10,
        [int]$MaxItemLength = 0,
        [int]$MaxItems = 0
    )
    $backup = Get-NewsTickerSnapshot -Path $BackupPath -Separator $Separator -MaxItemLength $MaxItemLength -MaxItems $MaxItems
    if (-not $backup.Success -or -not $backup.Exists) {
        return [pscustomobject]@{Success=$false;Conflict=$false;BackupPath='';Hash='';Error='النسخة الاحتياطية غير صالحة أو غير موجودة.'}
    }
    return Publish-NewsTickerFile -Path $Path -Items $backup.Items -ExpectedHash $ExpectedHash -Separator $Separator `
        -BackupDirectory $BackupDirectory -BackupKeepFiles $BackupKeepFiles -MaxItemLength $MaxItemLength -MaxItems $MaxItems
}

Export-ModuleMember -Function ConvertFrom-NewsSheetCsv,ConvertFrom-NewsTickerText,ConvertFrom-NewsPasteText,Get-CleanNewsItemText,ConvertTo-NewsTickerText,Get-NewsTickerSnapshot,Publish-NewsTickerFile,Restore-NewsTickerBackup
