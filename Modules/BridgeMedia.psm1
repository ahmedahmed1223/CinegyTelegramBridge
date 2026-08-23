Set-StrictMode -Version Latest

function ConvertTo-BridgeProcessArgumentLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    $quoted=foreach($arg in $Arguments){
        if($null -eq $arg -or $arg -eq ''){'""'}
        elseif($arg -notmatch '[\s"]'){$arg}
        else{
            $escaped=[regex]::Replace($arg,'(\\*)"','$1$1\"')
            $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
            '"'+$escaped+'"'
        }
    }
    return $quoted -join ' '
}

function Get-BridgeFfmpegInputArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceType,[Parameter(Mandatory)][string]$SourceUrl,[switch]$Realtime)
    $prefix=if($Realtime){@('-re')}else{@()}
    switch($SourceType.ToLowerInvariant()){
        'srt'{return @($prefix) + @('-i',$SourceUrl)}
        'm3u8'{return @($prefix) + @('-i',$SourceUrl)}
        'hls'{return @($prefix) + @('-i',$SourceUrl)}
        'ndi'{return @('-f','libndi_newtek','-i',$SourceUrl)}
        default{throw "LiveStream.SourceType '$SourceType' غير معروف (المتوقع m3u8, hls, srt, أو ndi)."}
    }
}

function Start-BridgeMediaProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$StandardOutputPath='',
        [string]$StandardErrorPath=''
    )
    $start=@{
        FilePath=$FilePath;ArgumentList=(ConvertTo-BridgeProcessArgumentLine -Arguments $Arguments)
        WorkingDirectory=$WorkingDirectory;WindowStyle='Hidden';PassThru=$true
    }
    if(-not [string]::IsNullOrWhiteSpace($StandardOutputPath)){$start.RedirectStandardOutput=$StandardOutputPath}
    if(-not [string]::IsNullOrWhiteSpace($StandardErrorPath)){$start.RedirectStandardError=$StandardErrorPath}
    return Start-Process @start
}

function Get-BridgeFrameLuminance {
    <#
        Mean perceived brightness of a captured frame, 0 (black) to 255.

        Used to notice that playout has gone to black while everything the
        bridge can interrogate still reports healthy: Cinegy answers, the
        relay process is alive, the graphics layers are correct - and the
        output is a black rectangle. Nothing else in the bridge looks at the
        picture itself.

        Samples a grid rather than every pixel: a 1920x1080 frame is two
        million reads, this is a few hundred, and black is black at any
        sampling density. Returns $null on an unreadable file so a caller can
        tell "not black" apart from "could not tell".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(4, 128)][int]$GridSize = 16
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { return $null }
    $bitmap = $null
    try {
        $bitmap = [System.Drawing.Bitmap]::new($Path)
        if ($bitmap.Width -lt 1 -or $bitmap.Height -lt 1) { return $null }
        $total = 0.0
        $samples = 0
        for ($gx = 0; $gx -lt $GridSize; $gx++) {
            for ($gy = 0; $gy -lt $GridSize; $gy++) {
                $x = [int](($gx + 0.5) * $bitmap.Width / $GridSize)
                $y = [int](($gy + 0.5) * $bitmap.Height / $GridSize)
                if ($x -ge $bitmap.Width) { $x = $bitmap.Width - 1 }
                if ($y -ge $bitmap.Height) { $y = $bitmap.Height - 1 }
                $pixel = $bitmap.GetPixel($x, $y)
                # Rec. 601 luma: green dominates perceived brightness.
                $total += (0.299 * $pixel.R) + (0.587 * $pixel.G) + (0.114 * $pixel.B)
                $samples++
            }
        }
        if ($samples -eq 0) { return $null }
        return [math]::Round($total / $samples, 2)
    }
    catch { return $null }
    finally { if ($bitmap) { $bitmap.Dispose() } }
}
Export-ModuleMember -Function Get-BridgeFrameLuminance, ConvertTo-BridgeProcessArgumentLine, Get-BridgeFfmpegInputArguments, Start-BridgeMediaProcess
