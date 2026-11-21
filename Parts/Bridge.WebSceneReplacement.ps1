#requires -Version 7
$script:WebTemplateSceneChoices = @{}
$script:WebTemplateSceneReviews = @{}

function Get-WebSceneReplacementArtifact {
    # This function is copied into the existing catalogue worker. Its output
    # is metadata only. Parse and hash the same bytes with writes excluded.
    param([string]$Root, [string]$RelativePath, [string]$SceneModule)

    $scene = Get-WebSceneItem -Root $Root -RelativePath $RelativePath
    if (-not $scene -or $scene.PSIsContainer -or $scene.Extension -ine '.cintitle' -or
        [Environment]::ExpandEnvironmentVariables($scene.FullName) -cne $scene.FullName) { return @{ error = 'scene_not_found' } }
    $stream = $null
    $buffer = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($scene.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -le 0 -or $stream.Length -gt 16MB) { return @{ error = 'scene_replacement_size' } }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes, 0, $bytes.Length)
        $buffer = [IO.MemoryStream]::new($bytes, $false)
        $options = [Xml.XmlReaderSettings]::new()
        $options.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $options.XmlResolver = $null
        $options.IgnoreComments = $true
        $options.MaxCharactersInDocument = 16MB
        $reader = [Xml.XmlReader]::Create($buffer, $options)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        if (@($document.SelectNodes('//*[local-name()="Scene"]')).Count -ne 1) { return @{ error = 'scene_replacement_format' } }
        Import-Module -Name $SceneModule -ErrorAction Stop
        return @{
            FullName = $scene.FullName
            Digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            Fields = @(Get-BridgeSceneFields -Xml $document.OuterXml)
        }
    }
    catch { return @{ error = 'scene_replacement_format' } }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($buffer) { $buffer.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-WebSceneReplacementMismatch {
    param([hashtable]$Template, [object[]]$Fields)

    $overrides = Get-TemplateFieldTypeOverrides -Template $Template
    $defaultType = [string](Get-Setting 'AirVariableType')
    foreach ($name in $Template.Fields) {
        $consumers = @($Fields | Where-Object { $_.Name -ceq $name -and $_.Consumed })
        if ($consumers.Count -ne 1) { $name; continue }
        $expected = $overrides[$name] ?? $defaultType
        $actual = [string]$consumers[0].Type
        $textCompatible = $expected -in 'Text', 'String' -and $actual -in 'Text', 'String' -and $consumers[0].Kind -eq 'text'
        $typedCompatible = $expected -in 'Bool', 'Float' -and $actual -eq $expected -and $consumers[0].Kind -eq 'text'
        $mediaCompatible = $expected -eq 'File' -and $consumers[0].Kind -eq 'media' -and $actual -in 'File', 'String', 'Text'
        if (-not ($textCompatible -or $typedCompatible -or $mediaCompatible)) { $name }
    }
}

function Invoke-WebTemplateSceneRequest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [hashtable]$Entry)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $key = [string](Get-JsonProp $Arguments 'key')
    if (-not $key -or $action -cnotin 'inspect', 'select', 'preview', 'apply') { return @{ ok = $false; error = 'scene_definition_invalid' } }
    $template = (Get-TemplateStore).Map[$key]
    if (-not $template) { return @{ ok = $false; error = 'scene_not_found' } }
    $key = [string]$template.Key
    $layer = [int]$template.Layer
    if (-not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $revision = [string](Get-JsonProp $template 'PresetRevision')
    $stale = @{ ok = $false; error = 'scene_registry_stale' }
    if (-not $revision -or $revision -cne (Get-TemplatePresetRegistryRevision -TemplateKey $key)) { return $stale }
    if ($action -ceq 'inspect') {
        return @{ ok = $true; data = @{ current = @{
                    key = $key; file = [IO.Path]::GetFileName([string]$template.Path); layer = $layer; revision = $revision
                    presetCount = @(Get-JsonProp $template 'Presets').Count
                } } }
    }
    if ($revision -cne [string](Get-JsonProp $Arguments 'revision')) { return $stale }
    if ($script:WebSceneRequest -or [Diagnostics.Stopwatch]::GetTimestamp() -ge $Entry.Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $root = Get-WebSceneCatalogueRoot
    if (-not [IO.Path]::IsPathFullyQualified($root)) { return @{ ok = $false; error = 'scene_folder_missing' } }
    $selectionToken = [string](Get-JsonProp $Arguments 'selection')
    $reviewToken = [string](Get-JsonProp $Arguments 'review')
    $relativePath = [string](Get-JsonProp $Arguments 'file')
    if ($action -cne 'select') {
        $choice = $script:WebTemplateSceneChoices[$actor]
        if (-not $choice -or $choice.Token -cne $selectionToken -or $choice.ExpiresAt -le [datetimeoffset]::UtcNow -or
            $choice.Key -cne $key -or $choice.Revision -cne $revision -or $choice.Root -cne $root) { return $stale }
        $relativePath = $choice.RelativePath
    }
    if ($action -ceq 'apply') {
        $issued = $script:WebTemplateSceneReviews[$actor]
        if (-not $issued -or $issued.Token -cne $reviewToken -or $issued.ExpiresAt -le [datetimeoffset]::UtcNow) { return $stale }
    }
    $query = @{
        Action = "replace-$action"; RelativePath = $relativePath; Key = $key; Revision = $revision
        Selection = $selectionToken; Review = $reviewToken; SceneModule = Join-Path $moduleRoot 'BridgeMojaz.psm1'
    }
    return Start-WebSceneWorker -Entry $Entry -Root $root -Actor $actor -Query $query
}

function Complete-WebTemplateSceneReplacement {
    param([hashtable]$Pending, [hashtable]$Scene)

    $actor = $Pending.Actor
    $query = $Pending.Query
    if (-not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $stale = @{ ok = $false; error = 'scene_registry_stale' }
    if ((Get-WebSceneCatalogueRoot) -cne $Pending.Root) { return $stale }
    $template = (Get-TemplateStore).Map[$query.Key]
    if (-not $template -or $query.Revision -cne [string]$template.PresetRevision -or
        $query.Revision -cne (Get-TemplatePresetRegistryRevision -TemplateKey $query.Key)) { return $stale }
    $layer = [int]$template.Layer
    if (-not (Test-TemplateAccess -Key $query.Key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $approval = if ($query.Action -ceq 'replace-apply') {
        Use-WebAirReview -Actor $actor -Token $query.Review -Reviews $script:WebTemplateSceneReviews
    }
    if ($query.Action -ceq 'replace-apply' -and -not $approval) { return $stale }
    $problem = [string](Get-JsonProp $Scene 'error')
    if ($problem) {
        if ($query.Action -cne 'replace-select') { return $stale }
        return @{ ok = $false; error = $problem }
    }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $Pending.Entry.Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if (-not $Scene.FullName -or -not $Scene.Digest -or [string]$template.Path -eq [string]$Scene.FullName) { return $stale }
    $fingerprint = ConvertTo-Json -Compress -InputObject @($query.Key, $query.Revision, $Pending.Root, $Scene.FullName, $Scene.Digest)
    if ($query.Action -ceq 'replace-select') {
        $incompatible = @(Get-WebSceneReplacementMismatch -Template $template -Fields $Scene.Fields)
        $handle = if (-not $incompatible.Count) {
            $choiceToken = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateSceneChoices
            $choice = $script:WebTemplateSceneChoices[$actor]
            $choice.Key = $query.Key
            $choice.Revision = $query.Revision
            $choice.Root = $Pending.Root
            $choice.RelativePath = $query.RelativePath
            $choiceToken
        }
        return @{ ok = $true; data = @{ selection = @{ handle = $handle; file = $query.RelativePath; incompatibleFields = $incompatible } } }
    }
    $approvedChoice = $script:WebTemplateSceneChoices[$actor]
    if (-not $approvedChoice -or $approvedChoice.Token -cne $query.Selection -or
        $approvedChoice.ExpiresAt -le [datetimeoffset]::UtcNow -or $approvedChoice.Fingerprint -cne $fingerprint) { return $stale }

    $blocker = Get-TemplateDefinitionBlocker -TemplateKey $query.Key -Delete
    if ($blocker -and $blocker -ne 'scene_definition_alias') { return @{ ok = $false; error = $blocker } }
    if ($query.Key -in $script:MojazTemplateKey, $script:MojazUrgentKey -or (Get-JsonProp $template 'Bulletin') -or
        [string](Get-Setting 'SceneMode') -eq 'Multi') { return @{ ok = $false; error = 'scene_replacement_managed' } }
    if (@(Get-WebSceneReplacementMismatch -Template $template -Fields $Scene.Fields).Count) {
        return @{ ok = $false; error = 'scene_replacement_incompatible' }
    }
    $device = (Resolve-AirGfxDevice -Layer $layer).StatusPath
    $live = Get-CinegyLayerReviewStamp -Status (Get-WebLayerStatus -Layer $layer)
    if (-not $live) { return @{ ok = $false; error = 'scene_replacement_unverified' } }
    if ($live -ne 'empty') { return @{ ok = $false; error = 'scene_definition_live' } }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $Pending.Entry.Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $reviewFingerprint = ConvertTo-Json -Compress -InputObject @($fingerprint, $query.Selection, $layer, $device, $live)
    if ($query.Action -ceq 'replace-preview') {
        $token = New-WebAirReview -Actor $actor -Fingerprint $reviewFingerprint -Reviews $script:WebTemplateSceneReviews
        return @{ ok = $true; data = @{ preview = @{
                    review = $token; key = $query.Key; layer = $layer
                    beforeFile = [IO.Path]::GetFileName([string]$template.Path); afterFile = $query.RelativePath
                    fields = @($template.Fields); presetCount = @(Get-JsonProp $template 'Presets').Count
                } } }
    }
    if ($approval.Fingerprint -cne $reviewFingerprint) { return $stale }
    $script:WebTemplateSceneChoices.Remove($actor) | Out-Null
    $saved = Save-TemplateDefinitionChange -TemplateKey $query.Key -Action edit -ExpectedRevision $query.Revision -Definition @{ path = $Scene.FullName }
    if (-not $saved.Success) {
        $code = [string](Get-JsonProp $saved 'Code')
        return @{ ok = $false; error = ($code ? $code : 'scene_registry_failed') }
    }
    Add-AuditEntry (T 'atpl.savedAudit' 'edit' $query.Key $(Format-UserAuditActor -UserId $actor))
    return @{ ok = $true; data = @{} }
}
