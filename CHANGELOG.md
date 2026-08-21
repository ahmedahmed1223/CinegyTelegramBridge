# Changelog

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
