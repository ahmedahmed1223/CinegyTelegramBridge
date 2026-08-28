# Version 6 Multi-Scene Compatibility Design

## Purpose

Extend Version 6 so the bridge can evolve from its current one-active-scene
per-layer model to multiple independently identified scenes on a layer, without
changing the current deployment's behavior, configuration, or Telegram
callbacks.

## Current behavior and compatibility decision

The deployed bridge permits multiple *template definitions* to target one
Cinegy layer, but `$script:OnAir` is keyed by layer and therefore records one
active scene per layer. Version 6 keeps that behavior as the default
`Single` scene mode.

`Multi` scene mode is opt-in and is unavailable until the Cinegy integration
can return a stable identity for every active scene and can target a specific
scene for HIDE, EXIT, and UPDATE. The bridge must never infer multiple scenes
from template definitions alone or manufacture local identities that Cinegy
cannot act on.

## Scope

1. Introduce a canonical scene collection that may hold more than one record
   for a layer.
2. Migrate legacy layer-keyed `onair.json` data into the canonical collection
   safely and reversibly.
3. Preserve the existing single-scene UI and callbacks in `Single` mode.
4. Add capability-gated scene-specific UI and operations for `Multi` mode.
5. Prepare operation admission so actions exclusive to a layer cannot race,
   while scene-specific actions remain distinguishable.

## Non-goals

- Do not enable `Multi` against a Cinegy endpoint that returns only one
  layer-level active item.
- Do not change `config.json`, `templates.json`, typed Telegram commands, or
  existing `hide:<layer>` callbacks in `Single` mode.
- Do not add runspace concurrency over the mutable `$script:` state.
- Do not treat several templates configured with the same layer as evidence
  that several scenes are simultaneously on air.

## Capability model

The bridge exposes a scene mode selected from a validated capability record:

```text
Single  = Cinegy reports one active item per layer; current behavior.
Multi   = Cinegy reports stable SceneId values and accepts a SceneId target.
```

The configured/default value is `Single`. A request for `Multi` fails closed
with an Arabic diagnostic if either required Cinegy capability is absent. The
health center reports the selected scene mode and whether the capability probe
is verified.

## Canonical live-scene state

The versioned on-air document has an envelope and a `Scenes` array. Each scene
record contains:

```text
SceneId, Layer, Key, ActiveId, At, UserId, ChatId, Source,
TemplatePath, LastVerifiedAtUtc
```

`SceneId` is a Cinegy-provided stable identity in `Multi` mode. In `Single`
mode it is a bridge-generated legacy identity only for persistence and lookup;
it must never be sent to Cinegy as a target.

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

`Get-BridgePrimarySceneForLayer` retains the legacy one-scene presentation in
`Single` mode. Existing consumers are moved behind this adapter before the
layer-keyed runtime map is retired. A layer with multiple scenes must not be
silently reduced to one record in `Multi` mode.

## Telegram interaction contract

### Single mode

- Existing callbacks, including `hide:<layer>` and `exit:<layer>`, remain
  unchanged.
- Existing screens continue to show one tracked scene per layer.

### Multi mode

- A live-scene row identifies the template and its scene identity.
- Scene-specific controls use an opaque, bounded callback token resolved to a
  verified `SceneId`; raw unbounded identifiers are not placed in Telegram
  callbacks.
- HIDE/EXIT/UPDATE first resolve the token to one scene and reject expired,
  unknown, or cross-layer tokens.
- A separate administrator-confirmed `hide-layer:<layer>` action applies to
  every verified scene on the layer. It is never substituted for a requested
  scene-specific action.

## Operation admission and safety

Operations receive a target scope:

```text
LayerExclusive: SHOW, layer-wide HIDE, layer-wide EXIT, replace/clear.
SceneSpecific:  scene HIDE, scene EXIT, scene UPDATE.
```

`LayerExclusive` actions retain the existing layer lock and emergency priority.
`SceneSpecific` actions are admitted only in verified `Multi` mode. Until
Cinegy proves concurrent scene mutation safe, the dispatcher serializes them
through the same layer lock; identity separation prevents selecting or
reporting on the wrong scene without introducing unsafe concurrent requests.

## Tests and acceptance criteria

- Legacy `onair.json` migrates to exactly one canonical scene per prior layer.
- A failed migration leaves the primary state file unchanged.
- `Single` mode produces the same legacy callbacks and one-scene presentation.
- `Multi` mode rejects activation without both Cinegy capabilities.
- With a deterministic fake Cinegy multi-scene response, two scenes on one
  layer render separately and a scene-specific action targets only its own
  SceneId.
- Layer-wide emergency actions remain higher priority than ordinary scene
  actions.
- Full syntax, analyzer, Pester, release-package, and compatibility checks
  remain green.

## Delivery sequence

1. Pure scene-state and migration helpers, with no runtime behavior change.
2. Compatibility adapters and `Single`-mode regression coverage.
3. Capability contract plus health reporting.
4. Tokenized `Multi` UI and scene-specific operation routing behind the
   verified capability gate.
5. Operation admission integration and stress/compatibility verification.
