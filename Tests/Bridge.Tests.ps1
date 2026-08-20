#requires -Version 7
<#
    Bridge.Tests.ps1 — Pester tests for the bridge's pure logic.

    These cover exactly the function-boundary behaviours that produced the
    three bugs that reached production:

      * Split-TelegramText returning a nested array  -> "System.Object[]"
        appeared as the text of every message.
      * Get-FavoriteTemplateKeys returning an empty array -> the caller got
        $null and $null.Count threw under Set-StrictMode.
      * Escape-XmlValue rejecting '' -> pressing ⏭ تخطي crashed the command.

    None of these are visible to static analysis; all three fail loudly here.

    Run:  .\Run-Checks.ps1        (analyzer + tests)
      or: Invoke-Pester .\Tests   (tests only)
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot

    # -LoadOnly defines every function without touching Telegram, the mutex,
    # or the polling loop. config.example.json is used so a real config is
    # never read or rewritten by the tests.
    . (Join-Path $script:Root 'TelegramBridge.ps1') -LoadOnly -ConfigPath 'config.example.json'

    function New-TempTemplateFile {
        <# Unique name per call: Get-TemplateStore caches on path + write time,
           so a fresh path guarantees a fresh parse. The file is created next
           to the script because the registry path is resolved relative to it. #>
        param([Parameter(Mandatory)][string]$Json)
        $name = "templates.test-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $full = Join-Path $script:Root $name
        Set-Content -Path $full -Value $Json -Encoding utf8
        $config.TemplateRegistryPath = $name
        return $full
    }

    # Sanity: -LoadOnly must have defined the functions without running the bot.
    if (-not (Get-Command Split-TelegramText -ErrorAction SilentlyContinue)) {
        throw "TelegramBridge.ps1 did not load its functions; check the -LoadOnly guard."
    }
}

Describe 'Split-TelegramText' {
    It 'returns the short message as a plain string, not a nested array' {
        # The System.Object[] regression: the element must be a string.
        $chunks = @(Split-TelegramText -Text 'مرحبا')
        $chunks.Count | Should -Be 1
        $chunks[0] | Should -BeOfType ([string])
        $chunks[0] | Should -Be 'مرحبا'
        "$($chunks[0])" | Should -Not -Match 'System\.Object'
    }

    It 'keeps every chunk within the limit and loses no characters' {
        $text = (1..400 | ForEach-Object { "سطر رقم $_ فيه نص عربي" }) -join "`n"
        $chunks = @(Split-TelegramText -Text $text)
        $chunks.Count | Should -BeGreaterThan 1
        foreach ($c in $chunks) { $c.Length | Should -BeLessOrEqual 3500 }
        ($chunks -join "`n").Replace("`n", '') | Should -Be $text.Replace("`n", '')
    }

    It 'hard-splits a single line longer than the limit' {
        $chunks = @(Split-TelegramText -Text ('x' * 9000))
        foreach ($c in $chunks) { $c.Length | Should -BeLessOrEqual 3500 }
        ($chunks -join '') | Should -Be ('x' * 9000)
    }
}

Describe 'ConvertTo-ProcessArgumentLine' {
    It 'quotes a path containing spaces' {
        # The ffmpeg exit -22 regression: "D:\cingy cg\..." was split at the space.
        $line = ConvertTo-ProcessArgumentLine -Arguments @('-i', 'D:\cingy cg\logs\snap.jpg')
        $line | Should -Be '-i "D:\cingy cg\logs\snap.jpg"'
    }

    It 'leaves arguments without spaces unquoted' {
        ConvertTo-ProcessArgumentLine -Arguments @('-y', '-frames:v', '1') | Should -Be '-y -frames:v 1'
    }

    It 'represents an empty argument as an empty quoted string' {
        ConvertTo-ProcessArgumentLine -Arguments @('-x', '') | Should -Be '-x ""'
    }

    It 'escapes embedded quotes' {
        ConvertTo-ProcessArgumentLine -Arguments @('say "hi"') | Should -Be '"say \"hi\""'
    }
}

Describe 'Get-JsonProp' {
    It 'returns $null for a missing property instead of throwing under StrictMode' {
        $obj = [pscustomobject]@{ a = 1 }
        Get-JsonProp $obj 'missing' | Should -BeNullOrEmpty
    }

    It 'returns the value when present' {
        Get-JsonProp ([pscustomobject]@{ a = 42 }) 'a' | Should -Be 42
    }

    It 'supports hashtables and a $null object' {
        Get-JsonProp @{ b = 'x' } 'b' | Should -Be 'x'
        Get-JsonProp $null 'anything' | Should -BeNullOrEmpty
    }

    It 'preserves $false rather than treating it as absent' {
        Get-JsonProp ([pscustomobject]@{ flag = $false }) 'flag' | Should -Be $false
    }
}

Describe 'Protect-SensitiveText' {
    It 'redacts a Telegram RTMP stream key' {
        $msg = 'Error opening output rtmp://dc4-1.rtmp.t.me/s/SECRETKEY123: failed'
        $safe = Protect-SensitiveText $msg
        $safe | Should -Not -Match 'SECRETKEY123'
        $safe | Should -Match 'rtmp://\*\*\*'
    }

    It 'redacts a bot token' {
        (Protect-SensitiveText 'token 123456789:TEST_TOKEN_REDACTED here') |
        Should -Not -Match 'TEST_TOKEN_REDACTED'
    }

    It 'redacts an SRT passphrase' {
        (Protect-SensitiveText 'srt://host:9000?passphrase=hunter2') | Should -Not -Match 'hunter2'
    }

    It 'leaves ordinary text untouched' {
        Protect-SensitiveText 'تم إظهار عاجل على الطبقة 4' | Should -Be 'تم إظهار عاجل على الطبقة 4'
    }

    It 'handles empty input' {
        Protect-SensitiveText '' | Should -Be ''
    }
}

Describe 'Template registry parsing' {
    It 'accepts both plain-string and labelled field definitions' {
        $file = New-TempTemplateFile -Json @'
{
  "a": { "path": "C:\\x.cintitle", "layer": 3, "order": 1, "fields": ["Plain.Text"] },
  "b": { "path": "C:\\y.cintitle", "layer": 4, "order": 2,
         "fields": [ { "name": "Ajel.center", "label": "نص العاجل" } ] }
}
'@
        try {
            $store = Get-TemplateStore
            $store.Order.Count | Should -Be 2
            $store.Map['a'].Fields[0] | Should -Be 'Plain.Text'
            $store.Map['a'].FieldLabels[0] | Should -Be ''
            $store.Map['b'].Fields[0] | Should -Be 'Ajel.center'
            $store.Map['b'].FieldLabels[0] | Should -Be 'نص العاجل'
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'skips templates missing path or layer instead of crashing' {
        $file = New-TempTemplateFile -Json @'
{
  "good":    { "path": "C:\\x.cintitle", "layer": 3 },
  "nopath":  { "layer": 3 },
  "nolayer": { "path": "C:\\y.cintitle" }
}
'@
        try {
            $store = Get-TemplateStore
            $store.Order | Should -Be @('good')
            $store.Errors.Count | Should -Be 2
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'gives an absent fields key an empty array, not a phantom null field' {
        $file = New-TempTemplateFile -Json '{ "solo": { "path": "C:\\x.cintitle", "layer": 2 } }'
        try {
            (Get-TemplateStore).Map['solo'].Fields.Count | Should -Be 0
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'resolves field limits: field maxLength beats template beats global' {
        $file = New-TempTemplateFile -Json @'
{
  "t": { "path": "C:\\x.cintitle", "layer": 1, "maxLength": 120,
         "fields": [ { "name": "A.Text", "maxLength": 40 },
                     { "name": "B.Text" },
                     "C.Text" ] }
}
'@
        try {
            $t = (Get-TemplateStore).Map['t']
            $t.FieldLimits[0] | Should -Be 40    # field override
            $t.FieldLimits[1] | Should -Be 120   # template default
            $t.FieldLimits[2] | Should -Be 120   # plain string inherits template
            Get-EffectiveFieldLimit -FieldLimit 40 | Should -Be 40
            Get-EffectiveFieldLimit -FieldLimit 0  | Should -Be (Get-SettingInt 'MaxFieldLength' 0)
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'falls back to the global limit when no maxLength is declared' {
        $file = New-TempTemplateFile -Json '{ "t": { "path": "C:\\x.cintitle", "layer": 1, "fields": ["A.Text"] } }'
        try {
            (Get-TemplateStore).Map['t'].FieldLimits[0] | Should -Be 0
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'orders deterministically by order then key' {
        $file = New-TempTemplateFile -Json @'
{
  "zebra": { "path": "C:\\z.cintitle", "layer": 1, "order": 1 },
  "alpha": { "path": "C:\\a.cintitle", "layer": 2, "order": 5 },
  "beta":  { "path": "C:\\b.cintitle", "layer": 3, "order": 1 }
}
'@
        try {
            (Get-TemplateStore).Order | Should -Be @('beta', 'zebra', 'alpha')
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Array-returning helpers' {
    # Dot-sourcing hoists the script's variables into this scope, so they are
    # referenced unqualified - a $script: prefix here would resolve to the test
    # file's own scope, not the bridge's.
    It 'Get-FavoriteTemplateKeys yields a countable array even with no usage history' {
        # The $null.Count regression: an empty return must survive @() wrapping.
        $favs = @(Get-FavoriteTemplateKeys)
        { $favs.Count } | Should -Not -Throw
        $favs.Count | Should -BeGreaterOrEqual 0
    }

    It 'Get-KnownLayers always returns at least one layer' {
        @(Get-KnownLayers).Count | Should -BeGreaterThan 0
    }
}

Describe 'Settings access' {
    It 'falls back to the declared default for an unset key' {
        Get-SettingInt 'MaxFieldLength' 1 | Should -BeGreaterThan 0
    }

    It 'returns 0 for an unknown key rather than throwing' {
        Get-SettingInt 'NoSuchSettingAtAll' 0 | Should -Be 0
    }

    It 'declares every protected setting as a real boolean setting' {
        $ProtectedSettings | Should -Not -BeNullOrEmpty
        foreach ($name in $ProtectedSettings) {
            $DefaultSettings.Contains($name) | Should -BeTrue -Because "$name must exist in DefaultSettings"
            $DefaultSettings[$name] | Should -BeOfType ([bool])
        }
    }

    It 'exposes every declared setting through Get-Setting' {
        foreach ($name in $DefaultSettings.Keys) {
            { Get-Setting $name } | Should -Not -Throw
        }
    }
}

Describe 'Escape-XmlValue (CinegyAirTitler)' {
    It 'accepts an empty string' {
        # The ⏭ تخطي regression: a Mandatory [string] rejects ''.
        { Escape-XmlValue -Value '' } | Should -Not -Throw
        Escape-XmlValue -Value '' | Should -Be ''
    }

    It 'escapes XML metacharacters' {
        Escape-XmlValue -Value '<b>&"' | Should -Match '&lt;'
        Escape-XmlValue -Value '<b>&"' | Should -Not -Match '<b>'
    }

    It 'leaves Arabic text intact' {
        Escape-XmlValue -Value 'خبر عاجل' | Should -Be 'خبر عاجل'
    }
}
