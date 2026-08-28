# Version 6 Completion Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the remaining Version 6 user-experience, operation-safety,
state, health, and scale improvements while retaining the existing PowerShell,
Telegram, Cinegy, configuration, and callback contracts.

**Architecture:** Keep `Single` scene mode as the compatible default, introduce
canonical live-scene and operation records behind pure modules, and expose new
behavior only through capability-gated adapters. Build settings, storage,
navigation, and health improvements on those adapters; no mutable bridge state
is accessed from background runspaces.

**Tech Stack:** PowerShell 7, Telegram Bot API, Cinegy Air HTTP control,
JSON, Pester 6, PSScriptAnalyzer.

**Spec:** `docs/VERSION-6.md` and
`docs/superpowers/specs/2026-08-28-version-6-multi-scene-compatibility-design.md`.

## Global Constraints

- Preserve `config.json`, `templates.json`, existing typed commands, and
  existing `hide:<layer>` / `exit:<layer>` callbacks in `Single` mode.
- A configured shared template layer does not prove simultaneous active scenes.
- `Multi` scene mode remains disabled until Cinegy supports stable scene listing
  and direct scene targeting; failure to verify capabilities fails closed.
- HIDE, EXIT, and hide-all remain higher priority than SHOW and administration.
- SHOW keeps its existing review and layer-verification safety gates.
- New mutable state is validated and atomically persisted with a backup before
  the primary file is replaced.
- Every behavior change begins with a focused failing Pester test.

---

### Task 1: Canonical live-scene state with legacy migration

**Files:**
- Create: `Modules/BridgeLiveScenes.psm1`
- Create: `Tests/BridgeLiveScenes.Tests.ps1`
- Modify: `Parts/Bridge.OnAir.ps1`
- Modify: `TelegramBridge.ps1`
- Modify: `Run-Checks.ps1`, `Build-Release.ps1`

**Interfaces:** Produces `ConvertTo-BridgeLiveSceneState`,
`Get-BridgeLiveScenes`, `Get-BridgeLiveScenesForLayer`,
`Get-BridgeLiveScene`, and `Get-BridgePrimarySceneForLayer`.

- [ ] **Step 1: Write failing state tests**

Test that a legacy `{ "7": { "Key": "lower-third" } }` document becomes one
scene whose `Layer` is `7`, that two records may share `Layer = 7`, and that
duplicate or blank `SceneId` values are rejected.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/BridgeLiveScenes.Tests.ps1 -Output Detailed`

Expected: missing live-scene helper commands.

- [ ] **Step 3: Implement pure canonical state conversion**

Create scene records with `SceneId`, `Layer`, `Key`, `ActiveId`, `At`,
`UserId`, `ChatId`, `Source`, `TemplatePath`, and `LastVerifiedAtUtc`.
Legacy layer-keyed input creates exactly one generated legacy SceneId per
layer; canonical input validates every record before returning it.

- [ ] **Step 4: Add atomic runtime integration**

Load the legacy state through `ConvertTo-BridgeLiveSceneState`, keep the
current `$script:OnAir` view populated through `Get-BridgePrimarySceneForLayer`,
and write the canonical envelope only after backup and validation succeed.

- [ ] **Step 5: Verify GREEN and commit**

Run: `Invoke-Pester ./Tests/BridgeLiveScenes.Tests.ps1 -Output Detailed`

Commit: `feat(v6): add compatible live scene state`

### Task 2: Cinegy capability gate and scene-mode health reporting

**Files:**
- Modify: `Modules/CinegyAirTitler.psm1`
- Modify: `Modules/BridgeLiveScenes.psm1`
- Modify: `Parts/Bridge.Admin.ps1`
- Modify: `Tests/BridgeLiveScenes.Tests.ps1`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:** Produces `Get-CinegySceneCapabilities` and
`Test-BridgeSceneMode`. Consumes canonical scene records from Task 1.

- [ ] **Step 1: Write failing capability tests**

Mock Cinegy responses that expose one layer item, multiple items without
identities, and multiple items with stable SceneId values plus direct-target
support. Assert only the final response permits `Multi` mode.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/BridgeLiveScenes.Tests.ps1 -Output Detailed`

Expected: capability functions do not exist.

- [ ] **Step 3: Implement fail-closed mode selection**

Return `{ Mode; CanListScenes; CanTargetScene; Verified; Error }`. The default
mode is `Single`; selecting `Multi` returns an Arabic error unless both
capabilities are true. Add the selected mode and verification state to the
health-center text.

- [ ] **Step 4: Verify GREEN and commit**

Run: `Invoke-Pester ./Tests/BridgeLiveScenes.Tests.ps1,./Tests/Bridge.Tests.ps1 -Output Detailed`

Commit: `feat(v6): gate multi-scene mode on Cinegy capability`

### Task 3: Operation lifecycle, priority admission, and scene-safe routing

**Files:**
- Create: `Modules/BridgeOperationLifecycle.psm1`
- Create: `Tests/BridgeOperationLifecycle.Tests.ps1`
- Modify: `Modules/BridgeOperationPolicy.psm1`
- Modify: `Parts/Bridge.ShowFlow.ps1`, `Parts/Bridge.Callbacks.ps1`
- Modify: `Parts/Bridge.Keyboards.ps1`, `Tests/Bridge.Tests.ps1`

**Interfaces:** Produces `New-BridgeOperationRecord`,
`Set-BridgeOperationState`, `Get-BridgeOperationStatusText`, and
`New-BridgeSceneCallbackToken` / `Resolve-BridgeSceneCallbackToken`.

- [ ] **Step 1: Write failing lifecycle tests**

Assert a new operation receives a short id and state `queued`, legal states
are `queued`, `running`, `succeeded`, `warning`, and `failed`, and an invalid
state transition is rejected. Assert expired, unknown, and cross-layer scene
tokens cannot resolve.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/BridgeOperationLifecycle.Tests.ps1 -Output Detailed`

Expected: lifecycle and token commands do not exist.

- [ ] **Step 3: Implement lifecycle records and callback tokens**

Store no editorial values in a record. Include operation id, action, target
scope, layer, optional SceneId, actor, queued/start/end times, result, and
error. Use random bounded tokens mapped in memory to a verified SceneId;
preserve legacy callbacks in `Single` mode.

- [ ] **Step 4: Route Multi actions safely**

Classify SHOW, hide-layer, exit-layer, replace, and clear as `LayerExclusive`.
Classify scene HIDE, EXIT, and UPDATE as `SceneSpecific`, but serialize both
through the existing layer lock until Cinegy concurrency is proven. Render
separate scene rows and scene-specific controls only in verified `Multi` mode.

- [ ] **Step 5: Verify GREEN and commit**

Run: `Invoke-Pester ./Tests/BridgeOperationLifecycle.Tests.ps1,./Tests/Bridge.Tests.ps1 -Output Detailed`

Commit: `feat(v6): add scene-safe operation lifecycle`

### Task 4: Advanced settings discovery and single-setting recovery

**Files:**
- Modify: `Modules/BridgeSettingsSchema.psm1`
- Modify: `Parts/Bridge.Keyboards.ps1`, `Parts/Bridge.Callbacks.ps1`
- Modify: `Parts/Bridge.Admin.ps1`, `Tests/BridgeSettingsSchema.Tests.ps1`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:** Extends schema records with `Minimum`, `Maximum`, `Advanced`,
`Sensitive`, `RequiresConfirmation`, and `RequiresRestart`; produces
`Find-BridgeSettings`, `Get-ModifiedBridgeSettings`, and
`Reset-BridgeSettingToDefault`.

- [ ] **Step 1: Write failing settings tests**

Assert a numeric setting rejects values outside its schema range, an advanced
setting is hidden in simple mode, Arabic search finds the matching label or
description, and resetting one changed setting saves only that setting's
default value.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/BridgeSettingsSchema.Tests.ps1,./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: the new schema fields and helpers are missing.

- [ ] **Step 3: Extend schema and editors**

Compose constraints from existing setting metadata. Add settings-home actions
for search, modified-only, simple/advanced mode, and single-setting reset;
retain reset-all behind its existing confirmation path. Every imported value
is validated against the same schema before persistence.

- [ ] **Step 4: Verify GREEN and commit**

Run: `Invoke-Pester ./Tests/BridgeSettingsSchema.Tests.ps1,./Tests/Bridge.Tests.ps1 -Output Detailed`

Commit: `feat(v6): add advanced settings discovery and recovery`

### Task 5: Versioned runtime files, integrity, and recovery view

**Files:**
- Modify: `Modules/BridgeStateMigration.psm1`, `Modules/BridgeStorage.psm1`
- Modify: `Parts/Bridge.OnAir.ps1`, `Parts/Bridge.Schedule.ps1`, `Parts/Bridge.Tick.ps1`
- Modify: `Parts/Bridge.Admin.ps1`, `Parts/Bridge.Keyboards.ps1`
- Create: `Tests/BridgeRuntimeMigration.Tests.ps1`

**Interfaces:** Produces `Invoke-BridgeStateFileMigration` and
`Get-BridgeRuntimeFileHealth`.

- [ ] **Step 1: Write failing file-migration tests**

Use isolated TestDrive files for `onair.json`, `schedule.json`, and
`autohide.json`. Assert legacy input receives an envelope, a failed migration
does not replace the primary file, and a corrupt primary restores only a
validated backup.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/BridgeRuntimeMigration.Tests.ps1 -Output Detailed`

Expected: missing migration and runtime-health helpers.

- [ ] **Step 3: Implement transactional file migration**

Validate JSON, transform with `Invoke-BridgeStateMigration`, write a sibling
temporary file, validate it again, create a timestamped backup, and atomically
replace the primary file. Return file path, size, last write time, schema
version, and backup health for the administrative screen.

- [ ] **Step 4: Verify GREEN and commit**

Run: `Invoke-Pester ./Tests/BridgeRuntimeMigration.Tests.ps1,./Tests/BridgeStorage.Tests.ps1 -Output Detailed`

Commit: `feat(v6): migrate and report runtime state safely`

### Task 6: Role-focused navigation, health readiness, and message continuity

**Files:**
- Modify: `Parts/Bridge.Keyboards.ps1`, `Parts/Bridge.Commands.ps1`
- Modify: `Parts/Bridge.Callbacks.ps1`, `Parts/Bridge.Admin.ps1`
- Modify: `Parts/Bridge.Telegram.ps1`, `Tests/Bridge.Tests.ps1`

**Interfaces:** Produces `Get-RoleMainKeyboard`, `Get-BridgeNavigationContext`,
and `Get-BridgeReadinessSummary`.

- [ ] **Step 1: Write failing navigation tests**

Assert an operator receives on-air, templates, update, and schedule actions;
an administrator receives users, requests, settings, health, and diagnostics;
and emergency actions remain at the top for authorized roles. Assert return
actions preserve page and filter context.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Expected: role keyboard and navigation-context helpers do not exist.

- [ ] **Step 3: Implement navigation and cached readiness**

Move uncommon administrative controls behind `more` screens, add Arabic
breadcrumb text, and retain `Page`, `Filter`, and `ReturnCallback` in pending
navigation state. Health uses cached Telegram, Cinegy, output, relay, disk,
schedule, last-success, and last-error data; opening the screen does not make
a new network request.

- [ ] **Step 4: Verify GREEN and commit**

Run: `Invoke-Pester ./Tests/Bridge.Tests.ps1 -Output Detailed`

Commit: `feat(v6): add role-focused navigation and readiness`

### Task 7: Scale, latency, release, and operational acceptance

**Files:**
- Create: `Tests/BridgeVersion6Load.Tests.ps1`
- Modify: `Run-Checks.ps1`, `Build-Release.ps1`
- Modify: `README.md`, `CHANGELOG.md`, `docs/VERSION-6.md`

**Interfaces:** Consumes all Version 6 helpers and produces measured,
repeatable load acceptance results.

- [ ] **Step 1: Write failing load acceptance tests**

Generate 1,000 templates, 250 users, 200 requests, and multiple scene records
on a shared layer. Assert every keyboard remains below 100 buttons, legacy
single-mode callbacks remain present, and priority admission preserves an
emergency action before normal work.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester ./Tests/BridgeVersion6Load.Tests.ps1 -Output Detailed`

Expected: required load and multi-scene assertions are absent.

- [ ] **Step 3: Add measured acceptance thresholds**

Use `Measure-Command` around pure keyboard, scene lookup, and operation
admission helpers. Require each 1,000-template operation to complete in less
than one second on the test machine; report the measured milliseconds in the
test failure text.

- [ ] **Step 4: Update release gate and documentation**

Add the test to `Run-Checks.ps1`, add Version 6 capability/mode documentation,
and retain the final operational gates: dedicated non-production Cinegy
SHOW/HIDE/EXIT smoke test and Authenticode signing.

- [ ] **Step 5: Verify GREEN and commit**

Run: `./Run-Checks.ps1`

Commit: `test(v6): verify Version 6 scale and release acceptance`

## Completion audit

Version 6 is complete when every task above is checked, `Single` mode remains
fully backward compatible, `Multi` mode is capability-gated, all automated
checks pass, the dedicated Cinegy smoke test succeeds, and the final package
is signed or explicitly documented as an unsigned preview.
