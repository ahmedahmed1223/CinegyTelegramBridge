# News Ticker Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build safe Telegram management of `news.txt` through a permanent button, single-user drafts, manual editing, TXT import, atomic publishing, backup, restore, and configurable operator permissions.

**Architecture:** Add a pure `BridgeNewsTicker` module for parsing, validation, hashing, backup, and atomic file replacement. Keep Telegram workflows and authorization orchestration in `TelegramBridge.ps1`, with a persisted single draft/lock file isolated from the live news file.

**Tech Stack:** PowerShell 7, Pester 6, Telegram Bot API, JSON draft state, UTF-8 BOM text files, SHA-256.

**Spec:** `docs/superpowers/specs/2026-08-23-news-ticker-management-design.md`

## Global Constraints

- Default live path is `D:\cingy cg\ticker msg\news.txt`.
- Default separator is `|`; it is a non-empty string and may change later.
- Published text is UTF-8 with BOM.
- No edit reaches the live file before reviewed publish.
- Only one draft lock exists; administrators may cancel another user's lock after confirmation.
- Tests use `TestDrive` only and never touch the live `news.txt`.
- Audit records contain counts and operation ids, never complete news text.
- Existing private-chat-only, role, maintenance, and Telegram length safeguards remain in force.

---

### Task 1: Pure news file storage and validation

**Files:**
- Create: `Modules/BridgeNewsTicker.psm1`
- Create: `Tests/BridgeNewsTicker.Tests.ps1`
- Modify: `Run-Checks.ps1`
- Modify: `Build-Release.ps1`

**Interfaces:**
- Produces: `ConvertFrom-NewsTickerText -Text <string> -Separator <string> -MaxItemLength <int> -MaxItems <int>` returning `{ Success, Items, EmptyCount, DuplicateCount, Errors }`.
- Produces: `ConvertTo-NewsTickerText -Items <string[]> -Separator <string>` returning BOM-independent text.
- Produces: `Get-NewsTickerSnapshot -Path <string> ...` returning `{ Success, Exists, Items, Hash, LastWriteTime, Error }`.
- Produces: `Publish-NewsTickerFile -Path <string> -Items <string[]> -ExpectedHash <string> -Separator <string> -BackupDirectory <string> -BackupKeepFiles <int>` returning `{ Success, Conflict, BackupPath, Hash, Error }`.
- Produces: `Restore-NewsTickerBackup -Path <string> -BackupPath <string> ...` with the same atomic guarantees.

- [x] Write Pester tests for BOM Arabic parsing, configurable separator, line fallback import, empty/duplicate counts, limits, and order.
- [x] Run `Invoke-Pester Tests/BridgeNewsTicker.Tests.ps1` and confirm missing-command failures.
- [x] Implement pure parsing and serialization without Telegram/global state.
- [x] Add tests for hashing, external hash conflict, backup retention, atomic publish, restore, and invalid/binary UTF-8 input.
- [x] Implement snapshot, validated temporary write in the destination directory, re-read verification, atomic replace, and backup pruning.
- [x] Register module/tests in checks and release allow-list.
- [x] Run the module tests and commit `Add safe news ticker storage module`.

### Task 2: Settings, runtime paths, and persisted single draft

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `config.example.json`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces settings exactly named in the spec.
- Produces: `Import-NewsTickerDraft`, `Save-NewsTickerDraft`, `Get-NewsTickerDraft`, `Start-NewsTickerDraft`, `Touch-NewsTickerDraft`, `Remove-NewsTickerDraft`.
- Draft schema: `{ Id, OwnerUserId, OwnerChatId, OwnerName, CreatedAt, UpdatedAt, BaseHash, OriginalItems, Items, Source }`.

- [x] Test default settings, custom separator/path, isolated runtime draft path, and migration preserving configured values.
- [x] Test one-owner lock, lock display, owner reuse, second-user rejection, timeout archival, and confirmed administrator cancellation.
- [x] Run focused tests and confirm failures.
- [x] Import `BridgeNewsTicker`, define defaults/metadata, and store `news-draft.json` plus recoverable abandoned drafts under the runtime directory.
- [x] Implement atomic draft persistence using existing validated storage conventions.
- [x] Implement owner/administrator lock policy without storing editorial text in audit records.
- [x] Run focused tests and commit `Add persisted news ticker draft lock`.

### Task 3: Permanent button and read-only news screen

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces: `Get-NewsTickerManagementKeyboard`, `Show-NewsTickerManagementScreen`, `Get-NewsTickerItemsKeyboard`.
- Adds reply hotword `📰 إدارة شريط الأخبار` and callback namespace `news:*`.

- [x] Test that the third permanent reply button appears only when enabled and routes only authorized private users.
- [x] Test status text for file availability, item count, modification time, separator, lock owner/age, and external hash change.
- [x] Test paginated display and short callbacks that contain indexes but no news text.
- [x] Run focused tests and confirm failures.
- [x] Implement permanent reply routing, management screen, pagination, and role-aware keyboard visibility.
- [x] Run focused tests and commit `Add permanent news ticker management screen`.

### Task 4: Manual draft editing and reviewed publishing

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces flows: `news_add_text`, `news_edit_text`, `news_publish_review`, `news_clear_confirm`.
- Produces callbacks: `news:add`, `news:edit:<index>`, `news:delete:<index>`, `news:up:<index>`, `news:down:<index>`, `news:preview`, `news:publish`, `news:publishconfirm`, `news:cancel`.

- [x] Test add/edit/reorder/delete changing only the draft while live file hash stays unchanged.
- [x] Test duplicate, empty, long, and excess-item rejection with actionable Arabic messages.
- [x] Test preview difference counts and retained order.
- [x] Test publish hash recheck, conflict refusal, backup creation, atomic success, retry after failure, and lock release only on success.
- [x] Test operator delete permission and double-confirmed clear-all permission independently.
- [x] Run focused tests and confirm failures.
- [x] Implement manual flows, difference summary, authorization gates, and publish orchestration through module interfaces.
- [x] Add content-free structured audit and runtime logs.
- [x] Run focused tests and commit `Add reviewed manual news editing`.

### Task 5: Safe Telegram TXT import

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `Tests/Bridge.Tests.ps1`

**Interfaces:**
- Produces modes `news_import_upload` and `news_import_review`.
- Produces callbacks `news:import`, `news:importreplace`, `news:importappend`.

- [x] Test admin/operator access, `.txt` extension, Telegram file-size bound, traversal-safe download destination, binary rejection, invalid UTF-8 rejection, separator parsing, line fallback, and cleanup.
- [x] Test review counts for valid, empty, duplicate, and rejected items.
- [x] Test replace and deduplicated append modifying only the draft.
- [x] Run focused tests and confirm failures.
- [x] Implement bounded Telegram document download using the existing transport helper and an explicit temporary path.
- [x] Parse via `BridgeNewsTicker`, show review, apply selected mode, and always remove temporary uploads.
- [x] Run focused tests and commit `Add reviewed TXT news import`.

### Task 6: Backup browser, restore, lock administration, and documentation

**Files:**
- Modify: `TelegramBridge.ps1`
- Modify: `Tests/Bridge.Tests.ps1`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `DEVELOPMENT-PLAN.md`
- Modify: `RELEASE.md`

**Interfaces:**
- Produces callbacks `news:backups`, `news:restore:<index>`, `news:restoreconfirm`, `news:unlock`, `news:unlockconfirm`.

- [x] Test bounded backup listing, restore preview, operator restore permission, confirmed atomic restore, and preserving current live file as a backup.
- [x] Test administrator-only foreign-lock cancellation and archival of the cancelled draft.
- [x] Test clear-all double confirmation for administrator and opted-in operator.
- [x] Run focused tests and confirm failures.
- [x] Implement backup/restore and lock administration screens.
- [x] Document settings, workflows, permissions, recovery, and external-change conflicts.
- [x] Bump bridge version and add release notes.
- [x] Run focused tests and commit `Complete news ticker administration`.

### Task 7: Release verification and live-safe handoff

**Files:**
- Verify all changed files.

**Interfaces:**
- Consumes every prior task; produces a release artifact with no live news, config, logs, drafts, or backups.

- [x] Record SHA-256 and timestamp of live `news.txt` and `logs/onair.json`.
- [x] Run `Run-Checks.ps1`; require parser success, zero Analyzer errors, and zero Pester failures.
- [x] Confirm both live-file hashes and timestamps are unchanged by tests.
- [x] Build the allow-listed release ZIP and inspect entries for forbidden runtime/editorial files.
- [x] Perform a smoke test against a temporary copied news file, not the live path.
- [x] Commit release changes and verify a clean tracked worktree.
- [x] Restart only after explicit operational approval; verify Telegram startup and read-only news status before any live publish.


> **الحالة:** مُنجَزة ومشحونة. الميزة تعمل في الإنتاج عبر
> `Modules/BridgeNewsTicker.psm1` وشاشات الأخبار في `Parts/Bridge.News.ps1`،
> ويغطيها `Tests/BridgeNewsTicker.Tests.ps1` مع Describe الأخبار في
> `Tests/Bridge.NewsScreens.Tests.ps1`. الصناديق أُشّرت بأثر رجعي بعد التحقق
> من الكود، لا من الخطة.