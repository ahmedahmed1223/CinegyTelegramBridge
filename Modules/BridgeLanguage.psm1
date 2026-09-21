#requires -Version 7
<#
    BridgeLanguage.psm1 - the bridge's text in both languages.

    WHY A CATALOGUE AND NOT A SECOND SET OF LITERALS

    The bridge grew with its Arabic written inline, which was right while the
    station that runs it is the only one reading the screens. Publishing it
    means a second reader, and the two ways to serve them are:

      - branch at every call site (`if ($lang -eq 'en') { ... } else { ... }`),
        which doubles every screen in place and guarantees the two halves
        drift the first time one is edited alone; or
      - name each piece of text once and hold both languages beside each
        other, where a missing translation is a fact a test can assert rather
        than a sentence somebody has to notice.

    This is the second. A key that lacks 'en' falls back to Arabic and says so
    once in the log - an operator reading one English screen with one Arabic
    line still knows what it says, while a screen that refuses to render
    because a key is missing takes the graphics with it.

    THE ARABIC LIVES HERE TOO, NOT AT THE CALL SITE

    Keeping the Arabic inline and passing only English here would leave the
    catalogue half-populated and the coverage test unable to see what it is
    missing. Both languages sit together so that reading one entry tells you
    whether it is finished.

    PLACEHOLDERS

    {0}, {1} ... are filled by Format-BridgeText through [string]::Format, so
    the two languages may put them in different places - which Arabic and
    English routinely need. A translation that drops a placeholder the Arabic
    uses is a silent hole, so Test-BridgeTextCatalogue reports it.
#>

Set-StrictMode -Version Latest

# The catalogue lives in Modules/BridgeText/, one file per domain. Dot-sourced
# rather than imported: these are partial definitions that fill one shared
# dictionary, not modules with a surface of their own.
foreach ($textFile in @('Common', 'Settings', 'Screens', 'Content', 'Alerts', 'Replies')) {
    . (Join-Path $PSScriptRoot "BridgeText\$textFile.ps1")
}

# Every language the bridge can be set to. Adding a third means adding its
# code here and a column in the catalogue; nothing else reads a hard-coded
# pair of names.
$script:BridgeLanguages = @('ar', 'en')
$script:BridgeDefaultLanguage = 'ar'

function Test-BridgeLanguage {
    param([string]$Language = '')
    return ($script:BridgeLanguages -contains ([string]$Language).ToLowerInvariant())
}

function Get-BridgeLanguages {
    return @($script:BridgeLanguages)
}

function Get-BridgeDefaultLanguage {
    return $script:BridgeDefaultLanguage
}

function New-BridgeTextCatalogue {
    <#
        The catalogue itself: key -> @{ ar = '...'; en = '...' }.

        Built by a function rather than held as a module variable so a test can
        take a fresh copy without the module's state leaking between cases.
    #>
    $catalogue = [ordered]@{}

    # One call per domain file in Modules/BridgeText/. A fifth domain means a
    # file and its name in this list; nothing else in the mechanism counts them.
    foreach ($section in @('Common', 'Settings', 'Screens', 'Content', 'Alerts', 'Replies')) {
        & "Add-BridgeText$section" -Catalogue $catalogue
    }

    return $catalogue
}

$script:BridgeTextCatalogue = New-BridgeTextCatalogue
$script:BridgeTextMissing = [System.Collections.Generic.HashSet[string]]::new()

function Get-BridgeTextEntry {
    <# The raw pair for a key, or $null. Exposed so a test can read the
       catalogue without going through the fallback path. #>
    param([Parameter(Mandatory)][string]$Key)
    if ($script:BridgeTextCatalogue.Contains($Key)) { return $script:BridgeTextCatalogue[$Key] }
    return $null
}

function Get-BridgeTextKeys {
    return @($script:BridgeTextCatalogue.Keys)
}

function Format-BridgeText {
    <#
        [string]::Format with the arguments the caller actually passed.

        A format string whose placeholders outnumber the arguments throws, and
        a screen that throws while an operator is mid-edit is worse than one
        that reads awkwardly - so the unformatted template is returned instead
        and the fault is logged by the caller's own logger, not swallowed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template, [object[]]$Arguments = @())
    if (@($Arguments).Count -eq 0) { return $Template }
    try { return [string]::Format([cultureinfo]::InvariantCulture, $Template, $Arguments) }
    catch { return $Template }
}

function Get-BridgeText {
    <#
        The text for a key in the requested language.

        An unknown key returns the key itself: it is visible, greppable, and
        cannot be mistaken for a sentence somebody wrote. A key that exists but
        has no translation in the requested language falls back to Arabic,
        because half a screen an operator can read beats a blank one.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Language = '',
        [object[]]$Arguments = @(),
        [AllowEmptyString()][string]$Fallback = $null
    )
    $entry = Get-BridgeTextEntry -Key $Key
    if (-not $entry) {
        [void]$script:BridgeTextMissing.Add($Key)
        # -Fallback is for text that ALREADY exists in Arabic somewhere else:
        # the setting labels and descriptions built at load, which are several
        # hundred strings that can only be translated a few at a time. Without
        # it every untranslated one would render as its key; with it, the
        # screen keeps saying exactly what it said before this feature existed.
        #
        # Asked of the bound parameters, not of the value: [string]$Fallback
        # coerces an unpassed $null to '', so "$null -ne $Fallback" is true
        # even when no fallback was given - and every unknown key came back as
        # an empty string instead of as its own name.
        if ($PSBoundParameters.ContainsKey('Fallback')) { return (Format-BridgeText -Template $Fallback -Arguments $Arguments) }
        return $Key
    }
    $code = ([string]$Language).ToLowerInvariant()
    if (-not (Test-BridgeLanguage -Language $code)) { $code = $script:BridgeDefaultLanguage }
    $template = if ($entry.Contains($code) -and -not [string]::IsNullOrEmpty([string]$entry[$code])) {
        [string]$entry[$code]
    }
    else {
        [void]$script:BridgeTextMissing.Add("$Key`:$code")
        [string]$entry[$script:BridgeDefaultLanguage]
    }
    return (Format-BridgeText -Template $template -Arguments $Arguments)
}

function Get-BridgeTextMisses {
    <# Keys asked for and not found, so a diagnostic screen can report a gap
       the catalogue test cannot see - one reached only at runtime. #>
    return @($script:BridgeTextMissing)
}

function Clear-BridgeTextMisses {
    $script:BridgeTextMissing.Clear()
}

function Get-BridgeTextPlaceholders {
    <# The distinct {N} indices a template uses, sorted. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)
    $found = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($match in [regex]::Matches($Template, '\{(\d+)\}')) {
        [void]$found.Add([int]$match.Groups[1].Value)
    }
    return @($found)
}

function Test-BridgeTextCatalogue {
    <#
        What is wrong with the catalogue, as data.

        Three faults, each of which reaches an operator as a broken screen:
        a key with no entry for a language; a translation that drops a
        placeholder the other language fills (so a layer number or a count
        simply vanishes from the sentence); and an empty string, which renders
        as a blank line rather than as the missing text it is.
    #>
    param($Catalogue = $null)
    if (-not $Catalogue) { $Catalogue = $script:BridgeTextCatalogue }
    $problems = @()
    foreach ($key in @($Catalogue.Keys)) {
        $entry = $Catalogue[$key]
        foreach ($language in $script:BridgeLanguages) {
            if (-not $entry.Contains($language)) {
                $problems += [pscustomobject]@{ Key = $key; Language = $language; Problem = 'missing' }
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry[$language])) {
                $problems += [pscustomobject]@{ Key = $key; Language = $language; Problem = 'empty' }
            }
        }
        $reference = @(Get-BridgeTextPlaceholders -Template ([string]$entry[$script:BridgeDefaultLanguage]))
        foreach ($language in $script:BridgeLanguages) {
            if ($language -eq $script:BridgeDefaultLanguage -or -not $entry.Contains($language)) { continue }
            $theirs = @(Get-BridgeTextPlaceholders -Template ([string]$entry[$language]))
            if (($reference -join ',') -ne ($theirs -join ',')) {
                $problems += [pscustomobject]@{ Key = $key; Language = $language; Problem = 'placeholders' }
            }
        }
    }
    return @($problems)
}

Export-ModuleMember -Function Test-BridgeLanguage, Get-BridgeLanguages, Get-BridgeDefaultLanguage,
New-BridgeTextCatalogue, Get-BridgeTextEntry, Get-BridgeTextKeys, Format-BridgeText, Get-BridgeText,
Get-BridgeTextMisses, Clear-BridgeTextMisses, Get-BridgeTextPlaceholders, Test-BridgeTextCatalogue
