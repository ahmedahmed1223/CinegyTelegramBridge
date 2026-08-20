# Cinegy Telegram Bridge 3.0 Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship 3.0.0 with a complete configured-layer dashboard, Cinegy telemetry health, and deduplicated administrator alerts for external scene changes and health transitions.

**Architecture:** Extend the Cinegy wrapper with read-only metadata and telemetry parsers, then compose those results in the bridge status screen. Add two lightweight tick watchdogs that reuse the existing state reconciliation and admin broadcast boundaries; retain the current private-chat permission model unchanged.

**Tech Stack:** PowerShell 7, Cinegy Air HTTP API XML, Pester 5, PSScriptAnalyzer.

**Spec:** `docs/superpowers/plans/2026-08-20-v3-operations-spec.md`

## Global Constraints

- Do not change the current permission schema or role behavior.
- Do not send Cinegy commands from monitoring code.
- Treat unreachable state as unknown and preserve local on-air records.
- Keep alerts transition-based to avoid repeated messages.
- Use TDD for every executable behavior.

---

### Task 1: Cinegy status metadata and telemetry

**Files:**
- Modify: `Tests/Bridge.Tests.ps1`
- Modify: `CinegyAirTitler.psm1`

**Interfaces:**
- Extends: `Get-TitlerLayerStatus` with `ActiveName`, `LicenseState`, `OutputState`, `ClientConnected`, and `ClientIdentity`.
- Produces: `Get-AirTelemetryStatus -AirServerAddress -AirChannelNumber -TimeoutSec`.

- [ ] Write failing tests with literal Cinegy XML for layer metadata, healthy metrics, unhealthy counters, and unreachable metrics.
- [ ] Run focused tests and confirm failures are caused by missing fields/function.
- [ ] Implement minimal XML parsing and export the telemetry function.
- [ ] Run focused tests and the complete Pester suite.

### Task 2: Configured-layer dashboard

**Files:**
- Modify: `Tests/Bridge.Tests.ps1`
- Modify: `TelegramBridge.ps1`

**Interfaces:**
- Produces: `Get-CinegyLayerDashboard`, `Format-CinegyLayerDashboard`.
- Extends: `Update-OnAirStateFromCinegy -LayerStatuses` to reuse a dashboard sample.

- [ ] Write failing tests for on-air, hidden, external, and unknown rows.
- [ ] Run focused tests and confirm RED.
- [ ] Implement dashboard collection/formatting and reuse its samples during status reconciliation.
- [ ] Add the dashboard and telemetry summary to `Invoke-StatusCommand`.
- [ ] Run focused tests and the complete Pester suite.

### Task 3: Transition-based watchdog alerts

**Files:**
- Modify: `Tests/Bridge.Tests.ps1`
- Modify: `TelegramBridge.ps1`
- Modify: `config.example.json`

**Interfaces:**
- Produces: `Update-CinegyStateWatchdog`, `Update-CinegyHealthWatchdog`.
- Adds settings: `CinegyStateCheckSeconds`, `CinegyHealthCheckSeconds`, `NotifyAdminsOnExternalChange`, `NotifyAdminsOnCinegyHealth`.

- [ ] Write failing tests for one external-change alert, unhealthy deduplication, and recovery notification.
- [ ] Run focused tests and confirm RED.
- [ ] Implement timers, state transitions, tick registration, and polling timeout integration.
- [ ] Run focused tests and the complete Pester suite.

### Task 4: Release artifacts and verification

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `README.md`
- Create: `CHANGELOG.md`

**Interfaces:**
- Produces: version `3.0.0`, upgrade notes, and operational documentation.

- [ ] Update the runtime version and document status/health/alert behavior and unchanged two-role permissions.
- [ ] Parse `config.example.json` to verify valid JSON.
- [ ] Run `./Run-Checks.ps1` and require zero failed tests and zero analyzer errors.
- [ ] Run `git diff --check` and verify real `config.json` files are not changed.
