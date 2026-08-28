# Version 6 Settings Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unbounded administrator settings keyboard with categorized, Arabic, paged navigation while preserving every existing setting editor and configuration key.

**Architecture:** Add a small setting-navigation schema beside the existing defaults, expose pure category and pagination helpers, then make the Telegram keyboards and callback router consume those helpers. Keep value mutation in the existing setting functions so the change is limited to discovery and navigation.

**Tech Stack:** PowerShell 7, Telegram inline keyboards, Pester 5, PSScriptAnalyzer

**Spec:** `docs/superpowers/specs/2026-08-28-version-6-current-experience-design.md`

## Global Constraints

- Preserve PowerShell 7, Telegram Bot API, Cinegy Air HTTP control, `config.json`, and `templates.json` compatibility.
- Preserve the existing `cfg:t:`, `cfg:v:`, `cfg:s:`, and `cfgs:` editing callbacks.
- Category pages contain at most eight setting rows.
- Every current or future default setting remains reachable; missing metadata falls back to the advanced category.
- Production behavior is added only after a focused Pester test has failed for the expected reason.

---

### Task 1: Setting navigation schema

**Files:**
- Modify: `TelegramBridge.ps1:125`
- Modify: `Parts/Bridge.Keyboards.ps1:703`
- Test: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces: `Get-SettingCategoryDefinitions`, `Get-SettingNavigationMetadata -Name <string>`, and `Get-SettingsInCategory -Category <string>`.
- Consumers: settings home and category keyboards in Task 2.

- [ ] **Step 1: Write failing schema tests**

Add tests that assert the literal category order, that `RequireUserLevelAuth` resolves to the Arabic security label, and that the union of category results contains every default setting exactly once.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: failures report the three missing navigation helper commands.

- [ ] **Step 3: Add the minimal schema and pure helpers**

Define ordered category records with `Key`, `Label`, and `Icon`; define metadata for each current setting with `Category` and `Label`; make missing metadata return `{ Category = 'advanced'; Label = <technical name> }`; filter defaults in their existing order.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: all tests in `Bridge.Tests.ps1` pass.

### Task 2: Categorized and paged Telegram keyboards

**Files:**
- Modify: `Parts/Bridge.Keyboards.ps1:703`
- Modify: `Parts/Bridge.Commands.ps1:24`
- Test: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces: `Get-SettingsKeyboard` as the category home and `Get-SettingsCategoryKeyboard -Category <string> -Page <int> -PageSize <int>`.

- [ ] **Step 1: Write failing keyboard behavior tests**

Assert that the home has `cfgcat:security:0`, has no direct `cfg:t:RequireUserLevelAuth`, and that a category page emits no more than eight setting callbacks plus navigation controls.

- [ ] **Step 2: Run tests and verify RED**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: the legacy flat keyboard violates the home and paging assertions.

- [ ] **Step 3: Implement the home and category keyboard**

Render two category buttons per row, retain layer scope/names/backups/reset on the home, clamp invalid pages, emit existing edit callbacks, and add `cfgcat:<key>:<page>` previous/next plus `menu:settings` return controls.

- [ ] **Step 4: Update settings screen copy and verify GREEN**

Change the settings home text to explain categories, run the test file, and confirm every existing settings editor test remains green.

### Task 3: Authorized category callback routing

**Files:**
- Modify: `Parts/Bridge.Callbacks.ps1:412`
- Modify: `Parts/Bridge.Commands.ps1:24`
- Test: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Consumes: `Get-SettingsCategoryKeyboard`.
- Produces: `Show-SettingsCategoryScreen -Category <string> -Page <int> -ChatId <long> -UserId <long>` and authorized `cfgcat:*` routing.

- [ ] **Step 1: Write failing routing tests**

Assert that an administrator callback `cfgcat:security:0` sends the security category screen and a non-administrator callback does not send it.

- [ ] **Step 2: Run tests and verify RED**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: the callback falls through because `cfgcat:*` is not registered.

- [ ] **Step 3: Implement strict parsing and authorized routing**

Split only the category key and numeric page, reject malformed or unknown categories with the settings home, and call the category screen only after `Test-CallbackAdmin` succeeds.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: administrator and rejection paths pass.

### Task 4: Version, operator documentation, and release gate

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `config.example.json`

**Interfaces:**
- Consumes: completed categorized settings behavior.
- Produces: documented Version 6 preview behavior without changing configuration format.

- [ ] **Step 1: Update operator-facing version and documentation**

Set the development version to `6.0.0-preview.1`, document the category names, paging behavior, compatibility promise, and the unchanged 10 MiB import limits.

- [ ] **Step 2: Run the complete release gate**

Run: `./Run-Checks.ps1`

Expected: required-file/JSON checks pass, PowerShell syntax is clean, PSScriptAnalyzer reports zero actionable findings, and all Pester tests pass.

- [ ] **Step 3: Review the final diff**

Run: `git diff --check` and `git diff --stat`.

Expected: no whitespace errors and changes are limited to the spec, plan, settings navigation, tests, version, and documentation.
