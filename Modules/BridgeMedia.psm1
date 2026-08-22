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

Export-ModuleMember -Function ConvertTo-BridgeProcessArgumentLine, Get-BridgeFfmpegInputArguments, Start-BridgeMediaProcess
