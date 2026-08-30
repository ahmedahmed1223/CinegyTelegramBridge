# Version 6 Merge Blockers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Version 6 safe to merge by preserving causal command order, lossless live-scene state, and real operation lifecycle tracking.

**Architecture:** Telegram update ordering becomes scope-aware and stable. Canonical scenes are kept separately from the legacy layer projection so persistence cannot discard same-layer records. The shared Cinegy mutation wrappers create and complete a bounded lifecycle record with the existing correlation identity.

**Tech Stack:** PowerShell 7, Pester 6, PSScriptAnalyzer, JSON runtime state.

**Spec:** `docs/superpowers/specs/2026-08-30-version-6-merge-blockers-design.md`

## Global Constraints

- Do not send live Cinegy SHOW/HIDE/EXIT commands.
- Keep legacy `onair.json` compatible.
- Keep HIDE and EXIT layer-level only.
- Keep execution single-worker; do not create a per-layer queue or runspaces.
- Write each behavioral test first and observe its failure before production code.
- The production `config.json` ACL is not changed.

---

### Task 1: Scope-aware Telegram ordering

**Files:**
- Modify: `Modules/BridgeOperationPolicy.psm1`
- Modify: `Tests/BridgeOperationPolicy.Tests.ps1`

**Interfaces:**
- Produces `Get-BridgeUpdateScope -Update <object>` returning `Kind` (`layer`, `global`, `unknown`) and `Layer`.
- Produces `Get-BridgeUpdatesForProcessing -Updates <object[]>` preserving dependent original order.

- [ ] **Step 1: Write failing ordering tests**

```powershell
@((Get-BridgeUpdatesForProcessing -Updates $showThenHide).update_id) | Should -Be @(100, 101)
@((Get-BridgeUpdatesForProcessing -Updates $hideThenShow).update_id) | Should -Be @(100, 101)
@((Get-BridgeUpdatesForProcessing -Updates $crossLayer).update_id) | Should -Be @(101, 100)
```

- [ ] **Step 2: Run focused test and verify failure**

Run: `Invoke-Pester -Path .\Tests\BridgeOperationPolicy.Tests.ps1`
Expected: same-layer SHOW/HIDE order currently fails because global priority sorts HIDE first.

- [ ] **Step 3: Implement minimal stable scope ordering**

```powershell
function Get-BridgeUpdateScope { ... }
function Test-BridgeUpdatesIndependent { ... }
# Move a priority-0 update only left across known, different layer scopes.
```

- [ ] **Step 4: Run focused test and verify pass**

Run: `Invoke-Pester -Path .\Tests\BridgeOperationPolicy.Tests.ps1`
Expected: PASS.

### Task 2: Lossless canonical on-air scenes

**Files:**
- Modify: `Parts/Bridge.OnAir.ps1`
- Modify: `Tests/BridgeLiveScenes.Tests.ps1`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces `$script:OnAirScenes` as canonical scene records.
- Produces `Sync-OnAirProjection` and `Set-OnAirCanonicalScenes` for layer-map compatibility.

- [ ] **Step 1: Write failing round-trip test**

```powershell
# Import canonical scene-a and scene-b on layer 7, save, reload JSON.
@($saved.Scenes | Where-Object Layer -eq 7).Count | Should -Be 2
```

- [ ] **Step 2: Run focused test and verify failure**

Run: `Invoke-Pester -Path .\Tests\Bridge.Tests.ps1 -TestName '*canonical*same layer*'`
Expected: only the primary scene survives the current layer-map save.

- [ ] **Step 3: Implement canonical state and projection synchronization**

```powershell
$script:OnAirScenes = [List[object]]::new()
function Sync-OnAirProjection { ... }
function Save-OnAirState { # serialize $script:OnAirScenes }
```

- [ ] **Step 4: Run focused tests and verify pass**

Run: `Invoke-Pester -Path .\Tests\BridgeLiveScenes.Tests.ps1, .\Tests\Bridge.Tests.ps1`
Expected: PASS.

### Task 3: Lifecycle integration

**Files:**
- Modify: `Modules/BridgeOperationLifecycle.psm1`
- Modify: `Parts/Bridge.OnAir.ps1`, `Parts/Bridge.ShowFlow.ps1`, `Parts/Bridge.Tick.ps1`
- Modify: `Tests/BridgeOperationLifecycle.Tests.ps1`, `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces `Initialize-BridgeOperationLedger`, `Start-BridgeOperation`, and `Complete-BridgeOperation`.
- Stores no more than 4096 in-memory records.

- [ ] **Step 1: Write failing lifecycle integration test**

```powershell
$operation = Get-BridgeOperationRecord -OperationId $result.OperationId
$operation.State | Should -Be 'succeeded'
```

- [ ] **Step 2: Run focused test and verify failure**

Run: `Invoke-Pester -Path .\Tests\BridgeOperationLifecycle.Tests.ps1`
Expected: helper does not yet retain or expose execution records.

- [ ] **Step 3: Implement bounded ledger and call shared Cinegy mutation wrappers**

```powershell
$operation = Start-BridgeOperation -Action $Action -Layer $Layer -ActorId $UserId
Complete-BridgeOperation -Operation $operation -State succeeded -Result $existingCorrelationId
```

- [ ] **Step 4: Run focused lifecycle and integration tests**

Run: `Invoke-Pester -Path .\Tests\BridgeOperationLifecycle.Tests.ps1, .\Tests\Bridge.Tests.ps1`
Expected: PASS.

### Task 4: Release claims and verification

**Files:**
- Modify: `docs/VERSION-6.md`, `README.md`, `CHANGELOG.md`
- Test: all Pester tests and `Run-Checks.ps1`

- [ ] **Step 1: Update documentation to describe the implemented contracts only**
- [ ] **Step 2: Run `git diff --check`**
- [ ] **Step 3: Run full `Run-Checks.ps1` and record any environment-only ACL limitation**
- [ ] **Step 4: Build and verify the release package without runtime secrets**

