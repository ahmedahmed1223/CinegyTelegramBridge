# Mojaz Bulletin Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single Mojaz table with a persistent named bulletin library, reusable schedules, immutable playback snapshots, and a no-overlap FIFO queue.

**Architecture:** Put pure bulletin, schedule, migration, validation, and playback-plan rules in `Modules/BridgeMojaz.psm1`. Keep persistence and Telegram/Cinegy orchestration in `Parts/Bridge.Mojaz.ps1`, reuse `BridgeStorage` for validated atomic JSON, and preserve the current scene-derived timing work behind the new per-bulletin model.

**Tech Stack:** PowerShell 7, Pester 6, Telegram Bot API, Cinegy Air Titler, validated JSON storage.

**Spec:** `docs/superpowers/specs/2026-09-02-mojaz-bulletin-library-design.md`

## Global Constraints

- Schedules resolve the latest saved bulletin revision only when playback starts.
- Active playback uses a deep immutable snapshot and never rereads editable rows.
- Only one Mojaz run may be active; due schedules queue FIFO by original due time.
- Existing `mojaz.json` migrates without data loss and remains recoverable.
- Persistence failures leave the prior in-memory state intact and never report success.
- Existing uncommitted scene-timing changes are preserved when tests prove them compatible.
- Tests use `TestDrive` and do not touch production state or media.

---

### Task 1: Pure Mojaz domain module

**Files:**
- Create: `Modules/BridgeMojaz.psm1`
- Create: `Tests/BridgeMojaz.Tests.ps1`
- Modify: `TelegramBridge.ps1`
- Modify: `Run-Checks.ps1`
- Modify: `Build-Release.ps1`

**Interfaces:**
- Produces `New-MojazLibrary`, `New-MojazBulletin`, `Copy-MojazBulletin`, `Rename-MojazBulletin`, `Set-MojazBulletinRows`, and `Remove-MojazBulletin`.
- Produces `New-MojazRunSnapshot -Bulletin -SceneTiming -Schedule` with copied rows and calculated transitions.
- Produces `Get-MojazDueQueue -Schedules -Now` ordered by `ScheduledAt`, `CreatedAt`, then `Id`.
- Produces structured results `{ Success, Value, ErrorCode, Error }`.

- [ ] **Step 1: Write failing Pester tests** for unique normalized names, revision increments, copying, immutable snapshots, single/multi-row plans, and stable queue ordering.
- [ ] **Step 2: Run** `Invoke-Pester Tests/BridgeMojaz.Tests.ps1` and verify missing-command failures.
- [ ] **Step 3: Implement the minimal pure module** with no Telegram, filesystem, Cinegy, or script-scope dependencies.
- [ ] **Step 4: Register the module and test** in startup, checks, and release allow-list.
- [ ] **Step 5: Run the focused tests** and require all pass.
- [ ] **Step 6: Commit** `feat: add Mojaz bulletin domain module`.

### Task 2: Atomic library storage and legacy migration

**Files:**
- Modify: `Parts/Bridge.Mojaz.ps1`
- Modify: `Tests/Bridge.Mojaz.Tests.ps1`
- Modify: `TelegramBridge.ps1`

**Interfaces:**
- Produces `Get-MojazLibraryFile`, `Get-MojazSchedulesFile`, `Import-MojazLibrary`, `Save-MojazLibrary`, and `Save-MojazSchedules`.
- Migration maps the old singleton to a bulletin named `الموجز الحالي`, revision 1, with blank images mapped to `inherit`.

- [ ] **Step 1: Add failing tests** for empty startup, validated primary/backup recovery, legacy field preservation, migration failure, and save rollback.
- [ ] **Step 2: Run focused tests** and confirm failures describe missing storage behavior.
- [ ] **Step 3: Replace local `Set-Content` persistence** with `Write-BridgeValidatedJson` and read through `Read-BridgeValidatedJson`.
- [ ] **Step 4: Implement one-time migration** that archives the legacy file only after verified library save.
- [ ] **Step 5: Change mutation operations** to clone, validate, persist, then publish the new in-memory state.
- [ ] **Step 6: Run focused tests** and require pass.
- [ ] **Step 7: Commit** `feat: persist named Mojaz bulletins safely`.

### Task 3: Bulletin library Telegram screens

**Files:**
- Modify: `Parts/Bridge.Mojaz.ps1`
- Modify: `Parts/Bridge.Callbacks.ps1`
- Modify: `TelegramBridge.ps1`
- Modify: `Tests/Bridge.Mojaz.Tests.ps1`

**Interfaces:**
- Produces `Show-MojazLibraryScreen`, `Get-MojazLibraryKeyboard`, `Show-MojazBulletinScreen`, and short callbacks using bulletin ids/page indexes.
- Produces pending modes for create, copy, and rename.

- [ ] **Step 1: Add failing screen tests** for empty library, pagination, counts, last update, upcoming schedules, and no editorial text in callbacks.
- [ ] **Step 2: Add failing workflow tests** for create, open, copy, rename, duplicate-name rejection, and persistence failure messaging.
- [ ] **Step 3: Implement library and detail screens** while retaining rich-message fallback.
- [ ] **Step 4: Route callbacks and pending text flows** through existing authorization and private-chat gates.
- [ ] **Step 5: Run focused tests** and require pass.
- [ ] **Step 6: Commit** `feat: add named Mojaz library screens`.

### Task 4: Safe row editing, image policy, and per-bulletin lock

**Files:**
- Modify: `Parts/Bridge.Mojaz.ps1`
- Modify: `Parts/Bridge.Callbacks.ps1`
- Modify: `Tests/Bridge.Mojaz.Tests.ps1`

**Interfaces:**
- Produces add/edit/delete/up/down actions addressed by stable row ids.
- Produces image modes `new`, `inherit`, and `default`.
- Produces one edit lock per bulletin with owner and last activity.

- [ ] **Step 1: Add failing tests** for row editing/reorder, all image modes, safe path validation, title/text bounds, and failed-save rollback.
- [ ] **Step 2: Add failing lock tests** for two users on different bulletins, refusal on the same bulletin, expiry, and confirmed admin release.
- [ ] **Step 3: Implement row and image workflows** including explicit labels for inherited/default images.
- [ ] **Step 4: Implement per-bulletin edit locks** without blocking read-only screens or playback.
- [ ] **Step 5: Run focused tests** and require pass.
- [ ] **Step 6: Commit** `feat: add safe Mojaz bulletin editing`.

### Task 5: Persistent reusable schedules and conflict queue

**Files:**
- Modify: `Parts/Bridge.Mojaz.ps1`
- Modify: `Parts/Bridge.Callbacks.ps1`
- Modify: `Parts/Bridge.Tick.ps1`
- Modify: `Tests/Bridge.Mojaz.Tests.ps1`

**Interfaces:**
- Produces `Add-MojazSchedule`, `Cancel-MojazSchedule`, `Update-MojazScheduleQueue`, and `Start-NextQueuedMojazSchedule`.
- States are `scheduled`, `queued`, `running`, `completed`, `cancelled`, and `failed`.

- [ ] **Step 1: Add failing tests** for multiple dates targeting one bulletin, latest-revision resolution at start, cancellation, persistence, and restart recovery.
- [ ] **Step 2: Add failing conflict tests** for no overlap, one delay notice, FIFO order, multiple same-bulletin appointments, and manual queue confirmation.
- [ ] **Step 3: Implement schedule storage and UI** with original due time retained.
- [ ] **Step 4: Replace the in-memory single `MojazStartAt` promise** with persisted entries and queue state transitions.
- [ ] **Step 5: Connect Tick to the new queue evaluator** while keeping generic schedule policy patterns.
- [ ] **Step 6: Run focused tests** and require pass.
- [ ] **Step 7: Commit** `feat: queue reusable Mojaz schedules`.

### Task 6: Immutable playback and scene-derived timing integration

**Files:**
- Modify: `Parts/Bridge.Mojaz.ps1`
- Modify: `Tests/Bridge.Mojaz.Tests.ps1`
- Modify: `Tests/BridgeMojaz.Tests.ps1`

**Interfaces:**
- `Start-MojazPlayback` consumes a bulletin id or queued schedule and stores the full run snapshot.
- `Update-MojazPlayback` consumes snapshot rows/transitions only.
- Completion/failure updates schedule state and starts the next queued item only after safe layer exit.

- [ ] **Step 1: Add failing regression tests** for delete/clear/edit during playback, one-row timing, current-vs-latest revisions, postbox failure, and blocked EXIT.
- [ ] **Step 2: Validate existing scene timing tests** and retain `Get-MojazSceneTiming` behavior where compatible.
- [ ] **Step 3: Refactor start/update/stop** to use the immutable run snapshot and one shared playback plan.
- [ ] **Step 4: Disable unsafe current-run actions** while allowing edits that clearly target future runs.
- [ ] **Step 5: Start the next queued schedule** only after exit/layer availability is confirmed.
- [ ] **Step 6: Run both Mojaz test files** and require pass.
- [ ] **Step 7: Commit** `fix: isolate Mojaz playback from live edits`.

### Task 7: Deletion choices and orphan image cleanup

**Files:**
- Modify: `Parts/Bridge.Mojaz.ps1`
- Modify: `Parts/Bridge.Callbacks.ps1`
- Modify: `Parts/Bridge.Tick.ps1`
- Modify: `Tests/Bridge.Mojaz.Tests.ps1`

**Interfaces:**
- Produces delete review, cancel-all-and-delete, and transfer-all-and-delete flows.
- Produces `Update-MojazImageCleanup` using references from every bulletin and the active snapshot.

- [ ] **Step 1: Add failing tests** for deletion without schedules, deletion choices, transfer validation, active-run refusal, and atomic cross-file rollback.
- [ ] **Step 2: Add failing cleanup tests** for referenced/shared/current-run/recent files and old orphan deletion.
- [ ] **Step 3: Implement reviewed deletion and transfer** with schedule/library writes treated as one recoverable operation.
- [ ] **Step 4: Implement bounded orphan cleanup** with safety age and upload-root containment.
- [ ] **Step 5: Run focused tests** and require pass.
- [ ] **Step 6: Commit** `feat: complete Mojaz lifecycle management`.

### Task 8: Documentation and release verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `DEVELOPMENT-PLAN.md`
- Modify: `RELEASE.md`
- Modify: `TelegramBridge.ps1`

**Interfaces:**
- Documents library, latest-update schedule semantics, queue behavior, migration, recovery, permissions, and image modes.

- [ ] **Step 1: Update operator documentation** with the exact Telegram workflow and conflict messages.
- [ ] **Step 2: Update technical/release documentation** and bump the bridge version after behavior is complete.
- [ ] **Step 3: Run parser and PSScriptAnalyzer** and fix all errors introduced by this work.
- [ ] **Step 4: Run the full Pester suite** outside the restricted registry sandbox if required.
- [ ] **Step 5: Build and inspect the release ZIP** for the new module and absence of runtime JSON/media.
- [ ] **Step 6: Review the combined diff** and verify only intended pre-existing Mojaz changes were incorporated.
- [ ] **Step 7: Commit** `feat: ship Mojaz bulletin library`.
