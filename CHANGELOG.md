# Changelog

## 4.2.32 — 2026-08-22

- Added an administrator-configured template test layer, disabled by default.
- Required the test layer to be absent from every production template
  definition and verified directly with Cinegy that it is empty before SHOW.
- Added administrator review and confirmation, synthetic `TEST` field values,
  explicit `BotTest` tracking, and a mandatory 3-300 second automatic hide.
- Added field-level before/after comparison to template-definition review and
  stated that the existing timestamped backup is created before saving.
- Added regression tests for production-layer rejection, occupied/uncertain
  layer blocking, isolated SHOW targeting, automatic hide, and comparison.

## 4.2.31 — 2026-08-22

- Added administrator template-registry export through Telegram.
- Added opt-in full-management import of JSON documents up to 1 MiB, with
  bounded download, safe Telegram file-path validation, and temporary staging.
- Validated every template key, absolute `.cintitle` path, positive layer, and
  field name before showing added/changed/removed/unchanged counts.
- Required an explicit confirmation before atomic replacement and created a
  timestamped backup of the previous registry.
- Blocked imports that change or remove a template currently on air or used by
  an upcoming schedule, and removed staged files on cancellation or expiry.

## 4.2.30 — 2026-08-22

- Added private per-user template search across key, description, and optional
  category without changing stable callback indexes.
- Added category browsing and documented optional `category` values in the
  example registry and administrator definition editor.
- Added a non-mutating template detail preview before SHOW selection.
- Persisted and displayed the local time of each template's last successful
  use while remaining compatible with legacy integer usage counters.

## 4.2.29 — 2026-08-22

- Added opt-in CurrentUser DPAPI storage for the bot token and live-stream
  source/destination URLs; the existing plaintext configuration remains the
  disabled-by-default behavior.
- Added the protected administrator setting `EnableDpapiSecrets` and an
  explicit `Protect-BridgeSecrets.ps1` migration command.
- Persisted only `dpapi:` references while enabled and prevented later config
  saves from leaking decrypted values back to JSON.
- Protected the encrypted store and the pre-migration backup with the same
  strict Windows ACL, and excluded both from Git and release packages.
- Added DPAPI round-trip, no-plaintext, migration, activation, deactivation,
  and default-off regression tests.

## 4.2.28 — 2026-08-22

- Added Windows ACL enforcement for `config.json`, its fallback copy, and all
  versioned configuration backups at startup and after save or restore.
- Restricted access to the bridge runtime identity, Local System, and the
  built-in Administrators group using stable Windows security identifiers.
- Added an integration test that verifies protected inheritance and the exact
  allow-list on temporary files and directories.

## 4.2.27 — 2026-08-22

- Extended the administrator-confirmed runtime cleanup to all direct `.log`
  files in `logs`, including bridge rotations and relay stdout/stderr logs.
- Kept `audit.jsonl`, `onair.json`, schedules, templates, backups, and
  diagnostic subdirectories outside runtime-log cleanup.
- Retained a fresh audit record after either runtime or audit cleanup.

## 4.2.26 — 2026-08-22

- Added Windows/PowerShell 7 GitHub Actions for parser, PSScriptAnalyzer, and
  Pester verification on pushes and pull requests.
- Persisted NUnit-format Pester results and uploaded verification artifacts.
- Added an allow-listed release builder that excludes live configuration,
  templates, logs, backups, snapshots, audit history, and on-air state.
- Added a release manifest, ZIP SHA-256 sidecar, and optional Authenticode
  signing using a Windows certificate thumbprint.
- Documented checksum/signature verification, side-by-side upgrade, and safe
  rollback preserving validated runtime state.
- Added automated package allow-list, manifest, and checksum tests.

## 4.2.25 — 2026-08-22

- Added `TelegramRequestTimeoutSeconds` with a 15-second default for
  `sendMessage`, `sendPhoto`, and `sendDocument`.
- Retained one bounded retry for transient Telegram send failures.
- Kept long polling on its independent poll timeout.
- Added send retry and timeout propagation tests for text and multipart
  uploads, completing the existing HTTP, Cinegy timeout, disk-failure, and
  corrupt-JSON coverage.

## 4.2.24 — 2026-08-22

- Counted field limits using Unicode text elements rather than UTF-16 code
  units, so emoji and Arabic combining marks match what operators see.
- Added Unicode-safe Telegram chunk boundaries that never split surrogate
  pairs or ordinary combining sequences.
- Preserved the existing 3500-code-unit Telegram safety ceiling.
- Added emoji, Arabic diacritic, invalid-surrogate, long-line, XML-special,
  and message-loss regression coverage.

## 4.2.23 — 2026-08-22

- Added `SchedulePaused` to keep all events pending without executing or
  deleting them.
- Added optional `SchedulePreNotifyMinutes` notifications, disabled by default,
  with one notification per occurrence.
- Added reviewed recurrence end dates for daily and weekly events, including
  validation that the end does not precede the first occurrence.
- Completed recurring events after their next local occurrence exceeds the
  configured end date.
- Preserved recurrence end dates during copy and edit operations.
- Added pause, notification de-duplication, recurrence completion, and UI flow
  coverage.

## 4.2.22 — 2026-08-22

- Added copy and edit-time buttons for each pending schedule event.
- Required a new local time followed by the existing schedule review before
  either mutation is saved.
- Kept the original event unchanged when copying and generated a fresh event
  id for the copy.
- Preserved the stable event id when editing time and reset stale execution or
  retry state only after an atomic save succeeds.
- Added full timezone ids to event summaries in addition to numeric offsets.
- Restricted copy/edit to the event owner or an administrator.
- Added copy isolation, edit identity, and timezone summary tests.

## 4.2.21 — 2026-08-22

- Required template paths to be absolute and use the `.cintitle` extension;
  existence is intentionally not checked because the path may belong to the
  remote Cinegy server.
- Excluded invalid template definitions from SHOW controls and exposed their
  keys and reasons through existing health warnings.
- Reported layers shared by multiple templates as allowed informational data,
  preserving the operational rule that one layer may host many templates.
- Retained scheduled-event proximity warnings as the actual layer conflict
  detector.
- Added invalid-path and shared-layer regression tests.

## 4.2.20 — 2026-08-22

- Added a private, in-memory recent operation history keyed by Telegram user
  id and capped at 20 records per user.
- Excluded editorial field values from operation history.
- Added the `🧾 عملياتي` screen and `/myoperations` (`/myops`) command with
  success, blocked, and failure guidance.
- Added a safe retry button that restores the same user's last SHOW values
  into the confirmation screen without sending directly to Cinegy.
- Added user-isolation, content-minimization, and no-direct-send retry tests.

## 4.2.19 — 2026-08-22

- Added shared validated JSON state read/write helpers with atomic temporary
  files and a last-known-good `.bak` copy.
- Applied automatic corruption recovery to `onair.json` and `schedule.json`.
- Repaired the primary state file from its validated backup during import.
- Preserved current in-memory state when neither primary nor backup can be
  parsed instead of replacing it with an empty collection.
- Added corruption and recovery tests alongside existing Cinegy/Telegram
  outage, recovery-notification, and interrupted-schedule coverage.

## 4.2.18 — 2026-08-22

- Added `SensitiveTemplateKeys` and `SensitiveTemplateAutoHideSeconds`.
- Enforced an automatic-hide timer for configured sensitive templates through
  ordinary, preset, and scheduled SHOW execution.
- Treated the administrator duration as the maximum on-air lifetime while
  retaining a shorter operator-selected timer.
- Replaced an existing timer on the same layer instead of stacking timers that
  could hide a later scene.
- Added mandatory timer and duration-bound regression tests.

## 4.2.17 — 2026-08-22

- Added an administrator-only redacted diagnostic ZIP via the diagnostics
  screen and `/diagbundle`.
- Limited bundle contents to `summary.json` and the latest 200 sanitized
  runtime lines; configuration, on-air state, schedules, templates, and audit
  history are never packaged.
- Removed bot credentials and stable user/chat/from/admin identifiers from
  exported text.
- Deleted the generated ZIP locally after the Telegram send attempt.
- Corrected runtime-path isolation so diagnostics and cleanup always target
  the selected runtime directory.
- Added bundle allow-list, redaction, and administrator delivery tests.

## 4.2.16 — 2026-08-22

- Added administrator-only buttons to clear runtime logs or the structured
  audit history independently.
- Required a fresh, expiring, per-administrator confirmation before deletion.
- Kept `onair.json`, schedules, templates, and backups outside cleanup scope.
- Recreated an audit record after cleanup identifying the administrator and
  selected history type.
- Added configurable low-disk, runtime-storage, and backup-storage warnings to
  administrator diagnostics.
- Added stricter diagnostic text redaction for user/chat/from/admin identifiers.
- Added confirmation, cleanup isolation, audit recreation, warning, and
  redaction regression tests.

## 4.2.15 — 2026-08-22

- Added the independent permanent `logs/audit.jsonl` audit trail.
- Recorded UTC timestamp, correlation id, event, result, actor, action, layer,
  target, duration, and redacted message as one machine-readable JSON object
  per line.
- Reused each air-control operation id in its structured audit record while
  retaining the human-readable `AIR_OP` runtime entry in `bridge.log`.
- Persisted general in-chat audit activity independently from the bounded
  in-memory list.
- Included the audit file size in administrator diagnostics.
- Added correlation, persistence, single-line, and secret-redaction tests.
- Suppressed helper return values such as `True` at the runtime orchestration
  boundary while preserving actual operational log lines in the terminal.

## 4.2.14 — 2026-08-22

- Added bridge build-file time and process uptime to administrator diagnostics.
- Added processor architecture, working-set memory, private memory, and free
  disk capacity.
- Added byte-derived sizes for configuration, templates, on-air state,
  schedule state, schedule execution history, and bridge log files.
- Added in-memory success, failure, and blocked counters for air-control
  operations without reparsing logs.
- Kept diagnostics administrator-only and passed all output through existing
  secret redaction.
- Added diagnostic content and counter regression coverage.

## 4.2.13 — 2026-08-22

- Changed opted-in scheduled retry delays from fixed to exponential backoff.
- Added `ScheduleRetryBackoffFactor` with a default factor of 2.
- Added `ScheduleRetryMaxDelaySeconds` with a default cap of 300 seconds.
- Normalized invalid timing values to a positive bounded delay.
- Added deterministic growth and cap regression coverage.

## 4.2.12 — 2026-08-22

- Added independent `logs/schedule-execution.jsonl` execution history.
- Recorded timestamp, event and execution ids, template, layer, scheduled time,
  attempt number, result, duration, and sanitized error for every scheduled
  SHOW attempt.
- Excluded template field names and editorial values from the execution log.
- Logged retry attempts independently while preserving `schedule.json` as the
  current schedule state.
- Added persistence and privacy regression coverage for the JSONL record.

## 4.2.11 — 2026-08-22

- Added `ScheduleMaxRetries` and `ScheduleRetryDelaySeconds` settings.
- Kept retries disabled by default (`ScheduleMaxRetries = 0`) to avoid
  surprising delayed graphics on air.
- Persisted attempt count, next-attempt time, and last failure reason with each
  scheduled event.
- Deferred retries until their configured time and cleared retry state after a
  successful recurring occurrence.
- Preserved the existing no-replay rule for occurrences interrupted while
  marked `running` across a bridge restart.
- Added deterministic retry-delay regression coverage.

## 4.2.10 — 2026-08-22

- Added same-layer scheduled-event conflict detection.
- Added configurable `ScheduleConflictWindowMinutes`, defaulting to two
  minutes.
- Stored the resolved layer with new schedule events while retaining fallback
  lookup compatibility for older persisted events.
- Displayed each conflicting template and time in schedule review before the
  operator confirms the event.
- Added coverage for same-layer conflicts, different-layer non-conflicts, and
  the Telegram review warning.

## 4.2.9 — 2026-08-22

- Added administrator-editable `ReservedLayers` and `DisabledTemplateKeys`
  settings.
- Blocked SHOW preparation and final execution for reserved layers and
  temporarily disabled templates before any Cinegy query or mutation.
- Kept HIDE and EXIT available for reserved layers so operators can still take
  content off air safely.
- Applied the central execution policy to scheduled and interactive SHOW paths.
- Added regression coverage proving blocked policies send no Cinegy command.

## 4.2.8 — 2026-08-22

- Added a unique `air-*` correlation id to every SHOW, HIDE, EXIT, and live
  UPDATE attempt.
- Added a single structured `AIR_OP` bridge-log result containing action,
  result, duration, operator, chat, layer, target, and sanitized failure reason.
- Recorded blocked maintenance and uncertain-Cinegy attempts as well as
  successful and failed commands.
- Kept historical operation records in `bridge.log`; `onair.json` remains live
  state only.
- Added regression coverage for successful and blocked operation records.

## 4.2.7 — 2026-08-22

- Added a direct target-layer verification immediately before every SHOW.
- Blocked SHOW when Cinegy cannot confirm the target layer instead of assuming
  an unreachable layer is safe.
- Reconciled the verified layer with `onair.json` before any replacement or
  pre-show hide action.
- Added regression coverage proving that an uncertain layer sends no SHOW
  command and does not run reconciliation on an invalid response.

## 4.2.6 — 2026-08-22

- Added the currently tracked scene to SHOW review before a layer replacement.
- Identified whether that scene came from Cinegy Air, the bot, or a named
  operator.
- Added an explicit warning when the layer state sample is not fresh enough to
  trust during review.
- Added regression coverage for replacement and uncertain-state warnings.

## 4.2.5 — 2026-08-22

- Added explicit Cinegy state freshness classification: connected, stale,
  unavailable, or unknown.
- Added `CinegyStateStaleSeconds` with a 45-second default threshold.
- Displayed the classification in both the operator status and administrator
  full-status views.
- Added deterministic tests for all four classifications.

## 4.2.4 — 2026-08-22

- Added an administrator-controlled maintenance mode in Settings.
- Maintenance mode blocks SHOW, ordinary HIDE, EXIT, live-value updates, and
  creation or execution of scheduled SHOW operations without altering current
  on-air scenes.
- Due scheduled events remain pending and resume after maintenance is disabled.
- The administrator-only emergency hide-all action remains available during
  maintenance.
- Added regression coverage proving that blocked controls do not send Cinegy
  commands and that the emergency override is restricted to the hide-all path.

## 4.2.3 — 2026-08-22

- Added `logs/user-profiles.json` with approval time, approving administrator,
  and last authorized activity time; message content is never stored.
- Existing users receive unknown historical metadata until their first new
  activity instead of invented timestamps.
- User management now displays last activity, and revocation removes the
  runtime profile while preserving the audit event.
- Activity persistence is atomically flushed at most once per minute to keep
  disk writes out of the high-frequency interaction path.
- Added regression coverage for approval metadata, authorized-only activity,
  and profile cleanup on revocation.

## 4.2.2 — 2026-08-22

- Added an administrator user-management screen with Alias, role, and active
  or disabled state for every authorized private-chat user.
- Added persistent temporary disable/enable state in
  `logs/disabled-users.json` without deleting whitelist entries.
- Added confirmed permission revocation across chat/user and operator/admin
  lists, with audit logging.
- Prevented revoking or disabling the final active administrator.
- Added regression coverage for disabled authorization, unique user listing,
  confirmation, revocation, and final-administrator protection.

## 4.2.1 — 2026-08-22

- Added `HealthFailureAlertThreshold` (default 3) for consecutive Cinegy and
  Telegram failures before notifying administrators.
- Outages now produce one alert and one recovery message without repeats.
- Full health status includes the consecutive failure count and outage start.
- On-air status distinguishes `🟣 Cinegy Air` external or scheduled scenes
  from `🔵 Bot · operator` scenes created through Telegram.
- Successful HIDE and EXIT commands read the affected Cinegy layer and
  reconcile `onair.json` from the confirmed result.
- Added regression coverage for thresholding, deduplication, recovery, and
  clearing outage state.

## 4.2.0 — 2026-08-22

- Added independently editable per-user favourites in `logs/favorites.json`.
- Kept usage-ranked templates as fallback and added the disabled
  `SharedFavoritesEnabled` placeholder for a future unified list.
- Added persistent operator aliases in `logs/user-aliases.json`, managed by
  `/alias USER_ID name` and displayed in status and audit text.
- Added regression coverage for user isolation, removal, invalid templates,
  alias normalization, and alias removal.
- Expanded the development backlog to retain all previously proposed items.

## 4.1.2 — 2026-08-22

- Fixed the Pester harness writing synthetic template records into the live
  `logs/onair.json` file while `Run-Checks.ps1` was running.
- Added an explicit `RuntimePath` parameter so tests isolate `onair.json`,
  schedules, drafts, recent values, usage data, relay state, snapshots, and
  `bridge.log` inside Pester's `TestDrive`.
- Added a release-gate regression test that fails if test persistence points
  at the live `logs` directory.
- Verified the live `onair.json` hash and timestamp remain unchanged across the
  complete 146-test suite.

## 4.1.1 — 2026-08-22

- Added a full Cinegy layer comparison during bridge startup before operator
  commands are accepted.
- Startup now discovers scenes launched directly from Cinegy and restores them
  to `onair.json` as current, hideable state.
- Unreachable startup layers preserve their previous local records and produce
  an explicit warning in `bridge.log` rather than being treated as hidden.
- Added a startup reconciliation summary to `bridge.log` with checked, added,
  and removed counts.
- Added regression coverage for full startup discovery and uncertain-layer
  preservation. Existing restart tests continue to verify scheduled
  occurrences are not replayed after a service restart.

## 4.1.0 — 2026-08-22

- Added an operator-triggered live reconciliation against every Cinegy GFX
  layer referenced by `templates.json` from both Status and the Layers panel.
- Scenes started directly in Cinegy are discovered, recorded in `onair.json`
  with `Source: cinegy`, and exposed to operators for HIDE/EXIT actions.
- Kept `onair.json` as current operational state only; historical actions and
  detailed add/remove reasons are written to `bridge.log`.
- Unreachable or uncertain Cinegy reads never add or remove an on-air record.
- Persisted each record's source (`bridge` or `cinegy`) across restarts.
- Added the last successful Cinegy comparison time to the status screen and a
  comparison summary to the Layers panel.
- Added regression coverage for discovery, uncertain reads, comparison from
  the Layers panel, and detailed removal logging.

## 4.0.1 — 2026-08-22

- Fixed the release gate so the five on-air persistence smoke tests are
  discovered and executed by Pester.
- Prevented `onair.json` from being rewritten on every Cinegy sync when the
  tracked `ActiveId` has not changed, with a regression test for the behavior.
- Restricted the bridge to private Telegram chats; group, supergroup, and
  channel updates are ignored before authorization or command dispatch.
- Added regression coverage proving a successful EXIT removes and persists the
  on-air template record, while a failed Cinegy EXIT keeps it for recovery.
- Cleaned actionable PSScriptAnalyzer warnings and documented the intentional
  UTF-8-without-BOM and private helper naming exclusions.
- Added `DEVELOPMENT-PLAN.md` with the 4.0.1–5.0 roadmap and release gate.

## 4.0.0

- Fixed onair.json losing live templates: a layer that is genuinely on air is
  no longer dropped just because Cinegy reports a different ActiveId (Cinegy
  generates its own id and ignores the bot's EventId). The record is kept and
  Cinegy's real id is adopted.
- Restored the external-change alert (regression in 3.1.1 on-air fix): a layer
  removed because Cinegy reports it hidden/off-air now produces a `Changes`
  entry, so admins are notified again.
- Added on-air dirty tracking so an updated ActiveId is persisted on the next
  sync instead of only on removal.
- Raised `CinegyMonitorTimeoutSeconds` default from 1 to 3 seconds so Air Pro
  status reads stop timing out and dropping tracked layers.
- Restructured the simple and full status reports with sections, an overall
  status line, and a local timestamp.
- Added `Tests/Smoke-OnAir.Pester.ps1` — a no-server, no-disk smoke test for
  on-air persistence (runs as part of Run-Checks.ps1).

## 3.1.1

- Replaced free-text `LayerNames` editing with an administrator-only layer
  picker: select a layer, enter one label, or use a dedicated clear button.
- Layer labels are validated before saving to prevent malformed configuration.

## 3.0.0 — 2026-08-20

- Added mandatory review before every interactive, preset, or typed `SHOW`,
  required fields, layer preparation locks, draft navigation, previews, and
  two-step confirmation for hide-all.
- Added persistent per-user drafts, repeat-with-edit, recent field choices that
  exclude sensitive values, and a live quick-action layer panel.
- Added administrator preset creation, value editing, rename, and deletion with
  review, atomic writes, and timestamped template-registry backups.
- Added reliable one-time, daily, and weekly scheduling with clock/time-zone
  validation, upcoming-event cancellation, atomic persistence, and crash-safe
  occurrence keys that prevent automatic replay.
- Added `/health`, Telegram/Cinegy latency and health history, startup and
  recovery notifications, and a redacted administrator diagnostics report.
- Split status by role: every authorized user gets a lightweight Air summary,
  while administrators get a combined full layer and service-health report.
- Clarified the layer panel states and its quick-hide behavior in the Arabic help.
- Added an administrator-selected `HideAllLayers` scope, so the emergency
  hide-all action affects only the layers selected from Settings.
- Enriched external Cinegy-change alerts with the tracked template, old/new
  item details, Air endpoint, and available Cinegy client identity.
- Added Arabic unit/description labels to administrator numeric settings.
- Added administrator-configurable operational layer names throughout layer
  status, actions, emergency confirmation, and external-change alerts.
- Added a read-only administrator template catalogue and protected, disabled-
  by-default full template definition management with atomic backups.
- Added configuration backup comparison/restoration and migration coverage.
- Added a real Cinegy dashboard for every GFX layer referenced by the template
  registry, distinguishing bridge-owned, external, hidden, and unknown state.
- Added layer metadata from Cinegy `/status`: active item name, output state,
  license state, and connected client identity.
- Added one-minute Cinegy `/metrics` health aggregation for output, dropped
  frames, missing input, read errors, read time, and heartbeat.
- Added deduplicated admin alerts for external scene changes, unhealthy or
  unreachable telemetry, and health recovery.
- Bounded automatic monitoring requests with a dedicated short timeout.
- Expanded the release gate to validate required files, JSON, PowerShell
  syntax, PSScriptAnalyzer, and the complete Pester suite.
- Kept the existing regular-user/admin permission model and automatic migration
  of 2.x configuration settings.

## 2.8.4

- Improved role-aware Arabic help with short on-air workflows.
