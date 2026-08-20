# Cinegy Air Pro / Titler Telegram Bridge

A Telegram bot that lets whitelisted operators drive Cinegy Air Pro's Titler
graphics layer from chat: push a named title template on air with text
filled in, hide it, exit the scene, or push a live text update to whatever
is already on air.

It's built directly on the HTTP control surfaces that Cinegy demonstrates in
[`Cinegy/Cinegy.Powershell`](https://github.com/Cinegy/Cinegy.Powershell)
(`Titler/PushTitlerTemplateOnAir.ps1`, `HideTitlerTemplateOnAir.ps1`,
`ExitSceneTitlerTemplateOnAir.ps1`, `PushTitlerVariableToPostbox.ps1`) —
those scripts were refactored into reusable functions in
`CinegyAirTitler.psm1`, and `TelegramBridge.ps1` wires them to a Telegram
long-polling loop.

## Version 3.0

Version 3.0 adds read-only operational monitoring while retaining the existing
permission model and all 2.x configuration files:

- `ℹ️ الحالة` checks every GFX layer referenced by `templates.json` and labels
  it on-air, hidden, external, or unknown.
- Cinegy `/metrics` is summarized for dropped frames, missing input, read
  errors, read time, output count, and telemetry heartbeat.
- Admins receive deduplicated alerts when a bridge-tracked scene is hidden or
  replaced externally, when Cinegy health becomes bad/unreachable, and once
  again when it recovers.
- `💚 الصحة` or `/health` measures Telegram and Cinegy response time and shows
  the latest successful check and error for each service.
- Permissions remain the same two effective levels: regular authorized user
  and administrator. The bot's intended deployment is private chats; no group
  workflow or migration is required for 3.0.

## How it works

```
Telegram operator  →  Telegram Bot API (getUpdates long-poll)
                            ↓
                   TelegramBridge.ps1 (PowerShell 7, runs on/near Air Pro)
                            ↓
                   CinegyAirTitler.psm1
                            ↓
      HTTP POST  http://<air-host>:<5521+channel>/video/command   (SHOW/HIDE/EXIT)
      HTTP POST  http://<air-host>:<5521+channel>/postbox         (live SetValue)
                            ↓
                     Cinegy Air Pro engine → on-air graphics
```

No inbound port is opened on the playout machine — the bridge only makes
outbound calls to `api.telegram.org` (long polling) and to the local/LAN Air
Pro engine. Run it on the Air Pro box itself, or on any Windows/PowerShell 7
host that can reach the engine's control port.

## What's included

| File | Purpose |
|---|---|
| `CinegyAirTitler.psm1` | Reusable functions for SHOW/HIDE/EXIT, postbox updates, GFX layer status metadata, and Cinegy telemetry. |
| `TelegramBridge.ps1` | The bot itself — polling loop, button dispatch, authorization, async ffmpeg jobs, watchdog, logging. |
| `config.example.json` | Bot token, whitelists, Air server address/channel, `LiveStream` and `Settings` blocks. Copy to `config.json` and edit. |
| `templates.example.json` | Named title templates (friendly key → `.cintitle` path, GFX layer, field list, optional `order` and `presets`). Copy to `templates.json` and edit. |
| `Install-BridgeTask.ps1` / `Uninstall-BridgeTask.ps1` | Registers/removes a Windows Scheduled Task so the bridge auto-starts at boot and auto-restarts on crash — see "Make it run like a service" below. |
| `Install-BridgeService-NSSM.ps1` / `Uninstall-BridgeService-NSSM.ps1` | Alternative to the above: registers/removes a real Windows Service via [NSSM](https://nssm.cc/), with its own stdout/stderr logs. |
| `Run-Checks.ps1` | Syntax check + PSScriptAnalyzer + Pester in one command. Run it after every change; it touches nothing live. |
| `Tests\Bridge.Tests.ps1` | Unit tests for the pure logic — message chunking, argument quoting, secret redaction, template parsing. |
| `REVIEW.md` / `REVIEW-2.md` | Technical reviews: findings, impact, recommended fixes, and an honest critique of what is still weak. |
| `TASKS.md` | Implementation log — what was built for each review item, and the one item still needing your action (rotating the bot token). |

## Setup

### 1. Prerequisites

- PowerShell 7.x on the machine that will run the bridge (matches the
  version the Cinegy repo's scripts are written for).
- Network line-of-sight from that machine to the Air Pro engine's control
  port (`5521 + channel number`, e.g. `5521` for channel 0).
- A Telegram bot token: message **@BotFather** on Telegram, run `/newbot`,
  follow the prompts, copy the token it gives you.
- The chat ID(s) that should be allowed to operate the bot: message your new
  bot once from each Telegram account/group you want to authorize, then hit
  `https://api.telegram.org/bot<token>/getUpdates` in a browser and read
  `message.chat.id` from the JSON. (Simplest one-time check — no code
  needed.)

### 2. Configure

```powershell
Copy-Item config.example.json config.json
Copy-Item templates.example.json templates.json
```

Edit `config.json`:

```json
{
  "BotToken": "<token from BotFather>",
  "AllowedChatIds": [111111111, 222222222],
  "AdminChatIds": [111111111],
  "AirServerAddress": "127.0.0.1",
  "AirChannelNumber": 0,
  "TemplateRegistryPath": ".\\templates.json",
  "LogPath": ".\\logs\\bridge.log",
  "PollTimeoutSeconds": 30
}
```

- `AllowedChatIds` — anyone not on this list gets a polite refusal and the
  attempt is logged. Keep this list tight; anyone on it can put graphics on
  air.
- `AdminChatIds` — subset of the above allowed to use the Settings screen,
  the live relay controls, the audit log, and `/أمر` (the raw Device/Cmd
  escape hatch).
- `AllowedUserIds` / `AdminUserIds` — the same two lists expressed as
  Telegram **user** ids rather than chat ids. In a private chat the two are
  identical, so an existing config keeps working untouched. They matter in
  **groups**, where the chat id belongs to the group and the user id to the
  person: with `Settings.RequireUserLevelAuth` on (the default) only people
  on the user lists may operate the bot there, so adding a group to
  `AllowedChatIds` no longer implicitly authorizes every current and future
  member of it.
- `AirServerAddress` / `AirChannelNumber` — the Air Pro engine's host and
  channel/instance number.
- `Settings` — every runtime option, all editable live from the bot's
  ⚙️ Settings screen. Missing keys are auto-filled with their defaults on
  first run. See the table in `TASKS.md` for what each one does.

All of these are lists, so any number of Telegram accounts can control the
bot.

#### Adding operators without editing the file

You don't have to hand-edit `config.json` for every new operator. When
someone who isn't authorized messages the bot or taps a button, the bot
sends every admin a notification with their name, chat id and user id, plus
**✅ موافقة** / **❌ رفض** (Approve / Reject) buttons. Tapping **موافقة**
adds them to both `AllowedChatIds` and `AllowedUserIds` right away — no
restart, no manual editing — and the new operator gets a message saying
they're in. Admins can also check **👤 طلبات الوصول** in the main menu at
any time to see who's waiting.

The queue is capped at `MaxPendingApprovals` and requests expire after
`PendingApprovalExpiryHours`, so a bot whose link leaks can't be used to
flood the admins. Self-service requests can be switched off entirely with
`Settings.EnableSelfServiceRequests`.

Edit `templates.json` — one entry per title template you want operators to
be able to trigger by name, e.g.:

```json
{
  "lower3rd": {
    "description": "Standard lower-third: headline + supporting line",
    "path": "C:\\Cinegy\\Titler\\Scenes\\Lower3rd.cintitle",
    "layer": 5,
    "order": 10,
    "fields": ["TopText.Text", "BottomText.Text"],
    "presets": [
      { "name": "ترحيب", "values": ["أهلاً بكم", "نتابع معكم البث المباشر"] }
    ]
  }
}
```

- `path` and `layer` are **required**; a template missing either is skipped
  with a warning (shown in ℹ️ الحالة and logged) rather than crashing the bot.
- `fields` must list the template's variable names in the order operators
  will supply values in chat. Field names come from the `.cintitle` scene
  itself — open it in Cinegy Titler to check exact names, or use
  `Titler/AutoVariableReader.ps1` from the Cinegy repo as a reference for
  reading them programmatically.
- A `fields` entry may be a plain variable name, **or** an object carrying a
  human label, an optional character limit, and `required: true` when the
  operator must not leave it empty or use the skip button:
  ```json
  "maxLength": 120,
  "fields": [ { "name": "Ajel.center", "label": "نص الخبر العاجل", "maxLength": 80, "required": true } ]
  ```
  Both forms can be mixed freely; plain strings keep working unchanged.
- **Character limits** resolve in this order: the field's own `maxLength` →
  the template's `maxLength` → the global `Settings.MaxFieldLength` (200 by
  default, editable from ⚙️ الإعدادات). The applicable limit is shown in the
  prompt *before* the operator types, and text that exceeds it is rejected
  with the flow left open so they can simply retype. This matters because a
  headline strap and a scrolling ticker have very different usable lengths —
  one global number can only ever be a floor.
- `order` (optional) fixes the button position in the menu. Templates sort by
  `order`, then by name, so buttons never move around between renders.
- `presets` (optional) are saved sets of field values. Each becomes a
  ⚡ one-tap button under its template — handy for phrases you send often.

`templates.json` is re-read automatically whenever the file changes, so
adding a template or preset takes effect without restarting the bridge.

**Do not commit `config.json` to source control** — it holds your bot
token. `config.example.json` is the template to share instead, and the
included `.gitignore` already excludes `config.json` and `logs/`.

> ⚠️ **Rotate the bot token.** The token currently in `config.json` was
> shared in plain chat, so treat it as compromised: anyone holding it can
> impersonate the bot completely, read every message sent to it, and pose as
> the bot to your admins. Message **@BotFather** → `/revoke` → `/token`, put
> the new token in `config.json`, and restart the service. This is the one
> item from the review that can't be automated.

### 3. Check, then run

Before starting a new build — especially on the playout machine — run the
checks. They're static and offline: no Telegram, no Air Pro, no config writes.

```powershell
cd CinegyTelegramBridge
.\Run-Checks.ps1
```

Then start it:

```powershell
pwsh -File .\TelegramBridge.ps1 -ConfigPath .\config.json
```

> Passing checks are necessary, not sufficient. Always follow with a quick
> smoke test in Telegram — `/بدء` → a template with fields → ⏭ تخطي →
> 🚨 إخفاء الكل — before relying on a build during a live programme.

Leave it running — it long-polls Telegram in a loop. Good for a first test;
for anything beyond that, install it as a persistent background task (next
section) so it survives reboots and restarts itself if it ever crashes.

Only one bridge may run at a time: a second instance would compete for
`getUpdates` and make Telegram return 409 Conflict, so startup takes a
global mutex and any extra instance exits immediately with a line in the
log. **Stop the service before running manually.** (`-AllowMultipleInstances`
overrides this if you ever genuinely need two, e.g. two different bots.)

### 4. Make it run like a service (auto-start, auto-restart)

`Install-BridgeTask.ps1` registers the bridge as a Windows **Scheduled
Task** — starts at boot, runs as `SYSTEM` (no one needs to be logged in),
restarts automatically if it crashes. No third-party tool required.

```powershell
cd 'D:\cingy cg\CinegyTelegramBridge'
# Right-click PowerShell -> "Run as Administrator" first, then:
.\Install-BridgeTask.ps1
```

It'll ask if you want to start it immediately. Useful commands afterward:

```powershell
Start-ScheduledTask -TaskName 'CinegyTelegramBridge'      # start now
Stop-ScheduledTask  -TaskName 'CinegyTelegramBridge'      # stop
Get-ScheduledTask   -TaskName 'CinegyTelegramBridge' | Get-ScheduledTaskInfo   # status / last run
Get-Content .\logs\bridge.log -Wait -Tail 20              # tail the log live
```

To remove it: `.\Uninstall-BridgeTask.ps1` (also as Administrator).

#### Alternative: a real Windows Service via NSSM

If you'd rather have an actual service entry in `services.msc` — with its
own stdout/stderr logs and more fine-grained restart control — use
[NSSM](https://nssm.cc/) (the Non-Sucking Service Manager) instead of the
Scheduled Task above. `Install-BridgeService-NSSM.ps1` automates this too:

```powershell
cd 'D:\cingy cg\CinegyTelegramBridge'
# Right-click PowerShell -> "Run as Administrator" first, then:
.\Install-BridgeService-NSSM.ps1
```

NSSM itself is a small third-party `.exe`, not part of Windows, so the
script looks for it first (on `PATH`, next to itself, common install
folders) and, if it can't find it, prints exactly how to get it instead of
downloading anything on your behalf:

```powershell
winget install -e --id NSSM.NSSM
# or: choco install nssm -y
# or manually: download from https://nssm.cc/download, unzip, and copy
#   win64\nssm.exe into this folder (or anywhere on PATH), then re-run
```

Once installed, manage it like any Windows service:

```powershell
Start-Service 'CinegyTelegramBridge'
Stop-Service  'CinegyTelegramBridge'
Get-Service   'CinegyTelegramBridge'          # or open services.msc
```

It logs the bridge's own output to `logs\bridge.log` as usual, plus raw
process stdout/stderr to `logs\service-stdout.log` / `logs\service-stderr.log`
(auto-rotated by NSSM). To remove it: `.\Uninstall-BridgeService-NSSM.ps1`
(also as Administrator).

Only run **one** of the two options (Scheduled Task *or* NSSM service) at a
time — running both would start two competing instances of the bridge
polling the same bot token.

## Chat controls: buttons, not typed commands (Arabic, primary)

Operators drive the bot entirely with Telegram inline keyboard buttons — no
command syntax to remember. Send `/بدء` (or `/start`) once to open the main
menu:

```
📋 القوالب            ℹ️ الحالة
⭐ عاجل   ⭐ logo                      ← أكثر القوالب استخدامًا
🙈 اخفاء طبقة          🚪 خروج من المشهد
🚨 إخفاء الكل          🔁 إعادة الأخير
✏️ تحديث نص           ⏱ عرض مؤقّت
📸 صورة من البث        ❓ مساعدة
⚙️ الإعدادات           👤 طلبات الوصول    ← مشرفون فقط
▶️ بدء البث            🔗 رابط البث       ← مشرفون فقط
📜 السجل              🛠 أمر خام         ← مشرفون فقط
```

**For every operator**

- **📋 القوالب** → lists every template from `templates.json` as a button.
  Tap one: if it has no editable fields it goes on air immediately; if it
  has fields, the bot asks for each field's text one message at a time
  (with **⏭ تخطي** to leave a field blank and **❌ إلغاء** to abort), then
  pushes the template with the collected values. Templates that define
  `presets` also show ⚡ one-tap buttons for those saved phrasings.
- **⭐ favourites** → the most-used templates get their own row at the top,
  so the everyday ones are one tap away. Counts live in `logs/usage.json`;
  the row size is `FavoritesCount` and it can be switched off entirely.
- **🙈 اخفاء طبقة** / **🚪 خروج من المشهد** → shows a button per known GFX
  layer (derived from the layers used in `templates.json`) — tap one to
  hide that layer / exit its scene, no need to type a layer number.
- **🚨 إخفاء الكل** → emergency button: hides *every* known layer in one
  press and cancels any pending auto-hide timers. This is the one to reach
  for when something wrong is on air.
- **🔴 على الهواء** → a row appears at the top of the menu with one button per
  layer the bridge believes is currently live, labelled with the template
  name; tapping it hides that layer. The same information (with how long it
  has been up) appears in ℹ️ الحالة, and the confirmation you get after
  putting something on air carries its own **🙈 إخفاء هذا (طبقة N)** button —
  so taking a mistake off air is always one tap, never a menu hunt.
  The quick-action row reflects what this bot put on air. The full `ℹ️ الحالة`
  screen additionally queries Cinegy itself, so an active item started outside
  the bot appears as **خارجي**; a failed query appears as **غير معروف**, never
  as hidden.
- **🔁 إعادة الأخير** → repeats your last show with the same values.
- **✏️ تحديث نص** → pick a template (used only as a reference for its field
  names), then pick the field, then send the new text — pushed live via
  `/postbox` without re-showing the template.
- **⏱ عرض مؤقّت** → same as القوالب, but you pick how long it stays up: after
  choosing the template a duration picker appears (⭐ marks the default), with
  **⌨️ مدة أخرى** for any other value in seconds. The bot confirms when the
  auto-hide fires, and warns you if it failed so you can hide it manually.
  - The quick-pick buttons come from `AutoHidePresetSeconds`
    (`5,10,15,30,60,120`) and the pre-selected one from
    `AutoHideDefaultSeconds` — both editable in ⚙️ الإعدادات.
  - A timer can also be attached to something **already on air**: every live
    layer in the 🔴 row (and the confirmation after a show) carries an
    **⏱ مؤقت** button. Setting a new timer on a layer replaces any existing
    one rather than stacking, so a layer can never be hidden twice.
- **📸 صورة من البث** → grabs a single frame from `LiveStream.SourceUrl` via
  ffmpeg and sends it back as a photo. It runs **asynchronously**, so it
  never delays anyone else's command; repeat taps within
  `SnapshotCooldownSeconds` return the last frame instead of re-running
  ffmpeg. Works independently of the RTMP relay below — no Video Chat or
  `RtmpDestination` needed. If ffmpeg fails, the reply includes ffmpeg's own
  error line, not just an exit code. Snapshot files are disposable and clean
  themselves up: the previous frame is deleted on each success, failed or
  timed-out captures delete their own output, and a sweep every few minutes
  (plus one at startup) removes anything older than
  `SnapshotRetentionMinutes` that a hard kill may have orphaned.
- **ℹ️ الحالة** → Air host/channel, template count, relay state, outstanding
  snapshots and timers, authorized-user counts, pending requests, and template
  warnings. It also reads every configured GFX layer and reports Cinegy's
  output/license/client metadata plus the latest one-minute `/metrics` health
  summary.

**Admins only**

- **⚙️ الإعدادات** → the full settings screen. Booleans toggle in place with
  ✅/❌; numbers open a "send me the new value" prompt. Every change is saved
  to `config.json` immediately and recorded in the audit trail, and
  **♻️ استعادة الافتراضي** resets everything. Full option table in
  `TASKS.md`.
- **👤 طلبات الوصول** → anyone who messaged the bot but isn't authorized yet,
  each with Approve/Reject buttons. The label carries a live count, e.g.
  `👤 طلبات الوصول (2)`.
- **Automatic Cinegy alerts** → external replacement/hide events and telemetry
  health transitions are sent only to admins. The defaults are controlled by
  `CinegyStateCheckSeconds`, `CinegyHealthCheckSeconds`,
  `CinegyMonitorTimeoutSeconds`, `NotifyAdminsOnExternalChange`, and
  `NotifyAdminsOnCinegyHealth`. Repeated unhealthy samples are deduplicated;
  recovery produces one green notice.
- **▶️/⏹ البث** and **🔗 رابط البث** → live relay controls, see the next
  section.
- **📜 السجل** → the last 20 on-air actions with who did what and when,
  without opening `bridge.log`.
- **🛠 أمر خام** → still requires typing `/أمر Device Cmd [Op1]` since
  Device/Cmd values are arbitrary (see "Extending" below); everything else
  needs no typing at all.

Every bot reply carries the main menu keyboard again, so operators can keep
tapping through a full session without ever typing.

If you start filling in a template's fields and then wander off, the flow
expires after `PendingStateTimeoutMinutes` and the bot tells you so. This
matters: without it, a stray message sent hours later would be swallowed as
the next field value and could put unintended text on air.

### If you get lost: three ways back

The inline keyboard is attached to a specific message, so it scrolls away —
and a brand-new chat, a cleared history, or a half-finished field prompt can
all leave an operator with nothing obvious to tap. There are three
independent escape hatches:

1. **🏠 القائمة / 🆘 مساعدة** — a keyboard bar pinned permanently below the
   input box. Tapping 🏠 cancels whatever was in progress and reopens the
   main menu; it is checked *before* pending field input, so it works even
   mid-flow. Disable with `EnablePersistentMenuButton` if you'd rather not
   have the bar.
2. **The ☰ Menu button** next to the message box, populated automatically at
   startup, listing every command with an Arabic description.
3. **`/بدء`, `/قائمة`, or `/الغاء`** typed manually. `/الغاء` specifically
   cancels any pending operation.

> Telegram only accepts lowercase Latin letters, digits and `_` for the
> commands shown in the ☰ menu, so the entries registered there are the
> English aliases (`/start`, `/menu`, `/cancel`, …) — each with an Arabic
> description, which is what operators actually read. The Arabic commands
> keep working when typed.

Typed slash commands still work, kept for compatibility and scripting, but
buttons are the primary way to operate the bot:

| عربي | English alias |
|---|---|
| `/بدء` `/قائمة` `/الغاء` | `/start` `/menu` `/cancel` |
| `/مساعدة` `/قوالب` `/عرض` | `/help` `/templates` `/show` |
| `/اخفاء` `/اخفاءالكل` `/خروج` | `/hide` `/hideall` `/exit` |
| `/تحديث` `/حالة` `/صورة` | `/set` `/status` `/snapshot` |
| `/سجل` `/اعدادات` `/أمر` | `/audit` `/settings` `/cmd` |

## Watching the live air output in Telegram

The Telegram **Bot API has no method to push continuous video** to a chat —
a bot can send a photo or a video *file*, but not a live feed. The actual
mechanism for real continuous live video inside Telegram is a **Group or
Channel Video Chat with RTMP ingestion**: you start a Video Chat, Telegram
gives you an `rtmp://` server URL + stream key, and anything you push to
that URL with standard streaming tools (ffmpeg, OBS, etc.) plays live for
everyone in the chat — natively, no separate app needed to watch.

This bridge automates the *pushing* side: it runs `ffmpeg` in the
background to relay your existing air output (m3u8/HLS, SRT, or NDI) into
that Telegram RTMP endpoint, controlled by two admin-only buttons in the
main menu.

### One-time setup

1. **Install ffmpeg** on the machine running the bridge, if it isn't
   already: `winget install ffmpeg` (or download from
   [ffmpeg.org](https://ffmpeg.org/download.html) and add it to `PATH`).
   NDI as a source needs an NDI-enabled ffmpeg build (the NDI SDK ships
   one) — if you have m3u8 or SRT available instead, prefer those, since
   stock ffmpeg handles them natively with no extra build.
2. **Set the source** in `config.json`'s `LiveStream` block:
   ```json
   "LiveStream": {
     "SourceType": "m3u8",
     "SourceUrl": "https://your-source/stream.m3u8",
     "RtmpDestination": "",
     "VideoBitrateKbps": 2500,
     "CopyCodec": false
   }
   ```
   - `SourceType`: `m3u8` (HLS), `srt`, or `ndi`.
   - `SourceUrl`: the HLS URL, `srt://host:port?...` URL, or NDI source
     name, matching `SourceType`.
   - `VideoBitrateKbps`: target bitrate when re-encoding (default 2500).
   - `CopyCodec`: set to `true` to pass the stream through with `-c copy`
     (no re-encoding — much lighter on CPU) *if* your source is already
     H.264/AAC-compatible with FLV/RTMP; leave `false` to always
     transcode, which is safer if you're not sure.
3. **Create (or reuse) a private Telegram group or channel** for whoever
   should watch — this is just a normal Telegram group, unrelated to the
   bot's `AllowedChatIds`.
4. **Start a Video Chat** in that group (📹 icon / group menu), then open
   its streaming settings ("Start with another app" / "إعدادات خدمة البث")
   to get the RTMP **server URL** and **stream key**. Combine them into one
   full URL, e.g. `rtmp://dc4-1.rtmp.t.me/s/<your-key>`.
5. In the bot, open the main menu (admin account) and tap **🔗 رابط البث**,
   then paste that full RTMP URL. It's saved straight into `config.json`.

### Day to day

- **▶️ بدء البث** — starts the ffmpeg relay in the background and returns
  immediately; a moment later the bot confirms "البث يعمل الآن", or reports
  the exit code if ffmpeg died on startup (logs in `logs\relay-stdout.log` /
  `logs\relay-stderr.log`).
- **⏹ إيقاف البث** — stops it.
- **ℹ️ الحالة** shows whether the relay is running, restarting, or stopped.
- Whoever's in the Telegram group just opens its Video Chat to watch live —
  no bot interaction needed on their end.

**The relay is watchdogged.** Every `RelayWatchdogSeconds` the bridge checks
that ffmpeg is still alive. If it died on its own — a dropped source, a
network blip — it is restarted automatically (up to `RelayMaxRestarts`) and
the admins are notified; previously the stream would just go quiet with
nobody noticing. The watchdog distinguishes a crash from a deliberate stop,
so pressing ⏹ keeps it stopped. Both behaviours are configurable
(`RelayAutoRestart`, `NotifyAdminsOnRelayFailure`).

Two things worth knowing: Telegram issues a **new stream key each time a
Video Chat session (re)starts**, so you'll need to repeat step 4-5 above
whenever you start a fresh Video Chat. And if the bridge process itself is
killed forcefully (not stopped via the button) while relaying, ffmpeg can
be left running as an orphan process — the bot tracks it via
`logs\relay.pid` and will pick it back up (and let you stop it normally)
the next time it starts, but if in doubt, check Task Manager for a
lingering `ffmpeg.exe`.

### Keeping the playout machine's CPU free

Both the relay and the snapshot run ffmpeg on whichever machine hosts the
bridge — usually the Air Pro box itself, which is the last place you want
avoidable load. Two mitigations, in order of effectiveness:

1. Set `"CopyCodec": true` if your source is already H.264/AAC. This drops
   `libx264` re-encoding entirely and passes the stream through, which is
   dramatically cheaper.
2. Run the bridge on a **second machine** that can reach both the Air Pro
   control port and the m3u8/SRT source. Nothing in the design requires it
   to be on the playout box.

## Extending to playlist / clip transport control

This bridge, and the Cinegy example repo it's based on, only demonstrate
**Titler graphics control** (`SHOW` / `HIDE` / `EXIT_SCENE_LOOP` on `*GFX_n`
devices) and the **postbox** live-variable channel. The same
`/video/command` endpoint is understood to also carry playlist transport
commands (play, pause, cue, skip) in Cinegy's Air Remote Control API, but no
example of those Device/Cmd values ships in the public repo, so none are
hard-coded here.

If you need playlist transport from Telegram too:

1. Confirm the exact `Device`/`Cmd`/`Op1` values with Cinegy support or
   their Air Remote Control API documentation.
2. Either add a dedicated function to `CinegyAirTitler.psm1` (same pattern
   as `Show-TitlerTemplate`), or use the admin-only `/cmd <Device> <Cmd>
   [Op1]` command already wired up as a generic passthrough to
   `Send-AirCommand`.
3. Add a matching case to the `switch` in `TelegramBridge.ps1` once you're
   confident in the values, so operators get a friendly command instead of
   the raw `/cmd` escape hatch.

## Security notes

- **The bot token is the crown jewel.** Anyone holding it *is* the bot: they
  can read everything sent to it and impersonate it to your admins. Rotate
  the current one (see the warning in Setup), keep it out of source control
  (`.gitignore` covers `config.json`) and out of screenshots.
- The whitelists are the only access control — anyone on them can put
  graphics on air. Keep the operator group small.
- Authorization is evaluated against the **user id**, not just the chat id,
  when `RequireUserLevelAuth` is on (default). Turning it off restores the
  old chat-level-only behaviour, which means whitelisting a group authorizes
  every member of that group — only do that deliberately.
- Admin-gated separately: the Settings screen, live relay controls, the
  audit log, and `/أمر` (which can send any Device/Cmd pair the engine
  accepts). `/أمر` can also be disabled outright via `EnableRawCommand`.
- Text values from chat are XML-escaped before being sent (see
  `Escape-XmlValue` in the module) to avoid malformed XML or injected markup
  breaking the request, but there's no content moderation — anyone
  authorized can put arbitrary text on air. That's a chat-membership problem
  to manage on the Telegram side, not something the script can fix.
- All commands and failures are appended to `LogPath` (rotated at
  `LogMaxSizeMB`, keeping `LogKeepFiles` generations) for an audit trail of
  who put what on air and when. The last `AuditTrailSize` actions are also
  readable in-chat via 📜 السجل.
- Self-service access requests are rate-limited (`MaxPendingApprovals`),
  expire (`PendingApprovalExpiryHours`), and can be disabled
  (`EnableSelfServiceRequests`).
