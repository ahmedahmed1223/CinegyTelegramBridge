# Deep Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the authorization, restoration, persistence, retry, reporting, and manager lifecycle defects confirmed by the deep review.

**Architecture:** Add execution-time guards at state boundaries, preserve atomic state transitions, and keep delayed external work out of the on-air tick path. Follow the existing pure-module plus dot-sourced integration pattern.

**Tech Stack:** PowerShell 7, Pester 5+, C#/.NET 9 WinForms.

**Spec:** `docs/superpowers/specs/2026-09-05-deep-review-fixes-design.md`

## Global Constraints

- Never issue live SHOW, HIDE, or EXIT commands during verification.
- Never read or expose the real BotToken.
- Every behavioral fix starts with a failing regression test.
- Release version and all four release-note/test locations move together.

---

### Task 1: Authorization boundaries
- [ ] Add failing tests for revoked pending flows, owner revocation, and confirmed removal access.
- [ ] Add centralized pending-flow authorization and clear revoked-user flows.
- [ ] Protect explicit owners and repeat access checks on confirmation.
- [ ] Run focused access/callback/show-flow tests.

### Task 2: Mojaz restoration and identity
- [ ] Add failing tests for current-row restoration, template image persistence, and mismatched live identity.
- [ ] Persist required restoration fields and send the current row before advancing state.
- [ ] Fail closed before automatic exit when the active identity differs or cannot be verified.
- [ ] Run Mojaz and on-air tests.

### Task 3: Atomic persistence and reports
- [ ] Add failing storage, yesterday-window, sheet-takeover, and relay-retry tests.
- [ ] Commit primary state last, validate sheet input before mutation, use exclusive report bounds, and retain relay retry intent.
- [ ] Run module, report, news, and media tests.

### Task 4: Manager lifecycle and configuration concurrency
- [ ] Add failing self-checks for restart state, timer cancellation, and permission merging.
- [ ] Start replacements after confirmed exit and coordinate configuration saves with unique temporary files and a named mutex.
- [ ] Build and run BridgeManager selftest.

### Task 5: Telegram startup and flood control
- [ ] Add failing tests for closed startup draining and nonblocking rate-limit handling.
- [ ] Persist startup drain state, restrict allowed update types, and defer rate-limited outbound notifications without sleeping the tick.
- [ ] Run Telegram and runtime tests.

### Task 6: Release gate
- [ ] Raise bridge release to 7.64.0 and update operator and maintainer documentation.
- [ ] Run `pwsh -File Run-Checks.ps1` and manager publish/selftest.
- [ ] Inspect Git status for runtime data and secrets, then commit and push.
