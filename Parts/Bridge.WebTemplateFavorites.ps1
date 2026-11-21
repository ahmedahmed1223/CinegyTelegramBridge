#requires -Version 7

function Get-WebTemplateFavoritesActor {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if ([long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -and $actor -gt 0 -and
        (Test-Authorized -ChatId $actor -UserId $actor)) { return $actor }
}

function Get-WebTemplateFavoritesView {
    param([long]$Actor)
    if (-not (Get-Setting 'EnableFavorites')) {
        return @{ enabled = $false; selectedKeys = @(); promotedKeys = @(); eligibleKeys = @() }
    }
    $store = Get-TemplateStore
    $allowed = @{}
    $eligible = @(foreach ($key in $store.Order) {
            $template = $store.Map[$key]
            if ((Test-TemplateAccess -Key $key -Layer ([int]$template.Layer) -ChatId $Actor -UserId $Actor).Allowed) {
                $allowed[$key] = [string]$key
                [string]$key
            }
        })
    # Only the uncapped explicit selection drives the star and Favorites filter.
    # The Bot's separate ranking can include usage defaults and is capped.
    return @{
        enabled = $true; eligibleKeys = $eligible
        selectedKeys = @(Get-UserFavoriteSelection -UserId $Actor | Where-Object { $allowed.ContainsKey($_) } |
                ForEach-Object { $allowed[$_] } | Select-Object -Unique)
        promotedKeys = @(Get-FavoriteTemplateKeys -UserId $Actor | Where-Object { $allowed.ContainsKey($_) } |
                ForEach-Object { $allowed[$_] } | Select-Object -Unique)
    }
}

function Get-WebTemplateFavorites {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTemplateFavoritesActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    return @{ ok = $true; data = Get-WebTemplateFavoritesView -Actor $actor }
}

function Set-WebTemplateFavorite {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $actor = Get-WebTemplateFavoritesActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableFavorites')) { return @{ ok = $false; error = 'favorites_disabled' } }
    $selected = Get-JsonProp $Arguments 'selected'
    $key = Get-JsonProp $Arguments 'key'
    if ($selected -isnot [bool] -or $key -isnot [string] -or [string]::IsNullOrWhiteSpace($key)) {
        return @{ ok = $false; error = 'favorites_invalid' }
    }
    $access = Get-WebPresetTemplateAccess -Actor $actor -Key $key
    if (-not $access.ok) { return $access }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if (-not (Set-UserFavorite -UserId $actor -TemplateKey ([string]$access.template.Key) -Enabled $selected)) {
        return @{ ok = $false; error = 'favorite_save_failed' }
    }
    return @{ ok = $true; data = Get-WebTemplateFavoritesView -Actor $actor }
}
