# Version 6 Large-Catalogue UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep administrator Telegram keyboards bounded and navigable with hundreds or thousands of templates, users, and requests.

**Architecture:** A pure paging module calculates safe windows. Template administration, user administration, and pending approvals consume it and add page callbacks without changing item callback identities.

**Tech Stack:** PowerShell 7, Telegram inline keyboards, Pester 6

**Spec:** `docs/superpowers/specs/2026-08-28-version-6-current-experience-design.md`

## Global Constraints

- A generated Telegram keyboard stays below 100 buttons.
- Page numbers outside the valid range clamp to the nearest valid page.
- Item callbacks continue to identify the original absolute template index or user id.
- Existing callers without a page parameter render page zero.

---

### Task 1: Pure page-window helper

**Files:** Create `Modules/BridgeUiPaging.psm1`; create `Tests/BridgeUiPaging.Tests.ps1`; modify check/release allow-lists.

**Interfaces:** Produces `Get-BridgePageWindow -ItemCount <int> -Page <int> -PageSize <int>` returning `Page`, `PageCount`, `StartIndex`, `EndIndex`, `HasPrevious`, and `HasNext`.

- [x] Test empty, first, middle, last, negative, and excessive pages using literal expected boundaries.
- [x] Run focused tests and verify RED.
- [x] Implement clamping and zero-item behavior without slicing data.
- [x] Run focused tests and verify GREEN.

### Task 2: Bounded administrator catalogues

**Files:** Modify `Parts/Bridge.Keyboards.ps1`; modify `Parts/Bridge.Callbacks.ps1`; test `Tests/Bridge.Tests.ps1`.

**Interfaces:** Extends `Get-TemplateAdminCatalogueKeyboard`, `Get-UsersAdminKeyboard`, and `Get-PendingKeyboard` with optional `Page` and `PageSize`; adds `tadmpage:`, `userspage:`, and `pendingpage:` routes.

- [x] Test 1,000 templates, 250 users, and 200 requests: each first page is below 100 buttons, has a next callback, and item callbacks retain absolute identities.
- [x] Run focused tests and verify RED against the unbounded keyboards.
- [x] Slice through `Get-BridgePageWindow`, add previous/next rows, and route page callbacks through existing role guards.
- [x] Run focused and full tests, then update README, CHANGELOG, and `Get-WhatsNewSections` for `6.0.0-preview.2`.
