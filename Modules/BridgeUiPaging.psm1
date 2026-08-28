Set-StrictMode -Version Latest

function Get-BridgePageWindow {
    [CmdletBinding()]
    param(
        [ValidateRange(0, [int]::MaxValue)][int]$ItemCount,
        [int]$Page = 0,
        [ValidateRange(1, 100)][int]$PageSize = 20
    )

    $pageCount = [math]::Max(1, [int][math]::Ceiling($ItemCount / [double]$PageSize))
    $safePage = [math]::Max(0, [math]::Min($Page, $pageCount - 1))
    $start = if ($ItemCount -eq 0) { 0 } else { $safePage * $PageSize }
    $end = if ($ItemCount -eq 0) { -1 } else { [math]::Min($start + $PageSize - 1, $ItemCount - 1) }
    return [pscustomobject]@{
        Page = $safePage
        PageCount = $pageCount
        StartIndex = $start
        EndIndex = $end
        HasPrevious = $safePage -gt 0
        HasNext = $safePage + 1 -lt $pageCount
    }
}

Export-ModuleMember -Function Get-BridgePageWindow
