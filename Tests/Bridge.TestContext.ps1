#requires -Version 7
<#
    Bridge.TestContext.ps1 - shared Pester setup for the Bridge.*.Tests.ps1
    files. Dot-sourced at the top of each one so the bridge loads the same
    way everywhere and the setup lives in a single place.
#>

BeforeDiscovery {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\CinegyAirTitler.psm1'
    Import-Module $modulePath -Force
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot

    # -LoadOnly defines every function without touching Telegram, the mutex,
    # or the polling loop. config.example.json is used so a real config is
    # never read or rewritten by the tests.
    . (Join-Path $script:Root 'TelegramBridge.ps1') -LoadOnly -ConfigPath 'config.example.json' -RuntimePath $TestDrive
    # Promote the dot-sourced path into this test file's script scope so
    # persistence tests can redirect it safely to Pester's TestDrive.
    $script:onAirFile = $onAirFile
    $script:ConfigPath = $ConfigPath

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

    # The network, shut for every test file.
    #
    # -LoadOnly stops the polling loop, not a screen. Since screens began
    # trying sendRichMessage before their text, any test that drove a real
    # screen while mocking only Send-TelegramMessage was making a live request
    # to api.telegram.org and waiting out its 401 - fifteen of them, a second
    # each, on every run of the gate. The answer was never useful either: the
    # token in config.example.json is a placeholder.
    #
    # Mocked at the real boundary rather than at Invoke-BridgeTelegramRequest,
    # so everything above it still runs and is still measured - including the
    # retry and the timeout, whose own tests mock this same command and whose
    # mock wins over this one.
    Mock Invoke-RestMethod -ModuleName BridgeTelegram { throw 'the tests do not talk to Telegram' }
}

