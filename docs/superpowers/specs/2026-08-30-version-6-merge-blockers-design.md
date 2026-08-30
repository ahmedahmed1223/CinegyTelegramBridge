# Version 6 Merge Blockers — Design

## Goal

Remove the three Version 6 merge blockers without sending live Cinegy commands:
preserve causal Telegram ordering, retain every canonical live-scene record,
and connect the operation lifecycle to real Cinegy mutations.

## Telegram admission and ordering

Telegram `update_id` remains the causal order. Updates targeting the same
operational scope must never be reordered. A removal operation may move ahead
only across updates proven independent of it.

The ordering policy will assign each update an operational scope:

- A layer number for callbacks whose target layer can be parsed safely.
- `global` for hide-all and other mutations affecting multiple layers.
- `unknown` for messages and callbacks whose operational target cannot be
  established without executing application logic.

The scheduler will preserve original order whenever either update is global or
unknown, or both updates target the same layer. Emergency removal can move
ahead of lower-priority work only when both scopes are known and distinct.
This guarantees that `SHOW(7) -> HIDE(7)` and `HIDE(7) -> SHOW(7)` remain
unchanged while allowing a removal on layer 8 to precede work on layer 7.

## Canonical live-scene state

The canonical `Scenes` collection becomes the lossless persisted model. The
existing `$script:OnAir` layer map remains a compatibility projection used by
legacy call sites and represents the primary/current scene for each layer.

`Import-OnAirState` will load all canonical records into a new in-memory scene
state, then rebuild the compatibility projection. `Save-OnAirState` will write
the canonical state rather than recreating it from the lossy layer map.
Mutations through existing layer-level operations will update both models via
small synchronization helpers.

Mode contracts:

- `Single` retains at most one record per layer.
- `Multi` can retain multiple catalogue records for a layer, but exactly one
  record may represent the current Cinegy `ActiveId` at a time.
- HIDE and EXIT remain layer-level operations and remove all records for that
  layer because scene-targeted Cinegy control is not documented.
- Reconciliation updates the active/primary record without deleting unrelated
  canonical records solely because the compatibility projection cannot show
  them.

Legacy `onair.json` documents continue to migrate automatically. A canonical
file with multiple same-layer records must survive import followed by save
without record loss.

## Operation lifecycle integration

Every supported Cinegy mutation will create a bounded lifecycle record before
execution, transition it to `running` immediately before the Cinegy call, and
finish as `succeeded`, `warning`, or `failed` based on the real result.

Integration will reuse the existing air-operation correlation identifier where
possible so runtime logs, structured audit, user history, and lifecycle status
refer to one operation. Lifecycle storage remains an in-memory bounded list;
this change does not introduce parallel execution, background runspaces, or a
per-layer queue.

The integration point will be the shared mutation wrappers rather than every UI
callback. This covers command, callback, timer, schedule, rollback, and admin
entry paths consistently. Unsupported or authorization-blocked actions do not
claim to have reached `running`.

## Failure handling

- An unparseable callback scope falls back to stable Telegram order.
- A malformed canonical scene document is rejected without overwriting the
  primary state file.
- If persistence fails, the previous in-memory canonical state is restored
  where the existing operation expects transactional behavior.
- Lifecycle recording must never hide or replace the original Cinegy error.

## Tests and release gate

Tests are written and observed failing before production changes. Required
coverage includes:

1. Same-layer `SHOW -> HIDE` and `HIDE -> SHOW` preserve order.
2. Cross-layer emergency removal may move ahead safely.
3. Global and unknown updates act as ordering barriers.
4. Multiple same-layer canonical scenes survive import and save.
5. Single mode collapses a layer deliberately; Multi mode retains its catalogue
   with one current active record.
6. SHOW, HIDE, EXIT, update, timer, and hide-all paths produce valid lifecycle
   transitions and retain their correlation identifier.
7. Lifecycle-recording failure does not change the Cinegy operation result.

Completion requires the focused tests, the full Pester suite,
PSScriptAnalyzer, `git diff --check`, and release-package verification. The
ACL-protected `config.json` check must be run under an identity allowed to read
that production file; no ACL weakening is part of this change.

