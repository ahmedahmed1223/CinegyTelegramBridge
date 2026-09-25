#requires -Version 7
<#
    What a pasted string may not carry onto air, written once.

    Text copied out of WhatsApp, a browser or Word arrives with characters
    nobody typed. Direction marks and embeddings (U+200E/F, U+202A-E,
    U+2066-9) reorder the words on air; a BOM, zero-width space, word joiner
    or soft hyphen is invisible here and a gap or a stray glyph there.

    The ticker, the bulletin and the programme boards each take text for air,
    and the list of what to strip was going to be written three times - the
    guard AGENTS.md says drifts. So it lives here, and each module calls it.

    Line breaks are NOT folded here: a bulletin row or a board field may
    legitimately run to two lines on screen, and a ticker headline folds its
    own. U+200D stays, because it holds an emoji sequence together; U+200C
    stays for its meaning in Persian and Urdu.
#>

function Remove-BridgeInvisibleText {
    param([AllowEmptyString()][string]$Text = '')
    $clean = [regex]::Replace($Text, '[\u200B\u200E\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF\u00AD]', '')
    # Tabs and every horizontal space kind become an ordinary space, so a
    # non-breaking space cannot glue two words into one on the strap.
    return [regex]::Replace($clean, '[\t\p{Zs}]', ' ')
}

Export-ModuleMember -Function Remove-BridgeInvisibleText
