# UI/UX audit corrections implementation plan

> Execution: native implementation with test-first regression checks and final review.

**Goal:** Correct the eight findings in DESIGN_REVIEW.md without touching live broadcast state.
**Architecture:** Keep the bridge's shared PowerShell scope and existing WinForms forms. Use short, expiring removal tickets; preserve permission ordering at serialization; separate failed state reads from empty success; keep report content accessible and current.
**Tech stack:** PowerShell 7 / Pester; .NET 9 WinForms / SelfTest.
**Spec:** DESIGN_REVIEW.md and AGENTS.md.

## Constraints

- No SHOW/HIDE/EXIT against a live engine. No manager termination or runtime configuration edits.
- New guards receive malformed/stale-input tests observed failing before the fix.
- Version, Arabic and English What's New, CHANGELOG, README, and two version assertions change together.
- Full Run-Checks plus manager publish/SelfTest, then commit and push only a green tree.

## Steps

- [ ] Add regression cases to existing OnAir tests for changed scene, changed content, expired/foreign/replayed confirmation, and legacy layer-only confirmation. Implement bounded in-memory tickets tied to actor and scene snapshot; reject stale tickets with a fresh-menu message.
- [ ] Add manager SelfTest cases for preserving `[900,100]` admin ordering when adding 500, unavailable on-air data, accessible report rows, refreshable error counts, and readable button palettes. Observe failures; implement policy helpers used by the actual forms.
- [ ] Preserve loaded role ordering; disallow knowingly transient managed-list saves; expose effective owner. Keep failed on-air reads visibly unknown while retaining last good rows.
- [ ] Make all report bars reachable through scrolling and expose their names/values. Read current error count on refresh. Make settings footer wrap at narrow widths. Avoid blocking UI during stop/save waits.
- [ ] Bump patch release; write operator-oriented release notes in both languages, README and CHANGELOG; update audit status.
- [ ] Run full bridge gate and publish manager to isolated artifacts with Build-BridgeManager.ps1. Review diff, stage only intended source/docs/tests, commit and push.

## Review focus

Tickets must expire/reject replay and fail closed when scene identity is absent. An unchanged template key with changed content is still a changed target. Missing or malformed state must not claim the air is clear. Permission order carries owner meaning. Report values and accessible descriptions must update together.
