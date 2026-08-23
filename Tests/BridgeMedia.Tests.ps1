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

Describe 'Frame luminance' {
    BeforeAll {
        Add-Type -AssemblyName System.Drawing
        function New-SolidJpeg { param([string]$Path, [int]$R, [int]$G, [int]$B)
            $bmp = [System.Drawing.Bitmap]::new(64, 48)
            try {
                $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                try { $gfx.Clear([System.Drawing.Color]::FromArgb($R, $G, $B)) } finally { $gfx.Dispose() }
                $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            }
            finally { $bmp.Dispose() }
            return $Path
        }
    }

    It 'reads a black frame as near zero' {
        $path = New-SolidJpeg -Path (Join-Path $TestDrive 'black.jpg') -R 0 -G 0 -B 0
        Get-BridgeFrameLuminance -Path $path | Should -BeLessThan 6
    }

    It 'reads a white frame as near maximum' {
        $path = New-SolidJpeg -Path (Join-Path $TestDrive 'white.jpg') -R 255 -G 255 -B 255
        Get-BridgeFrameLuminance -Path $path | Should -BeGreaterThan 240
    }

    It 'weights green above blue, matching perceived brightness' {
        $green = New-SolidJpeg -Path (Join-Path $TestDrive 'green.jpg') -R 0 -G 255 -B 0
        $blue = New-SolidJpeg -Path (Join-Path $TestDrive 'blue.jpg') -R 0 -G 0 -B 255
        (Get-BridgeFrameLuminance -Path $green) | Should -BeGreaterThan (Get-BridgeFrameLuminance -Path $blue)
    }

    It 'reports a dark-but-not-black frame above the black threshold' {
        # A dimly lit studio must not be mistaken for loss of output.
        $path = New-SolidJpeg -Path (Join-Path $TestDrive 'dim.jpg') -R 40 -G 40 -B 40
        Get-BridgeFrameLuminance -Path $path | Should -BeGreaterThan 6
    }

    It 'returns null rather than a number when the file cannot be read' {
        Get-BridgeFrameLuminance -Path (Join-Path $TestDrive 'missing.jpg') | Should -BeNullOrEmpty
    }
}
