# Version 6 Health Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give administrators one concise screen for Telegram, Cinegy, output monitoring, relay, storage, schedules, and recent errors.

**Architecture:** A formatter consumes the bridge's existing runtime state and diagnostic snapshot; it performs no new network calls. A role-gated menu entry and callback render the report with refresh, full-status, diagnostics, and back controls.

**Tech Stack:** PowerShell 7, Telegram inline keyboards, Pester 6

**Spec:** `docs/superpowers/specs/2026-08-28-version-6-current-experience-design.md`

## Global Constraints

- Opening the center must not block on new Cinegy, ffmpeg, or Telegram probes.
- Healthy, warning, and unavailable states use consistent `🟢`, `🟠`, and `🔴` markers.
- The entry and callback are administrator/owner only through the existing admin guard.

---

### Task 1: Health summary and keyboard

**Files:** Modify `Parts/Bridge.Admin.ps1`; modify `Parts/Bridge.Keyboards.ps1`; test `Tests/Bridge.Tests.ps1`.

**Interfaces:** Produces `Get-BridgeHealthCenterText` and `Get-HealthCenterKeyboard`.

- [x] Test literal component headings and that stale/unavailable Telegram or Cinegy data produces a non-green marker without making external calls.
- [x] Run the focused test and verify RED.
- [x] Build the summary from `$script:RuntimeState`, on-air/schedule counts, relay state, and `Get-DiagnosticWarnings`; build refresh/full-status/diagnostics/back buttons.
- [x] Run focused tests and verify GREEN.

### Task 2: Administrator navigation

**Files:** Modify `Parts/Bridge.Keyboards.ps1`; modify `Parts/Bridge.Callbacks.ps1`; test `Tests/Bridge.Tests.ps1`.

**Interfaces:** Produces `Invoke-HealthCenterCommand -ChatId <long> -UserId <long>` and `menu:healthcenter` routing.

- [x] Test that Admin Tools contains the health-center callback, an administrator receives the screen, and an operator cannot invoke it.
- [x] Run tests and verify RED.
- [x] Add the button, command, and guarded callback using `Test-CallbackAdmin`.
- [x] Run focused tests and verify GREEN.
