# Admin Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build actionable external-change alerts, unit-aware settings, and safe template administration.

**Architecture:** Reconciliation returns structured changes without altering its existing removed-layer result. Settings get display metadata beside defaults. Template definition writes use one validated atomic writer; all admins can read definitions, while a protected false-by-default setting gates mutations.

**Tech Stack:** PowerShell 7, Pester 6, PSScriptAnalyzer, Telegram inline keyboards, Cinegy Air HTTP, JSON.

**Spec:** `docs/superpowers/specs/2026-08-21-admin-operations-design.md`

## Global Constraints

- Never invent a modifying program or remote IP.
- Preserve `Update-OnAirStateFromCinegy.Removed`.
- `EnableFullTemplateManagement` is protected and false by default.
- Every mutation validates, reviews, backs up, and atomically writes `templates.json`.
- Never alert/audit secrets or field values.
- Template keys remain immutable; on-air or scheduled templates cannot be deleted.

---

### Task 1: External-change details

**Files:**
- Modify: `TelegramBridge.ps1:1094-1164,4350-4370`
- Modify: `Tests/Bridge.Tests.ps1:1580-1628,1920-1965`
- Modify: `README.md:418-425`
- Modify: `CHANGELOG.md:3-25`

**Interfaces:**
- Produces `Changes` from `Update-OnAirStateFromCinegy`, with layer, template key, original user/time/id, actual Cinegy item/id/output/client data.
- Produces `Format-ExternalCinegyChangeAlert -Changes [object[]]`.

- [ ] **Step 1: Write failing tests**

```powershell
$result.Changes[0].TemplateKey | Should -Be 'lower-third'
$result.Changes[0].ActualActiveName | Should -Be 'External Item'
(Format-ExternalCinegyChangeAlert -Changes @($change)) | Should -Match 'مصدر خارجي غير معرّف'
```

- [ ] **Step 2: Run RED**

Run `Invoke-Pester -Path .\Tests -FullNameFilter '*external change*','*external alert*' -Output Detailed`; expect the missing record/formatter failure.

- [ ] **Step 3: Implement minimal records and formatter**

```powershell
$changes.Add([pscustomobject]@{ Layer=[int]$layer; TemplateKey=$record.Key; ShowUserId=$record.UserId; ShownAt=$record.At; ExpectedActiveId=$trackedId; ActualActiveId=$status.ActiveId; ActualActiveName=$status.ActiveName; OutputState=$status.OutputState; ClientConnected=$status.ClientConnected; ClientIdentity=$status.ClientIdentity })
```

Return `Changes` while retaining `Removed`. Format hidden/replaced state, Air server/channel, and either client identity or unknown source. Pass the formatter result to the watchdog broadcast.

- [ ] **Step 4: Verify and commit**

Run `.\Run-Checks.ps1`; expect all tests passing and zero analyzer errors. Stage the four files above and commit `Enrich external Cinegy change alerts`.

### Task 2: Unit-aware settings

**Files:**
- Modify: `TelegramBridge.ps1:69-120,1932-1958,3565-3595`
- Modify: `Tests/Bridge.Tests.ps1:260-300`
- Modify: `README.md:410-420`

**Interfaces:**
- Produces `$script:SettingDisplayMetadata`, `Format-SettingDisplay`, and `Get-SettingPromptText`.

- [ ] **Step 1: Write failing tests**

```powershell
Format-SettingDisplay -Name CinegyStateCheckSeconds -Value 15 | Should -Be '15 ثانية'
Format-SettingDisplay -Name ConfigBackupKeepFiles -Value 10 | Should -Be '10 ملفات'
Get-SettingPromptText -Name SnapshotRetentionMinutes | Should -Match 'مدة الاحتفاظ.*دقيقة'
```

- [ ] **Step 2: Run RED**

Run `Invoke-Pester -Path .\Tests -FullNameFilter '*setting units*' -Output Detailed`; expect missing helper failure.

- [ ] **Step 3: Implement metadata and apply it**

```powershell
$script:SettingDisplayMetadata = @{ CinegyStateCheckSeconds=@{Unit='ثانية';Description='الفاصل بين فحوص تغير الطبقات'}; SnapshotRetentionMinutes=@{Unit='دقيقة';Description='مدة الاحتفاظ بصور البث'}; ConfigBackupKeepFiles=@{Unit='ملفات';Description='عدد نسخ الإعدادات'} }
```

Cover all numeric defaults with seconds, minutes, hours, megabytes, files, characters, attempts, templates, values, or count. Use the helpers in settings rows and numeric prompt text; callback data stays unchanged.

- [ ] **Step 4: Verify and commit**

Run `.\Run-Checks.ps1`; stage files and commit `Clarify administrator setting values`.

### Task 3: Read-only template catalogue and guarded full management

**Files:**
- Modify: `TelegramBridge.ps1:69-120,650-780,1650-1685,1730-1765,2600-2755,3500-3610,3980-4230`
- Modify: `Tests/Bridge.Tests.ps1:380-460,1460-1545`
- Modify: `config.example.json:20-70`
- Modify: `README.md:25-55,410-430`
- Modify: `CHANGELOG.md:3-25`

**Interfaces:**
- Produces protected `EnableFullTemplateManagement = $false`.
- Produces `Get-TemplateAdminCatalogueKeyboard`, `Show-TemplateAdminDetail`, and `Save-TemplateDefinitionChange`.
- `Save-TemplateDefinitionChange -TemplateKey [string] -Action [ValidateSet('edit','create','delete')] -Definition [hashtable]` returns `Success`, `Error`, `BackupPath`.

- [ ] **Step 1: Write failing catalogue/guard tests**

```powershell
Show-TemplateAdminDetail -TemplateIndex 0 -ChatId 100 -UserId 100
Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'المسار' -and $Text -match 'الطبقة' }
Invoke-TemplateDefinitionChange -TemplateIndex 0 -Action edit -ChatId 100 -UserId 100
```

Assert the second action is rejected when `EnableFullTemplateManagement` is false.

- [ ] **Step 2: Run RED**

Run `Invoke-Pester -Path .\Tests -FullNameFilter '*template detail*','*full edits while*' -Output Detailed`; expect missing catalogue/detail/guard failure.

- [ ] **Step 3: Add the catalogue and protected gate**

Add an admin `📚 القوالب والإعدادات` menu. Detail always reads key, path, layer, order, description, fields, limits, preset count. Add mutation buttons only when the protected setting is enabled.

- [ ] **Step 4: Write failing atomic-writer safety tests**

```powershell
$result = Save-TemplateDefinitionChange -TemplateKey urgent -Action edit -Definition @{path='titles/urgent.cintitle';layer=5;fields=@('Headline.Text')}
$result.Success | Should -BeTrue
Test-Path $result.BackupPath | Should -BeTrue
(Save-TemplateDefinitionChange -TemplateKey urgent -Action delete -Definition @{}).Error | Should -Match 'على الهواء'
```

- [ ] **Step 5: Run RED**

Run `Invoke-Pester -Path .\Tests -FullNameFilter '*validated template edit*','*deleting an on-air template*' -Output Detailed`; expect missing writer failure.

- [ ] **Step 6: Implement writer and reviewed wizard**

Parse current JSON; validate unique new key, positive layer, valid fields, and project-contained path. Reject deleting keys in `$script:OnAir` or future schedules. Back up, write `$path.tmp`, atomically move, invalidate cache after success, and audit structural action only. Use the pending-state review pattern so Telegram saves only after confirmation.

- [ ] **Step 7: Verify and commit**

Run `.\Run-Checks.ps1`; stage code/tests/config/docs and commit `Add guarded template registry management`.
