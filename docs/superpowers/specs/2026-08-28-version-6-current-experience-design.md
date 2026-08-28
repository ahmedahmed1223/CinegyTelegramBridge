# Version 6 Current-Experience Design

## Purpose

Version 6 improves the existing PowerShell and Telegram product rather than replacing it. Its operational theme is: faster decisions, clearer state, and safer behavior under live-broadcast pressure.

## Compatibility

- PowerShell 7, Telegram Bot API, Cinegy Air HTTP control, `config.json`, and `templates.json` remain the product boundaries.
- Existing configuration keys, callback payloads, stored runtime files, and typed commands remain compatible unless a migration is explicitly versioned.
- Version 6 may add metadata and navigation callbacks, but it must not require operators to rewrite existing configuration or templates.

## 6.0 Scope

The first release focuses on navigation and settings because the current settings keyboard renders every setting in one long Telegram message. The new settings home groups settings by operational purpose and exposes advanced options separately. Each category opens a bounded, paged keyboard and retains the existing toggle/value editors.

Categories are security, on-air operation, templates and layers, news, scheduling, monitoring and alerts, files and retention, and advanced settings. Every setting has one category and an Arabic display label. Unknown future settings remain reachable through the advanced category so an incomplete metadata entry cannot hide a configuration key.

The settings home also keeps emergency-layer selection, layer names, backups, and reset access. Reset-all remains available but requires the existing confirmation path.

## Interaction Contract

- `menu:settings` opens the settings-category home.
- `cfgcat:<category>:<page>` opens a category page.
- Existing `cfg:t:`, `cfg:v:`, `cfg:s:`, and `cfgs:` callbacks continue to edit values.
- A category page shows at most eight setting rows, followed by previous/next controls when needed and a return-to-settings button.
- Screen copy uses Arabic operational labels while retaining the technical key in the setting description or prompt for support.
- Protected settings continue to display a lock and require confirmation only when protection is weakened.

## Internal Design

`TelegramBridge.ps1` owns a setting-schema map keyed by the existing setting name. Each entry provides `Category`, `Label`, and optional `Advanced`. Existing default values, display metadata, choice lists, and protected-setting lists remain authoritative during 6.0; later 6.x work can consolidate them after the navigation contract is stable.

Pure helpers resolve category definitions, setting metadata, category membership, and pagination. Keyboard functions consume those helpers. Callback routing only parses and authorizes category navigation; it does not duplicate schema logic.

## Non-Goals for 6.0

- No desktop application or Windows-service rewrite.
- No queue/worker rewrite of on-air commands.
- No rename or removal of existing settings.
- No automatic modification of a user's `config.json` beyond the existing initialization behavior.

## Acceptance Criteria

- The settings home contains category buttons instead of one row per configuration key.
- Every key in `$script:DefaultSettings` is reachable in exactly one category.
- Category pages contain no more than eight settings and paginate deterministically.
- Existing setting edits and authorization behavior still work.
- Full syntax, analyzer, and Pester checks pass.
