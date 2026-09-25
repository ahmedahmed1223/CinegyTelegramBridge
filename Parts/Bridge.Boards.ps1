#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Programme content boards: the producer's prepared table, and the one tap
    that puts a row of it on air.

    There is no engine here, deliberately. A row goes to air through
    Invoke-ShowTemplateResult like any other graphic, so this file inherits the
    whole funnel - maintenance mode, the per-layer permission, the reserved
    layer policy, the live Cinegy check, the audit record, the rollback
    candidate, the air notice, and stopping a bulletin or a breaking-news board
    that owns the layer. A third run-plan implementation beside those two is
    the duplication AGENTS.md warns about, and single-shot is what this
    workflow actually needs.

    The domain lives in Modules/BridgeContentBoards.psm1 and knows nothing of
    Telegram, Cinegy or the disk. This file is the glue.
#>

function Get-BoardsDirectory {
    return (Join-Path $script:logDir 'boards')
}

function Get-BoardFilePath {
    param([Parameter(Mandatory)][string]$BoardId)
    return (Join-Path (Get-BoardsDirectory) "$BoardId.json")
}

function Test-BoardsAvailable {
    return [bool](Get-Setting 'EnableContentBoards')
}

function Import-ContentBoards {
    <#
        Every board on disk, read once at startup.

        One file per board, and NO index file: the directory is the index. An
        index kept beside the files is a second source of truth that drifts
        from the first the moment one write succeeds and the other does not,
        and twenty small reads at boot are cheaper than a silent divergence.

        A board whose file cannot be read at all is skipped and named, not
        allowed to stop the bridge: a producer's table is not worth refusing to
        start over.
    #>
    $script:ContentBoards = [ordered]@{}
    $directory = Get-BoardsDirectory
    if (-not (Test-Path -LiteralPath $directory)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -like '*.bak') { continue }
        try {
            $read = Read-BridgeValidatedJson -Path $file.FullName
            if (-not $read -or -not $read.Data) { continue }
            $board = $read.Data
            $id = [string](Get-JsonProp $board 'Id')
            if (-not $id) { continue }
            if ($read.Recovered) { Write-BridgeLog "Recovered content board '$id' from its backup." 'WARN' }
            $script:ContentBoards[$id] = $board
        }
        catch { Write-BridgeLog "Could not read content board $($file.Name): $($_.Exception.Message)" 'WARN' }
    }
    if ($script:ContentBoards.Count -gt 0) {
        Write-BridgeLog "Loaded $($script:ContentBoards.Count) programme content board(s)."
    }
}

function Save-ContentBoard {
    <# Through the shared validated writer, which already owns the unique temp
       file, the verified backup and the atomic replace - and whose tests in
       BridgeStorage.Tests.ps1 are inherited rather than rewritten. #>
    param([Parameter(Mandatory)]$Board)
    $id = [string](Get-JsonProp $Board 'Id')
    if (-not $id) { return $false }
    if (-not (Write-BridgeValidatedJson -Path (Get-BoardFilePath -BoardId $id) -Json ($Board | ConvertTo-Json -Depth 10))) {
        Write-BridgeLog "Could not write content board '$id'." 'WARN'
        return $false
    }
    $script:ContentBoards[$id] = $Board
    return $true
}

function Remove-ContentBoardFile {
    <# A deleted board takes its file with it. Leaving it behind would have the
       directory - which IS the index - still listing a board nobody can reach. #>
    param([Parameter(Mandatory)][string]$BoardId)
    $path = Get-BoardFilePath -BoardId $BoardId
    foreach ($target in @($path, "$path.bak")) {
        if (Test-Path -LiteralPath $target) {
            try { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            catch { Write-BridgeLog "Could not remove $target`: $($_.Exception.Message)" 'WARN' }
        }
    }
    $script:ContentBoards.Remove($BoardId) | Out-Null
}

function Get-ContentBoard {
    param([Parameter(Mandatory)][string]$BoardId)
    if ($script:ContentBoards.Contains($BoardId)) { return $script:ContentBoards[$BoardId] }
    return $null
}

function Get-ContentBoards {
    return @($script:ContentBoards.Values)
}

# --------------------------------------------------------------- scene fields

function Get-BoardTextFields {
    <#
        The text variables this board's scene declares, in the scene's order.

        Media fields are not returned: this feature fills text only, and a
        variable the bridge never sends is left exactly as the designer built
        it - which is the point, not a shortfall. A programme banner keeps its
        own background and logo and changes its words.
    #>
    param([Parameter(Mandatory)][string]$TemplateKey)
    return @(Get-MojazDesignFields -TemplateKey $TemplateKey | Where-Object { [string]$_.Kind -eq 'text' } | ForEach-Object { [string]$_.Name })
}

function Get-BoardMediaFields {
    <# Listed on the card marked "from the scene", never edited. Silence here
       would read as "the developer forgot the picture field". #>
    param([Parameter(Mandatory)][string]$TemplateKey)
    return @(Get-MojazDesignFields -TemplateKey $TemplateKey | Where-Object { [string]$_.Kind -eq 'media' } | ForEach-Object { [string]$_.Name })
}

function Get-BoardEligibleTemplates {
    <#
        Every template with the verdict on whether a board can be bound to it.

        Unusable ones are returned MARKED, not dropped: an administrator who
        cannot find the template they meant deserves to be told why. Two of the
        four templates on this station declare no fields at all.
    #>
    $store = Get-TemplateStore
    return @(foreach ($key in @($store.Order)) {
            $template = $store.Map[$key]
            $path = [string](Get-JsonProp $template 'Path')
            $reason = ''
            $textFields = @()
            if (-not $path) { $reason = (T 'board.noScenePath') }
            elseif (-not (Test-Path -LiteralPath $path)) { $reason = (T 'board.sceneFileMissing') }
            else {
                $textFields = @(Get-BoardTextFields -TemplateKey $key)
                if ($textFields.Count -lt 1) { $reason = (T 'board.noTextField') }
            }
            [pscustomobject]@{
                Key = $key
                Layer = [int](Get-JsonProp $template 'Layer')
                Usable = [string]::IsNullOrEmpty($reason)
                Reason = $reason
                TextFields = $textFields
            }
        })
}

function Test-BoardEditAllowed {
    <# Who may change the rows, in the bridge's own permission words. The
       operator always orders, enables and shows; editing is what EditRole
       governs. #>
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    switch ([string](Get-BoardProperty $Board 'EditRole' 'all')) {
        'owner' { return (Test-Owner -ChatId $ChatId -UserId $UserId) }
        'admin' { return (Test-Admin -ChatId $ChatId -UserId $UserId) }
        default { return $true }
    }
}

# ------------------------------------------------------------- live identity

function Get-BoardsLiveFile {
    return (Join-Path $script:logDir 'boards-live.json')
}

function Import-BoardsLive {
    <# Which row of which board is on each layer, restored at startup.

       Persisted for the reason the urgent board's manual state is: the
       operator was told a row is live and how to hide it, and a restart must
       not take that promise off air with no way back. #>
    $script:BoardsLive = @{}
    $path = Get-BoardsLiveFile
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $payload = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in @(Get-JsonProp $payload 'Layers')) {
            $layer = [int](Get-JsonProp $entry 'Layer')
            if ($layer -le 0) { continue }
            $script:BoardsLive[$layer] = @{
                BoardId = [string](Get-JsonProp $entry 'BoardId')
                ItemId = [string](Get-JsonProp $entry 'ItemId')
                At = [string](Get-JsonProp $entry 'At')
            }
        }
    }
    catch { Write-BridgeLog "Could not read boards-live.json: $($_.Exception.Message)" 'WARN' }
}

function Save-BoardsLive {
    $payload = [pscustomobject]@{
        SavedAt = [datetimeoffset]::Now.ToString('o')
        Layers = @($script:BoardsLive.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Layer = [int]$_.Key; BoardId = [string]$_.Value.BoardId; ItemId = [string]$_.Value.ItemId; At = [string]$_.Value.At }
            })
    }
    return [bool](Write-BridgeValidatedJson -Path (Get-BoardsLiveFile) -Json ($payload | ConvertTo-Json -Depth 6))
}

function Set-BoardItemLive {
    <#
        Keyed by LAYER, not by board.

        Two boards may be bound to templates sharing one layer, and showing the
        second replaces the first on screen. Keyed by board, both cards would go
        on claiming to be on air - and a card that lies about the air is worse
        than a card that says nothing.
    #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][string]$BoardId, [Parameter(Mandatory)][string]$ItemId)
    $script:BoardsLive[$Layer] = @{ BoardId = $BoardId; ItemId = $ItemId; At = [datetimeoffset]::Now.ToString('o') }
    Save-BoardsLive | Out-Null
}

function Clear-BoardItemLive {
    param([Parameter(Mandatory)][int]$Layer)
    if ($script:BoardsLive.ContainsKey($Layer)) {
        $script:BoardsLive.Remove($Layer) | Out-Null
        Save-BoardsLive | Out-Null
    }
}

function Test-BoardItemLive {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][string]$BoardId, [Parameter(Mandatory)][string]$ItemId)
    if (-not $script:BoardsLive.ContainsKey($Layer)) { return $false }
    $live = $script:BoardsLive[$Layer]
    if ([string]$live.BoardId -ne $BoardId -or [string]$live.ItemId -ne $ItemId) { return $false }
    # The bridge's own record of the layer is the second half of the answer: a
    # row marked live on a layer nothing is on air on is a stale promise.
    return $script:OnAir.ContainsKey($Layer)
}

# -------------------------------------------------------------------- the air

function Show-BoardItemOnAir {
    <#
        One prepared row onto its programme's scene.

        Through Invoke-ShowTemplateResult, not around it. Everything that makes
        a SHOW safe on this bridge lives in that funnel, and a second door into
        Cinegy is a second place for every one of those rules to be forgotten.
    #>
    param([Parameter(Mandatory)][string]$BoardId, [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $board = Get-ContentBoard -BoardId $BoardId
    if (-not $board) { return $false }
    $item = Get-BoardItem -Board $board -ItemId $ItemId
    if (-not $item) { return $false }
    if (-not [bool](Get-BoardProperty $item 'Enabled' $true)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'board.rowDisabled')
        return $false
    }
    $key = [string](Get-BoardProperty $board 'TemplateKey' '')
    $template = (Get-TemplateStore).Map[$key]
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'board.templateGone' $key)
        return $false
    }
    $fields = @(Get-BoardTextFields -TemplateKey $key)
    $values = Get-BoardItemValues -Item $item -TextFields $fields
    $result = Invoke-ShowTemplateResult -Key $key -Variables $values -ChatId $ChatId -UserId $UserId
    if (-not $result -or -not $result.Success) { return $false }
    Set-BoardItemLive -Layer ([int]$template.Layer) -BoardId $BoardId -ItemId $ItemId
    return $true
}

# -------------------------------------------------------------------- screens

function Get-BoardsPageSize {
    # A constant, not a setting. Eight rows is what fits a phone screen beside
    # the navigation, and a knob nobody asked for is a knob to keep registered
    # in four places for ever.
    return 8
}

function Get-BoardsKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $boards = @(Get-ContentBoards)
    $window = Get-BridgePageWindow -ItemCount $boards.Count -Page $Page -PageSize (Get-BoardsPageSize)
    $rows = @()
    if ($boards.Count -gt 0) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $board = $boards[$index]
            $count = @(Get-BoardProperty $board 'Items' @()).Count
            $rows += , @( (New-Button "🗂 $([string](Get-BoardProperty $board 'Name' '')) · $count" "boards:b:$([string](Get-BoardProperty $board 'Id' ''))" -MaxTextLength 64) )
        }
    }
    if ($window.PageCount -gt 1) {
        $navigation = @()
        if ($window.HasPrevious) { $navigation += (New-Button (T 'common.previous') "boards:page:$($window.Page - 1)") }
        if ($window.HasNext) { $navigation += (New-Button (T 'common.next') "boards:page:$($window.Page + 1)") }
        $rows += , $navigation
    }
    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $rows += , @( (New-Button (T 'boards.new') 'boards:new' -Style success) )
    }
    $rows += , @( (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Show-BoardsScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $boards = @(Get-ContentBoards)
    $lines = @("<b>$(T 'boards.title')</b>", '')
    if ($boards.Count -eq 0) {
        $lines += (T 'boards.empty')
        $lines += ''
        $lines += (T 'boards.empty.bound')
        $lines += (T 'boards.empty.steps')
        $lines += (T 'boards.empty.then')
    }
    else {
        $lines += (T 'boards.count' $boards.Count)
    }
    $text = $lines -join "`n"
    $keyboard = Get-BoardsKeyboard -ChatId $ChatId -UserId $UserId -Page $Page
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Get-BoardScreenKeyboard {
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $boardId = [string](Get-BoardProperty $Board 'Id' '')
    $items = @(Get-BoardProperty $Board 'Items' @())
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize (Get-BoardsPageSize)
    $fields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $Board 'TemplateKey' '')))
    $rows = @()
    if ($items.Count -gt 0) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $item = $items[$index]
            $first = if ($fields.Count -gt 0) { [string](Get-BoardProperty (Get-BoardProperty $item 'Values' $null) $fields[0] '') } else { '' }
            $mark = if ([bool](Get-BoardProperty $item 'Enabled' $true)) { '✅' } else { '🚫' }
            $rows += , @( (New-Button "$mark $($index + 1). $first" "boards:i:$boardId`:$([string](Get-BoardProperty $item 'Id' ''))" -MaxTextLength 64) )
        }
    }
    if ($window.PageCount -gt 1) {
        $navigation = @()
        if ($window.HasPrevious) { $navigation += (New-Button (T 'common.previous') "boards:bp:$boardId`:$($window.Page - 1)") }
        if ($window.HasNext) { $navigation += (New-Button (T 'common.next') "boards:bp:$boardId`:$($window.Page + 1)") }
        $rows += , $navigation
    }
    if (Test-BoardEditAllowed -Board $Board -ChatId $ChatId -UserId $UserId) {
        $rows += , @( (New-Button (T 'boards.addRow') "boards:add:$boardId"), (New-Button (T 'boards.paste') "boards:paste:$boardId") )
    }
    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $roleLabel = switch ([string](Get-BoardProperty $Board 'EditRole' 'all')) {
            'owner' { T 'boards.role.owner' }
            'admin' { T 'boards.role.admin' }
            default { T 'boards.role.all' }
        }
        $rows += , @( (New-Button (T 'boards.role.button' $roleLabel) "boards:role:$boardId") )
        $rows += , @( (New-Button (T 'boards.delete') "boards:del:$boardId" -Style danger) )
    }
    $rows += , @( (New-Button (T 'boards.list') 'boards:open'), (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Get-BoardScreenBlocks {
    <# A board's rows as a table - number, its first two fields, on or off -
       where the buttons below could each show only the first field. #>
    param([Parameter(Mandatory)]$Board, [string]$Header)
    $blocks = @(@{ type = 'paragraph'; text = (ConvertFrom-TelegramHtmlText $Header) })
    $items = @(Get-BoardProperty $Board 'Items' @())
    if ($items.Count -eq 0) { return $blocks }
    $fields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $Board 'TemplateKey' '')) | Select-Object -First 2)
    $head = @( @{ text = '#'; is_header = $true } )
    foreach ($field in $fields) { $head += @{ text = [string]$field; is_header = $true } }
    $head += @{ text = '✅'; is_header = $true }
    $cells = @(, $head)
    $shown = @($items | Select-Object -First 40)
    for ($i = 0; $i -lt $shown.Count; $i++) {
        $values = Get-BoardProperty $shown[$i] 'Values' $null
        $row = @( @{ text = [string]($i + 1) } )
        foreach ($field in $fields) { $row += @{ text = (Get-NewsScreenLine -Text ([string](Get-BoardProperty $values $field '')) -Length 40) } }
        $row += @{ text = $(if ([bool](Get-BoardProperty $shown[$i] 'Enabled' $true)) { '✅' } else { '🚫' }) }
        $cells += , $row
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    if ($items.Count -gt $shown.Count) { $blocks += @{ type = 'paragraph'; text = (T 'news.table.firstOnly' $shown.Count ($items.Count - $shown.Count)) } }
    return $blocks
}

function Show-BoardScreen {
    param([Parameter(Mandatory)][string]$BoardId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $board = Get-ContentBoard -BoardId $BoardId
    if (-not $board) { Show-BoardsScreen -ChatId $ChatId -UserId $UserId -MessageId $MessageId; return }
    $key = [string](Get-BoardProperty $board 'TemplateKey' '')
    $items = @(Get-BoardProperty $board 'Items' @())
    $lines = @("🗂 <b>$(ConvertTo-TelegramHtmlText ([string](Get-BoardProperty $board 'Name' '')))</b>", '')
    $template = (Get-TemplateStore).Map[$key]
    if (-not $template) {
        # The board is kept, not deleted: a producer's texts are not thrown away
        # because somebody edited the template registry.
        $lines += (T 'boards.templateGone' (ConvertTo-TelegramHtmlText $key))
    }
    else {
        $fields = @(Get-BoardTextFields -TemplateKey $key)
        # The template is the whole contract of the board: it decides which
        # fields a row has and which layer the row goes out on. Naming the
        # fields - not just counting them - is what tells a producer what they
        # are being asked to write before they write it.
        $lines += (T 'boards.template' (ConvertTo-TelegramHtmlText $key) ([int]$template.Layer))
        if ($fields.Count -gt 0) {
            $lines += (T 'boards.fields' $fields.Count (ConvertTo-TelegramHtmlText ($fields -join ' · ')))
        }
        $lines += (T 'boards.templateFixed')
        $lines += (T 'boards.rows' $items.Count (Get-SettingInt 'BoardMaxItems' 1))
    }
    $text = $lines -join "`n"
    $keyboard = Get-BoardScreenKeyboard -Board $board -ChatId $ChatId -UserId $UserId -Page $Page
    if ($MessageId -gt 0) { $script:RefreshTarget = @{ ChatId = $ChatId; MessageId = $MessageId } }
    if ($template -and (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-BoardScreenBlocks -Board $board -Header $text) -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Get-BoardItemKeyboard {
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)]$Item, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $boardId = [string](Get-BoardProperty $Board 'Id' '')
    $itemId = [string](Get-BoardProperty $Item 'Id' '')
    $key = [string](Get-BoardProperty $Board 'TemplateKey' '')
    $template = (Get-TemplateStore).Map[$key]
    $layer = if ($template) { [int]$template.Layer } else { 0 }
    $rows = @()
    if ($template) {
        if ($layer -gt 0 -and (Test-BoardItemLive -Layer $layer -BoardId $boardId -ItemId $itemId)) {
            $rows += , @( (New-Button (T 'boards.live') 'boards:noop' -Style primary), (New-Button (T 'boards.hide') "boards:hide:$boardId`:$itemId" -Style danger) )
        }
        else {
            $rows += , @( (New-Button (T 'board.showNow') "boards:show:$boardId`:$itemId" -Style success) )
        }
    }
    if (Test-BoardEditAllowed -Board $Board -ChatId $ChatId -UserId $UserId) {
        $fieldIndex = -1
        foreach ($field in @(Get-BoardTextFields -TemplateKey $key)) {
            $fieldIndex++
            # Addressed by POSITION, not by name: a scene variable is free text
            # and 'Ajel.center' in Arabic-sized company would push this past the
            # 64-byte callback cap. The handler resolves the index against the
            # same list this row was drawn from.
            $rows += , @( (New-Button "✏️ $field" "boards:f:$boardId`:$itemId`:$fieldIndex" -MaxTextLength 64) )
        }
    }
    $enabled = [bool](Get-BoardProperty $Item 'Enabled' $true)
    $stateRow = @( (New-Button $(if ($enabled) { (T 'board.disable') } else { (T 'urgent.enable') }) "boards:en:$boardId`:$itemId") )
    if (Test-BoardEditAllowed -Board $Board -ChatId $ChatId -UserId $UserId) {
        $stateRow += (New-Button (T 'common.delete') "boards:rm:$boardId`:$itemId" -Style danger)
    }
    $rows += , $stateRow
    $rows += , @( (New-Button '⬆️' "boards:mv:$boardId`:$itemId`:-1"), (New-Button '⬇️' "boards:mv:$boardId`:$itemId`:1") )
    $rows += , @( (New-Button (T 'board.backToBoard') "boards:b:$boardId"), (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Show-BoardItemScreen {
    param([Parameter(Mandatory)][string]$BoardId, [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $board = Get-ContentBoard -BoardId $BoardId
    if (-not $board) { Show-BoardsScreen -ChatId $ChatId -UserId $UserId -MessageId $MessageId; return }
    $item = Get-BoardItem -Board $board -ItemId $ItemId
    if (-not $item) { Show-BoardScreen -BoardId $BoardId -ChatId $ChatId -UserId $UserId -MessageId $MessageId; return }
    $key = [string](Get-BoardProperty $board 'TemplateKey' '')
    $position = Get-BoardItemPosition -Board $board -ItemId $ItemId
    $total = @(Get-BoardProperty $board 'Items' @()).Count
    $lines = @((T 'board.rowOf' $(if ([bool](Get-BoardProperty $item 'Enabled' $true)) { '✅' } else { '🚫' }) $($position + 1) $total), '')
    $values = Get-BoardProperty $item 'Values' $null
    foreach ($field in @(Get-BoardTextFields -TemplateKey $key)) {
        $value = [string](Get-BoardProperty $values $field '')
        $shown = if ($value) { ConvertTo-TelegramHtmlText $value } else { (T 'board.empty') }
        $lines += "• <b>$(ConvertTo-TelegramHtmlText $field)</b>: $shown"
    }
    # Listed, never editable, and said out loud. Silence here would read as a
    # forgotten feature; the scene keeps its own picture on purpose.
    $media = @(Get-BoardMediaFields -TemplateKey $key)
    if ($media.Count -gt 0) {
        $lines += ''
        $lines += (T 'board.fromScene' $(ConvertTo-TelegramHtmlText ($media -join (T 'common.comma'))))
    }
    $orphans = @(Get-BoardOrphanFields -Item $item -TextFields @(Get-BoardTextFields -TemplateKey $key))
    if ($orphans.Count -gt 0) {
        $lines += ''
        $lines += (T 'boards.orphan' (ConvertTo-TelegramHtmlText ($orphans -join (T 'common.comma'))))
    }
    $ceiling = Get-EffectiveAutoHideSeconds -Key $key -RequestedSeconds 0
    if ($ceiling -gt 0) {
        $lines += ''
        $lines += (T 'boards.autoHide' $ceiling)
    }
    $text = $lines -join "`n"
    $keyboard = Get-BoardItemKeyboard -Board $board -Item $item -ChatId $ChatId -UserId $UserId
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Get-BoardTemplatePickerKeyboard {
    param([int]$Page = 0)
    $candidates = @(Get-BoardEligibleTemplates)
    $window = Get-BridgePageWindow -ItemCount $candidates.Count -Page $Page -PageSize (Get-BoardsPageSize)
    $rows = @()
    if ($candidates.Count -gt 0) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $candidate = $candidates[$index]
            # By absolute index, not by key: a template key is free text and an
            # Arabic one is two bytes a character against a 64-byte cap.
            $label = if ($candidate.Usable) { T 'boards.picker.usable' $candidate.Key @($candidate.TextFields).Count } else { T 'boards.picker.unusable' $candidate.Key }
            $rows += , @( (New-Button $label "boards:pick:$index" -MaxTextLength 64) )
        }
    }
    if ($window.PageCount -gt 1) {
        $navigation = @()
        if ($window.HasPrevious) { $navigation += (New-Button (T 'common.previous') "boards:pickp:$($window.Page - 1)") }
        if ($window.HasNext) { $navigation += (New-Button (T 'common.next') "boards:pickp:$($window.Page + 1)") }
        $rows += , $navigation
    }
    $rows += , @( (New-Button (T 'common.cancel') 'boards:open') )
    return @{ inline_keyboard = $rows }
}

function Show-BoardTemplatePicker {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0, [int]$MessageId = 0)
    $candidates = @(Get-BoardEligibleTemplates)
    $lines = @((T 'boards.picker.title'), '')
    $lines += (T 'boards.picker.decides')
    $lines += (T 'boards.picker.fields')
    $lines += (T 'boards.picker.fixed')
    if (@($candidates | Where-Object { -not $_.Usable }).Count -gt 0) { $lines += '' }
    foreach ($candidate in @($candidates | Where-Object { -not $_.Usable })) {
        $lines += "⛔ $(ConvertTo-TelegramHtmlText $candidate.Key): $(ConvertTo-TelegramHtmlText $candidate.Reason)"
    }
    $text = $lines -join "`n"
    $keyboard = Get-BoardTemplatePickerKeyboard -Page $Page
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

# ------------------------------------------------------------ typed input

function Complete-BoardText {
    <#
        A producer's typed value, for whichever prompt is open.

        One entry point for every board text mode, the way the breaking-news
        board has one: a second dispatcher is a second place to forget a mode.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return $false }
    $mode = [string](Get-JsonProp $state 'Mode')
    $boardId = [string](Get-JsonProp $state 'BoardId')
    $board = if ($boardId) { Get-ContentBoard -BoardId $boardId } else { $null }
    Clear-PendingState -ChatId $ChatId

    if ($mode -eq 'board_new_name') {
        # The template was chosen first and carried on the state, so the name is
        # the last thing asked and the board exists the moment it is answered.
        $result = New-ContentBoard -Name $Value -TemplateKey ([string](Get-JsonProp $state 'TemplateKey')) -UserId $UserId
        if (-not $result.Success) {
            Send-TelegramMessage -ChatId $ChatId -Text "⛔ $($result.Error)"
            Show-BoardsScreen -ChatId $ChatId -UserId $UserId
            return $false
        }
        if (-not (Save-ContentBoard -Board $result.Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'board.saveFailed')
            return $false
        }
        Add-AuditEntry (T 'board.created' $([string]$result.Value.Name) $(Format-UserAuditActor -UserId $UserId))
        Show-BoardScreen -BoardId ([string]$result.Value.Id) -ChatId $ChatId -UserId $UserId
        return $true
    }

    if (-not $board) { Show-BoardsScreen -ChatId $ChatId -UserId $UserId; return $false }
    if (-not (Test-BoardEditAllowed -Board $board -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'board.notYoursToEdit')
        return $false
    }
    $fields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $board 'TemplateKey' '')))
    $maxLength = Get-SettingInt 'MaxFieldLength' 1
    $result = $null
    # ➕ add takes a paste too. It already split one into rows and kept the
    # first, dropping the others without a word; several rows now go the
    # paste path, which adds each, counts them and names what it skipped.
    if ($mode -eq 'board_add' -and @((ConvertFrom-BoardPasteText -Text $Value -TextFields $fields).Rows).Count -gt 1) { $mode = 'board_paste' }
    # A paste is reviewed before it is added, from either button.
    if ($mode -eq 'board_paste') {
        Start-RowPasteReview -ChatId $ChatId -UserId $UserId -Kind board -Target $boardId -Text $Value
        return $true
    }

    switch ($mode) {
        'board_add' {
            # A single-field scene takes the whole message as the one value; a
            # multi-field one reads the same pipe-separated shape as the paste,
            # so a producer learns one convention rather than two.
            $parsed = ConvertFrom-BoardPasteText -Text $Value -TextFields $fields
            if (@($parsed.Rows).Count -lt 1) {
                Send-TelegramMessage -ChatId $ChatId -Text (T 'board.needOneField')
                Show-BoardScreen -BoardId $boardId -ChatId $ChatId -UserId $UserId
                return $false
            }
            $result = Add-BoardItem -Board $board -Values $parsed.Rows[0] -TextFields $fields -UserId $UserId `
                -MaxItems (Get-SettingInt 'BoardMaxItems' 1) -MaxFieldLength $maxLength
        }
        'board_field' {
            $index = [int](Get-JsonProp $state 'FieldIndex')
            if ($index -lt 0 -or $index -ge $fields.Count) {
                Send-TelegramMessage -ChatId $ChatId -Text (T 'board.fieldGone')
                Show-BoardScreen -BoardId $boardId -ChatId $ChatId -UserId $UserId
                return $false
            }
            $result = Set-BoardItemField -Board $board -ItemId ([string](Get-JsonProp $state 'ItemId')) `
                -Field $fields[$index] -Value $Value -TextFields $fields -UserId $UserId -MaxFieldLength $maxLength
        }
    }

    if (-not $result) { Show-BoardScreen -BoardId $boardId -ChatId $ChatId -UserId $UserId; return $false }
    if (-not $result.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ $($result.Error)"
        Show-BoardScreen -BoardId $boardId -ChatId $ChatId -UserId $UserId
        return $false
    }
    if (-not (Save-ContentBoard -Board $result.Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'board.saveFailed')
        return $false
    }
    Show-BoardScreen -BoardId $boardId -ChatId $ChatId -UserId $UserId
    return $true
}

function Add-BoardPastedRows {
    <# The rows of a confirmed board paste, added in order and saved once.
       Stops at the first refusal and says which, rather than skipping on. #>
    param([Parameter(Mandatory)]$Board, [object[]]$Rows, [string[]]$Fields, [long]$UserId)
    $added = 0; $working = $Board; $stopped = ''
    foreach ($row in @($Rows)) {
        $attempt = Add-BoardItem -Board $working -Values $row -TextFields $Fields -UserId $UserId `
            -MaxItems (Get-SettingInt 'BoardMaxItems' 1) -MaxFieldLength (Get-SettingInt 'MaxFieldLength' 1)
        if (-not $attempt.Success) { $stopped = [string]$attempt.Error; break }
        $working = $attempt.Value; $added++
    }
    if ($added -gt 0 -and -not (Save-ContentBoard -Board $working)) { return [pscustomobject]@{ Added = 0; Stopped = (T 'board.saveFailed') } }
    return [pscustomobject]@{ Added = $added; Stopped = $stopped }
}

function ConvertFrom-RowPasteText {
    <# One parser per kind, one review for both. #>
    param([Parameter(Mandatory)][hashtable]$State, [AllowEmptyString()][string]$Text)
    if ([string]$State.Kind -eq 'mojaz') { return (ConvertFrom-MojazPasteText -Text $Text) }
    $board = Get-ContentBoard -BoardId ([string]$State.Target)
    $fields = if ($board) { @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $board 'TemplateKey' ''))) } else { @() }
    return (ConvertFrom-BoardPasteText -Text $Text -TextFields $fields)
}

function Start-RowPasteReview {
    <#
        A paste of several rows - a programme board's or the bulletin's -
        reviewed before anything is added, as the ticker's has been since
        8.69.8: a paste is where a slip of the thumb puts thirty lines of
        somebody's chat on a board. Text that arrives while it is open joins
        it, because Telegram splits a paste past 4096 characters.
    #>
    param([long]$ChatId, [long]$UserId, [ValidateSet('board', 'mojaz')][string]$Kind, [string]$Target, [AllowEmptyString()][string]$Text = '')
    $state = @{ Mode = 'row_paste_review'; Kind = $Kind; Target = $Target; UserId = $UserId; StartedAt = (Get-Date); Rows = @(); Skipped = @(); MessageId = 0 }
    Set-PendingState -ChatId $ChatId -State $state | Out-Null
    if ($Text) { Add-RowPasteChunk -ChatId $ChatId -UserId $UserId -Value $Text }
}

function Add-RowPasteChunk {
    param([long]$ChatId, [long]$UserId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'row_paste_review' -or [long]$state.UserId -ne $UserId) { return }
    $parsed = ConvertFrom-RowPasteText -State $state -Text $Value
    $state.Rows = @(@($state.Rows) + @($parsed.Rows))
    $state.Skipped = @(@($state.Skipped) + @($parsed.Skipped))
    $state.StartedAt = Get-Date
    Show-RowPasteReview -ChatId $ChatId
}

function Get-RowPastePreview {
    param([hashtable]$Row)
    $values = @(foreach ($key in @($Row.Keys | Sort-Object)) { [string]$Row[$key] } ) | Where-Object { $_ }
    return (Get-NewsPasteSnippet -Text ($values -join ' · ') -Length 60)
}

function Show-RowPasteReview {
    param([long]$ChatId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'row_paste_review') { return }
    $rows = @($state.Rows)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'rows.paste.found' $rows.Count))
    if (@($state.Skipped).Count -gt 0) { $lines.Add((T 'board.skipped' @($state.Skipped).Count (ConvertTo-TelegramHtmlText ([string]@($state.Skipped)[0])))) }
    if ($rows.Count -gt 0) {
        $lines.Add('')
        $n = 0
        foreach ($row in @($rows | Select-Object -First 5)) { $n++; $lines.Add("$n. $(Get-RowPastePreview -Row $row)") }
        if ($rows.Count -gt 5) { $lines.Add((T 'news.paste.more' ($rows.Count - 5))) }
    }
    $lines.Add('')
    $lines.Add((T 'news.paste.keepSending'))
    $keyboard = @()
    if ($rows.Count -gt 0) { $keyboard += , @( @{ text = (T 'rows.paste.confirm' $rows.Count); callback_data = 'rows:pasteok'; style = 'success' } ) }
    $keyboard += , @( @{ text = (T 'reply.cancelWord'); callback_data = 'rows:pastecancel' } )
    $markup = @{ inline_keyboard = $keyboard }
    $text = $lines -join "`n"
    $messageId = [int]$state.MessageId
    if ($messageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $messageId -Text $text -ReplyMarkup $markup -ParseMode HTML)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $markup | Out-Null
    $state.MessageId = [int]$script:LastTelegramMessageId
}

function Complete-RowPaste {
    <# The review's buttons. The target is re-read and re-checked here: a
       board's editors or a bulletin's existence can change while it waits. #>
    param([long]$ChatId, [long]$UserId, [switch]$Cancel)
    $state = Get-PendingState -ChatId $ChatId
    $mine = $state -and [string]$state.Mode -eq 'row_paste_review' -and [long]$state.UserId -eq $UserId
    if ($mine) { Clear-PendingState -ChatId $ChatId }
    if ($Cancel -or -not $mine) {
        Send-TelegramMessage -ChatId $ChatId -Text $(if ($Cancel) { (T 'news.paste.cancelled') } else { (T 'news.paste.gone') })
        return
    }
    $rows = @($state.Rows)
    if ([string]$state.Kind -eq 'mojaz') {
        $bulletinId = [string]$state.Target
        $library = $script:MojazLibrary; $added = 0; $failed = ''
        foreach ($row in $rows) {
            $attempt = Add-MojazBulletinRow -Library $library -BulletinId $bulletinId -Title ([string]$row.Title) -Text ([string]$row.Text) -ImageMode inherit -UserId $UserId
            if (-not $attempt.Success) { $failed = [string]$attempt.Error; break }
            $library = $attempt.Value; $added++
        }
        if ($added -gt 0 -and -not (Invoke-MojazEdit -Result ([pscustomobject]@{ Success = $true; Value = $library; Error = '' }) -ChatId $ChatId)) { $added = 0 }
        $report = @((T 'board.rowsAdded' $added))
        if ($failed) { $report += (T 'board.stopped' (ConvertTo-TelegramHtmlText $failed)) }
        if ($added -gt 0) { Add-AuditEntry (T 'mjz.rowAddedAudit' $(Format-UserAuditActor -UserId $UserId)) }
        Send-TelegramMessage -ChatId $ChatId -Text ($report -join "`n")
        $script:MojazSelections[[string]$ChatId] = $bulletinId
        Show-MojazScreen -ChatId $ChatId -UserId $UserId
        return
    }
    $board = Get-ContentBoard -BoardId ([string]$state.Target)
    if (-not $board -or -not (Test-BoardEditAllowed -Board $board -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'board.notYoursToEdit'); return
    }
    $fields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $board 'TemplateKey' '')))
    $outcome = Add-BoardPastedRows -Board $board -Rows $rows -Fields $fields -UserId $UserId
    $report = @((T 'board.rowsAdded' $outcome.Added))
    if ($outcome.Stopped) { $report += (T 'board.stopped' (ConvertTo-TelegramHtmlText $outcome.Stopped)) }
    Send-TelegramMessage -ChatId $ChatId -Text ($report -join "`n")
    Show-BoardScreen -BoardId ([string]$state.Target) -ChatId $ChatId -UserId $UserId
}

function Invoke-BoardEdit {
    <# Save a domain result and redraw, or say why it was refused. One place, so
       nine callbacks do not each invent their own way of failing. #>
    param($Result, [Parameter(Mandatory)][string]$BoardId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$MessageId = 0, [string]$ItemId = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $Result -or -not $Result.Success) {
        if ($Result) { Send-TelegramMessage -ChatId $ChatId -Text "⛔ $($Result.Error)" }
        return $false
    }
    if (-not (Save-ContentBoard -Board $Result.Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'board.saveFailed')
        return $false
    }
    if ($ItemId -and (Get-BoardItem -Board $Result.Value -ItemId $ItemId)) {
        Show-BoardItemScreen -BoardId $BoardId -ItemId $ItemId -ChatId $ChatId -UserId $UserId -MessageId $MessageId
    }
    else { Show-BoardScreen -BoardId $BoardId -ChatId $ChatId -UserId $UserId -MessageId $MessageId }
    return $true
}
