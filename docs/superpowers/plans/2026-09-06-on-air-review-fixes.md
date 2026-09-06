# On-air review fixes implementation plan

**Goal:** Resolve the six confirmed pre-air review findings without operating the live bridge.

**Architecture:** Keep Cinegy state transitions on the polling thread. Move deferred Telegram HTTP into one bounded background request, retaining ownership of queued media until completion. Make manager configuration saves a stop/write/restart transaction when bridge-managed permissions change.

**Tech stack:** PowerShell 7, Pester, C#/.NET Windows Forms, built-in runspaces.

**Spec:** User-approved review in this task: scene identity before resume, nonblocking deferred sends, mutex release, private temporary config, race-free permission save, retained report uploads.

## Constraints

- No real Cinegy commands, bridge restart, configuration writes, or Telegram messages during development.
- Tests use temporary fixtures and mock external boundaries. No secret values in outputs.
- Version, What's New, Arabic changelog, English README and release pins move together to 7.67.0.

## Tasks and acceptance checks

- [x] Manager: reproduce failed-write lock/temporary-file leaks, implement guaranteed lock release and private temporary cleanup; test stop-before-write ordering and stop failure. Preserve chronological log display and clear save state.
- [x] Mojaz: reproduce a different ActiveId on the same template; assert neither postbox nor exit is sent, verify matching ID resumes, fix explicit clock behavior.
- [x] Telegram: demonstrate that a pending HTTP request does not block tick; one worker only, bounded queue, retry_after cooldown. Copy queued file uploads into owned temporary storage before caller cleanup; remove copies on success, rejection, eviction and shutdown.
- [x] Reports inspection: fallback explicitly uses plain text, so HTML escaping would display entities to users. Do not change that path. Defer additional report presentation changes beyond the six confirmed findings.
- [x] Release: update version/docs/pins; run complete Run-Checks and isolated manager build/selftest, independent review, commit and push the review branch.

## Coordination

Manager agent owns Manager/*.cs and its build script; Mojaz agent owns its part and test. Parent owns Telegram, reports, release and integration. No overlapping implementation files. Review is performed again after integration. The existing checkout is used on a dedicated codex branch; no production process is started.
