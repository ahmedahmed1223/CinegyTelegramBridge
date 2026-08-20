# Cinegy Telegram Bridge 3.0 — Operations Specification

## Goal

Release 3.0 improves operational visibility without changing the proven 2.x
control paths or permission storage.

## Permissions

The existing two effective roles remain unchanged:

- A regular authorized user can operate templates and use normal status tools.
- An administrator receives all normal access plus settings, approvals, relay,
  audit, raw-command, and explicit Cinegy refresh controls.

The bot is deployed in private chats, not Telegram groups. Existing
`AllowedChatIds`, `AdminChatIds`, `AllowedUserIds`, and `AdminUserIds`
configuration remains compatible and requires no migration.

## Layer dashboard

The normal status command queries every GFX layer referenced by
`templates.json` and labels each as on-air, hidden, or unknown. When available,
it includes Cinegy's active item name plus output, license, and client state.
An active external item is shown as external instead of being attributed to a
bridge template.

## Cinegy health

The bridge reads `GET /metrics` and summarizes the latest one-minute history:
sample count, output frames, dropped frames, missing-input frames, maximum read
error rate, average read time, and maximum heartbeat. Any dropped frames,
missing-input frames, or read errors make the sample unhealthy. An unreachable
endpoint is unknown, not healthy.

## Notifications

At a configurable interval the bridge reconciles its locally tracked on-air
layers. When Cinegy reports that a tracked scene was hidden or replaced outside
the bot, administrators receive one alert and the stale local record and timer
are removed.

At a separate configurable interval the bridge samples telemetry. It alerts on
the transition to unhealthy or unreachable and sends one recovery notice when
health returns. Repeated samples in the same state do not spam administrators.

## Safety

- Monitoring failures never issue Cinegy commands.
- A failed layer query preserves last-known local state.
- Monitoring is read-only and runs between Telegram updates.
- Existing settings are auto-filled through the current settings mechanism.
