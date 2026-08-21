# Changelog

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
