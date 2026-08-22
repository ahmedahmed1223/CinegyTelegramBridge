#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeMedia.psm1') -Force
}

Describe 'External media process module' {
    It 'quotes spaces empty values and embedded quotes for Windows process arguments' {
        ConvertTo-BridgeProcessArgumentLine -Arguments @('-i','D:\media files\in.m3u8','','say "hi"') |
            Should -Be '-i "D:\media files\in.m3u8" "" "say \"hi\""'
    }

    It 'builds supported realtime ffmpeg inputs and rejects unknown source types' {
        @(Get-BridgeFfmpegInputArguments -SourceType srt -SourceUrl 'srt://source' -Realtime) |
            Should -Be @('-re','-i','srt://source')
        @(Get-BridgeFfmpegInputArguments -SourceType ndi -SourceUrl 'Studio NDI' -Realtime) |
            Should -Be @('-f','libndi_newtek','-i','Studio NDI')
        { Get-BridgeFfmpegInputArguments -SourceType unknown -SourceUrl x } | Should -Throw '*غير معروف*'
    }

    It 'starts a hidden non-shell process with explicit working directory and redirects' {
        Mock Start-Process { [pscustomobject]@{Id=321;StartTime=[datetime]'2026-08-22'} } -ModuleName BridgeMedia

        $process=Start-BridgeMediaProcess -FilePath 'C:\ffmpeg\ffmpeg.exe' -Arguments @('-i','D:\media files\in.m3u8') `
            -WorkingDirectory 'D:\bridge' -StandardOutputPath 'D:\logs\out.log' -StandardErrorPath 'D:\logs\err.log'

        $process.Id | Should -Be 321
        Should -Invoke Start-Process -ModuleName BridgeMedia -Times 1 -Exactly -ParameterFilter {
            $WindowStyle -eq 'Hidden' -and $PassThru -and $ArgumentList -eq '-i "D:\media files\in.m3u8"' -and
            $RedirectStandardOutput -eq 'D:\logs\out.log' -and $RedirectStandardError -eq 'D:\logs\err.log'
        }
    }
}
