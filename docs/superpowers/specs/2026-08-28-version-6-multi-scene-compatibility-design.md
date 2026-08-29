# Version 6 Multi-Scene Compatibility Design

## Purpose

Extend Version 6 so an administrator can opt into a catalog containing several
named template items for the same layer, without changing the current
deployment's behavior, configuration, or Telegram callbacks.

## Current behavior and compatibility decision

The deployed bridge permits multiple *template definitions* to target one
Cinegy layer, but `$script:OnAir` is keyed by layer and therefore records one
active scene per layer. Version 6 keeps that behavior as the default
`Single` scene mode.

`Multi` scene mode is opt-in. It means that several template definitions may
share a layer and be selected by their template key/name or active item id.
Only one item is tracked as active on that layer at a time. The published
Cinegy controls remain layer-scoped (`Show`, `Hide`, and `Exit Loop`), so this
mode does not claim simultaneous independently targetable scenes.

## Scope

1. Introduce a canonical scene collection that can retain catalog identity and
   historical records while exposing one primary active record per layer.
2. Migrate legacy layer-keyed `onair.json` data into the canonical collection
   safely and reversibly.
3. Preserve the existing single-scene UI and callbacks in `Single` mode.
4. Add a capability-gated shared-layer catalog UI for `Multi` mode.
5. Prepare operation admission so actions exclusive to a layer cannot race,
   while scene-specific actions remain distinguishable.

## Non-goals

- Do not enable `Multi` unless Cinegy status exposes an active item identity
  and the bridge can issue the documented layer-level controls.
- Do not change `config.json`, `templates.json`, typed Telegram commands, or
  existing `hide:<layer>` callbacks in `Single` mode.
- Do not add runspace concurrency over the mutable `$script:` state.
- Do not treat several templates configured with the same layer as evidence
  that several scenes are simultaneously on air.

## Capability model

The bridge exposes a scene mode selected from a validated capability record:

```text
Single  = current compatible presentation and callbacks.
Multi   = several named catalog items may share a layer; one is active at once.
```

The configured/default value is `Single`. A request for `Multi` fails closed
with an Arabic diagnostic unless the active item can be identified and
layer-level control is available. The health center reports the selected scene
mode and whether the capability probe is verified.

## Canonical live-scene state

The versioned on-air document has an envelope and a `Scenes` array. Each scene
record contains:

```text
SceneId, Layer, Key, ActiveId, At, UserId, ChatId, Source,
TemplatePath, LastVerifiedAtUtc
```

`SceneId` is an internal stable record identity. `ActiveId` stores the Cinegy
active item identity when reported. Neither value is sent as a HIDE/EXIT target
because those operations are documented at layer scope.

Loading a legacy layer-keyed document creates one scene for each layer. The
bridge validates the transformed document, writes a timestamped backup, then
atomically writes the new envelope. A failed validation or write leaves the
primary document intact and returns a structured migration error.

## Compatibility adapters

All new code reads the canonical scene collection through helpers:

```text
Get-BridgeLiveScenes
Get-BridgeLiveScenesForLayer -Layer <int>
Get-BridgeLiveScene -SceneId <string>
Get-BridgePrimarySceneForLayer -Layer <int>
```

`Get-BridgePrimarySceneForLayer` retains the one-active-item presentation in
both modes. Existing consumers are moved behind this adapter before the
layer-keyed runtime map is retired. Catalog definitions remain independently
selectable by their existing template key/name.

## Telegram interaction contract

### Single mode

- Existing callbacks, including `hide:<layer>` and `exit:<layer>`, remain
  unchanged.
- Existing screens continue to show one tracked scene per layer.

### Multi mode

- Template lists may show and select several definitions assigned to one layer.
- Name/key identifies the template to prepare or show; `ActiveId` identifies
  the item reported active by Cinegy.
- HIDE and EXIT continue to use the existing layer callbacks because Cinegy's
  published controls are layer-scoped.
- Showing another item on an occupied layer follows the existing replacement
  and review safety gates.

## Operation admission and safety

All supported Cinegy mutations are `LayerExclusive`: SHOW, HIDE, EXIT,
replace, and clear. They retain the existing layer lock and emergency priority.
The operation correlation record distinguishes requests for observability; it
does not imply unsupported scene-specific control.

## Tests and acceptance criteria

- Legacy `onair.json` migrates to exactly one canonical scene per prior layer.
- A failed migration leaves the primary state file unchanged.
- `Single` mode produces the same legacy callbacks and one-scene presentation.
- `Multi` mode rejects activation without active-item identity and layer control.
- With deterministic fake Cinegy status, several definitions may share a layer
  while the active item is reported unambiguously.
- Layer-wide emergency actions remain higher priority than ordinary scene
  actions.
- Full syntax, analyzer, Pester, release-package, and compatibility checks
  remain green.

## Delivery sequence

1. Pure scene-state and migration helpers, with no runtime behavior change.
2. Compatibility adapters and `Single`-mode regression coverage.
3. Capability contract plus health reporting.
4. Shared-layer catalog UI behind the verified capability gate.
5. Operation admission integration and stress/compatibility verification.
