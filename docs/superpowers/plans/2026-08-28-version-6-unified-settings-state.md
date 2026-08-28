# Version 6 Unified Settings and State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every setting one consumable schema record and introduce tested version-migration primitives for persisted runtime state.

**Architecture:** A pure settings-schema module composes existing defaults and metadata into immutable records without changing `config.json`. A second pure module upgrades version-tagged state envelopes and accepts legacy documents as version zero; existing runtime formats stay readable while migrations gain a single tested contract.

**Tech Stack:** PowerShell 7, JSON, Pester 6

**Spec:** `docs/superpowers/specs/2026-08-28-version-6-current-experience-design.md`

## Global Constraints

- Existing configuration keys and values remain unchanged.
- Unknown settings fall back to Advanced with their technical key as label.
- Legacy unwrapped state is treated as schema version zero.
- Migration never overwrites a primary file until the transformed document validates.

---

### Task 1: Consumable settings schema

**Files:** Create `Modules/BridgeSettingsSchema.psm1`; create `Tests/BridgeSettingsSchema.Tests.ps1`; modify `TelegramBridge.ps1`; modify `Parts/Bridge.Keyboards.ps1`.

**Interfaces:** Produces `New-BridgeSettingSchema` returning records with `Name`, `Default`, `ValueType`, `Category`, `Label`, `Unit`, `Description`, `Protected`, and `Choices`.

- [x] Test a protected boolean, constrained string, numeric setting, and unknown metadata fallback with literal expected records.
- [x] Run the focused test and verify missing-command failures.
- [x] Implement schema composition from explicit input maps, then initialize `$script:SettingSchema` after current metadata and make navigation helpers read it.
- [x] Test that schema names equal `$script:DefaultSettings.Keys` exactly and run the focused suite.

### Task 2: Versioned state migration primitives

**Files:** Create `Modules/BridgeStateMigration.psm1`; create `Tests/BridgeStateMigration.Tests.ps1`; modify release/check allow-lists.

**Interfaces:** Produces `ConvertTo-BridgeStateEnvelope -Data <object> -Version <int>` and `Invoke-BridgeStateMigration -Document <object> -TargetVersion <int> -Migrations <hashtable>`.

- [x] Test legacy data as version zero, a two-step `0→1→2` migration, rejection of a missing step, and rejection of a document newer than the target.
- [x] Run the test and verify RED.
- [x] Implement an envelope `{ SchemaVersion; Data }`, sequential migration lookup by current integer version, and structured `{ Success; Version; Data; Error }` results.
- [x] Register new files in checks/releases and run focused tests.
