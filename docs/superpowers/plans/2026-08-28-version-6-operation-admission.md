# Version 6 Operation Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prioritize emergency Telegram actions and reject duplicate update identifiers before they can mutate Cinegy or bridge state.

**Architecture:** A pure module assigns stable priorities and maintains a bounded update-id ledger. The polling loop orders each fetched batch through that module and admits every update exactly once; execution remains single-worker so shared PowerShell state is not made thread-unsafe.

**Tech Stack:** PowerShell 7, Pester 6

**Spec:** `docs/superpowers/specs/2026-08-28-version-6-current-experience-design.md`

## Global Constraints

- HIDE, EXIT, and hide-all callbacks outrank SHOW and administrative actions.
- Updates with equal priority preserve Telegram order.
- The duplicate ledger is bounded and in-memory; restart behavior remains governed by `DropPendingUpdatesOnStart`.
- No background runspace may access `$script:` bridge state.

---

### Task 1: Pure admission policy

**Files:** Create `Modules/BridgeOperationPolicy.psm1`; create `Tests/BridgeOperationPolicy.Tests.ps1`.

**Interfaces:** Produces `New-BridgeUpdateLedger -Capacity <int>`, `Test-BridgeUpdateAdmission -Ledger <hashtable> -UpdateId <long>`, and `Get-BridgeUpdatesForProcessing -Updates <object[]>`.

- [ ] Write tests proving ids `10,10,11` admit `true,false,true`, capacity two evicts the oldest id, and callback data `hide:7` sorts before `tpl:2` without reordering equal-priority ids.
- [ ] Run `Invoke-Pester ./Tests/BridgeOperationPolicy.Tests.ps1 -Output Detailed`; expect missing-command failures.
- [ ] Implement the bounded ledger and a stable sort on `{ Priority; OriginalIndex }`, using priority 0 for `hide:`, `hidego:`, `exit:`, `exitgo:`, and `menu:hideall`, priority 1 for other on-air callbacks, and priority 2 otherwise.
- [ ] Re-run the focused test; expect all policy tests to pass.

### Task 2: Poll-loop integration

**Files:** Modify `TelegramBridge.ps1`; modify `Run-Checks.ps1`; modify `Build-Release.ps1`; test `Tests/Bridge.Tests.ps1`.

**Interfaces:** Consumes the Task 1 module. Produces one bounded `$script:ProcessedUpdateLedger` and a sorted/admitted update loop.

- [ ] Add a test that passes a fetched batch containing admin, SHOW, then HIDE updates through the real sorter and asserts the literal id order `3,2,1`.
- [ ] Run the test and verify it fails before module import/integration.
- [ ] Import the module, initialize a 4096-id ledger, sort each fetched batch, and skip an update when `Test-BridgeUpdateAdmission` returns false.
- [ ] Add the module and test to required-file, syntax, analyzer, and release allow-lists; run the focused tests.
