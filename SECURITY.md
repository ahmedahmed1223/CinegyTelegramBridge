# Security policy

This bridge holds a Telegram bot token and drives a broadcast station's
on-air graphics. A defect here can put the wrong thing on air, or hand
control of the air to someone who should not have it.

## Reporting a vulnerability

Report privately through GitHub's **Security → Report a vulnerability**
(private advisory) on this repository. Please do not open a public issue for
anything that would let an unauthorised person send `SHOW`, `HIDE`,
`EXIT_SCENE_LOOP`, or read the bot token.

Include what you did, what happened, and which version (`🆕 ما الجديد` in the
bot, or `$script:BridgeVersion` in `TelegramBridge.ps1`). A log excerpt helps —
**redact the token first**; the bridge redacts it in its own logs, but not in
anything you paste by hand.

## What is in scope

- Authorisation: anything that lets a chat or user id outside
  `AllowedChatIds` / `AllowedUserIds` operate the bot, or a non-admin reach an
  admin screen.
- Secret handling: the token, the join code, or anything matching
  `token|secret|password|apikey` reaching a log, a chat message, an export, or
  the diagnostic ZIP.
- On-air safety: a path that changes the air without passing the layer
  protection and the audit trail in `Invoke-AirOperation`.
- State corruption: a write that can leave `onair.json`, the schedule, or a
  board unreadable and the bridge unable to restart.

## What is not

- The Cinegy Air Pro control port itself. It has **no authentication** by
  design — that is Cinegy's surface, and the bridge assumes the port is
  reachable only from a trusted network. Putting it on an untrusted network is
  a deployment decision, not a defect in this code.
- Anything that requires an operator who is already authorised to act against
  their own station.

## Supported versions

The newest release only. This is a single-product repository deployed at the
station that maintains it; there are no maintenance branches.
