Set-StrictMode -Version Latest

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
        $item = ([string]$parts[$index]).Trim()
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

function ConvertTo-NewsTickerText {
    [CmdletBinding()]
    param(
        [string[]]$Items = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Separator
    )
    if (@($Items).Count -eq 0) { return '' }
    return (@($Items | ForEach-Object { "$(([string]$_).Trim()) $Separator" }) -join "`r`n") + "`r`n"
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

Export-ModuleMember -Function ConvertFrom-NewsTickerText,ConvertTo-NewsTickerText,Get-NewsTickerSnapshot,Publish-NewsTickerFile,Restore-NewsTickerBackup
