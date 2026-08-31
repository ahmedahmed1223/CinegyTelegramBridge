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
`Modules/CinegyAirTitler.psm1`, and `TelegramBridge.ps1` wires them to a Telegram
long-polling loop.

## Version 7.8.0

Corrects a wrong number in the news report. The ticker is one running strip
that gets edited, not a series of separate bulletins, so adding up how many
items each publish recorded counted the same headlines once per edit - a
strip of 14 edited three times was reported as 40. The report now shows what
the day ended with, the size of every edit as a trail, the days nothing was
touched at all, and how long the strip has been sitting unedited. The full
manual becomes one message with collapsible chapters, and the operation
history a structured list.

## Version 7.7.0

The news report joins the banner one as a real table - day, publishes,
items, operators - with the operator tally as its fourth column instead of a
second indented line the text version had nowhere else to put.

## Version 7.6.0

Scheduling gets a date field and a time field, built from inline buttons
because Telegram has no native picker: a month grid, then hours, then
minutes in fives. Past days and spent hours render disabled rather than
missing, so the grid keeps the shape the eye reads it by. Typing still works
and understands more of it - a bare 21:45, "tomorrow 21:45", "+30", a day
and month, and Arabic-Indic digits.

## Version 7.5.0

Upcoming events carry a tg-time entity rather than a rendering of the time,
so each reader sees the weekday, date and time in their own timezone and
language, with the station's zone kept alongside. Also fixes a latent flaw
from 7.0.0: an HTML message too long for one send was going out with its
tags visible - the markup is now taken back out instead.

## Version 7.4.1

Fixes a crash in the reference lookup on its most likely result: PowerShell
unwraps a one-item array on return, so a single matching log line came back
as a string and .Count on it threw under StrictMode. Also separates the
shape check from the search - an empty array returns as $null just as an
absent value does, so a rotated-away log was being reported as a malformed
reference.

## Version 7.4.0

The banner report is a real table now, sent with sendRichMessage: a header
row and five columns Telegram lays out itself, right-to-left. The text
version aligned its columns with spaces, which a proportional font on a
phone does not align at all. It is tried and never depended on - any refusal
falls through to exactly the text this screen has always sent, and the first
refusal of the method disables the attempt for the rest of the session.

## Version 7.3.0

The copy-reference button gets the half that was missing: an administrator
can paste a reference into the diagnostics screen and see the operation
line, instead of going to the playout machine to grep the log by hand. It is
a lookup, not a log search - the input must be exactly the eight hex
characters of a reference, and only structured AIR_OP records come back,
because the runtime log is the least redacted thing the bridge writes.

## Version 7.2.0

Everyday refusals answer on the button. A gate decides them above the
acknowledgement, because Telegram allows one answer per press - and the two
news-restore branches were refusing with a bare break, so the press did
nothing visible at all. The operation reference gets a copy button instead of
eight hex characters to retype off a phone.

## Version 7.1.1

Fixes a colouring rule that inverted itself: the direct hide button was red,
but the confirmation's "yes" was not - so turning ConfirmLayerRemoval on, the
safer setting, handed the operator the weaker screen. Resetting one setting
is now red like resetting them all.

## Version 7.1.0

A refused press now answers on the button instead of arriving as a new chat
message that scrolls the keyboard away. Telegram allows one answer per press
and the bridge was spending it on an empty acknowledgement before the guards
ran; the guards moved ahead of it, each answering on its way out. The reason
the acknowledgement came first is preserved - they are in-memory checks, and
an allowed press is still acknowledged before anything slow starts.

## Version 7.0.1

Button colour reaches the rest of the screens, under a policy written above
`New-Button`: red for a press that takes something off air, destroys typed
work, or overwrites live state; green for one that commits what the operator
just authored; nothing for navigation and for cancel. A menu entry that only
opens the screen where the act happens stays uncoloured, and only the
affirming half of a confirmation is coloured - colouring both halves leaves
the thumb with no signal.

## Version 7.0.0

The bot's screens now use the Bot API features that did not exist when they
were designed. Buttons carry a colour (`style`, Bot API 9.4) - red on delete
and discard, green on publish - so the destructive action is no longer told
apart from its neighbour by the label alone. The two placeholder arrows at the
ends of the reorder list are genuinely disabled (`disabled`, Bot API 10.3)
instead of live buttons pointing at a no-op handler. And the reorder listing is
sent as HTML inside an expandable block quotation (Bot API 7.6), so a long page
collapses to a few lines with Telegram's own "show more" and stops pushing its
own keyboard off the screen. `EnableButtonStyles` turns the colours off.

## Version 6.9.5

Stacked rows now carry the item number on every control (`⬆️ 3`, `🗑 3`) and
alternate a `▪️`/`▫️` marker, because Telegram gives a button no colour or
spacing to group it with the headline above. A fourth shape, `compact`, spends
one numbered button per item and puts the controls in the item screen - the
only way thirty items fit on a single screen.

## Version 6.9.4

The reorder screen's shape is now a three-way setting - `NewsListLayout`:
`text` (headline in the message body), `stacked` (headline on its own button)
and `inline` (headline in the row beside its controls, the pre-6.9.3
behaviour). It replaces the `NewsListStackedLayout` toggle, so anyone who had
that on picks the shape again once.

## Version 6.9.3

The reorder screen now lists the headlines in the message body instead of
inside a button. Telegram splits a row's width equally between its buttons, so
a headline sharing a row with three controls only ever had a quarter of the
screen; every item row is now a fixed four buttons - number, two arrows or an
inert placeholder, delete - so the rows stop rendering at different sizes.

## Version 6.9.2

Help now carries its own Google Sheets chapter: the shape the sheet has to be
in, both pull buttons, what happens to an empty sheet or a draft somebody else
holds, and the write-back in the other direction. The setup half - the CSV
export link, the sync mode, and where the write URL and its token live in
`config.json` - shows only to administrators.

## Version 6.9.1

`/help` and the 🆘 button opened the old one-screen manual instead of the
chapter index added in 6.8.0, and the full guide had drifted behind the
chapters - it was missing the news ticker entirely. It is now built from the
chapters themselves. Audit lines carry the operator's name beside the id
everywhere, with the id pinned left-to-right so Arabic lines stop mirroring
its brackets, and a 400 from `answerCallbackQuery` - a stale button - is no
longer logged as an error.

## Version 6.9.0

Publishing the ticker from Telegram now writes it back to the Google Sheet, so
the sync runs both ways and the sheet stays the readable record wherever the
editing happened. The write goes through a deployed Apps Script web app - see
`docs/news-sheet-writeback.gs` - because the Sheets API would need OAuth or a
service-account key and RS256 JWT signing. `NewsSheetWriteUrl` and
`NewsSheetWriteToken` live at the top level of `config.json` beside `BotToken`,
never in `Settings`, so a settings export cannot carry them. A failed write is
reported and never undoes a publish that already reached air.

## Version 6.8.0

Help is now a quick-start card plus a chapter index rather than one long
screen: eight operator chapters and one administrator chapter, each a single
message, with previous/index/next inside each and the full guide still one
button away. Sheet pulls now respect the news draft lock - an operator can no
longer erase a colleague's draft through them, and is pointed at the unlock
request instead, matching every other news screen.

## Version 6.7.0

Both sheet pulls now always confirm before acting, not only on a draft
conflict. The first press asks and the second acts, and the single prompt
carries every relevant fact: how many ticker items the publish pull would
replace, that the review pull reaches nothing on air, and who currently holds
the draft.

## Version 6.6.0

Both sheet pulls - publish and review - are available to every authorised
operator, not only administrators, and `AllowOperatorsSheetPull` (default true)
puts them back behind the administrator bar in one setting. The button is not
drawn and the callback is refused, because Telegram keeps buttons alive in old
messages. `NewsSheetNotifyScope` now defaults to `all`.

## Version 6.5.0

The sheet can be pulled into the draft for review instead of published
straight away: the news screen offers both a publish pull and a review pull.
The review pull replaces the draft contents through the ordinary import path,
so the same length, count, and duplicate rules apply. `NewsSheetNotifyScope`
(`none` / `admins` / `all`) replaces the admins-only boolean and decides who
hears about a sync.

## Version 6.4.0

The news ticker can be driven from a Google Sheets CSV export. Set
`NewsSheetCsvUrl` and the bridge fetches, parses, and publishes it through the
same validated atomic writer the Telegram screens use - which also ends the race
on `news.txt` between the bridge and any external converter script. Mode is
`manual` by default (an administrator button on the news screen) or `auto` on an
interval. An automatic sync yields to an operator holding the draft; an empty
sheet is refused rather than clearing the ticker.

## Version 6.3.0

Operations on the 🧾 screen now carry a short reference taken from the `AIR_OP`
correlation id, so an operator can quote it and an administrator can find the
exact log line. The health centre gains a runtime-file screen (healthy / not yet
written / corrupt-with-backup / corrupt) and a usage line covering today's
operations, active operators, graphics on air, and uptime. Neither screen runs a
new probe.

## Version 6.2.0

6.2.0 is a maintenance release. No screen, button, or command changed. The
test suite was split by subject and widened to cover the settings reset and
search paths that had no test, and the digest now reads audit timestamps
through the same shared helpers as every other reader.

## Version 6.1.0

Version 6 is the official release of the existing PowerShell and Telegram product without changing its configuration or template formats. Template-operation records are readable: wherever an administrator has configured an Alias, the logs retain both that Alias and the immutable user ID (for example, `محرر الأخبار (12345)`). Settings inside each Arabic category use a full row, every current key has an Arabic label, and the row shows its current state or formatted value within a safe 64-character display cap without changing category distribution or callbacks. It also includes Cinegy auto-hide identity correlation, an acknowledged personal reminder with one configurable follow-up, approximate user activity, emergency-first Telegram admission, the health center, unified settings schema, state migration, bounded administrator pages, and the documented side-by-side upgrade/rollback path.

`SceneMode` remains `Single` by default. Administrators may choose `Multi` for a catalogue where several named templates target the same Cinegy layer; one item is active on that layer at a time and the documented HIDE/EXIT controls remain layer-wide. The bridge enables that mode only when a non-empty active item identity and layer control are verified. A successful Multi SHOW preserves the layer's canonical catalogue while updating only the represented active item; Single SHOW keeps one record.

The settings experience from Preview 1 remains: the former long administrator keyboard is split into eight Arabic operational categories, each paged at eight settings. Existing `cfg:*` callbacks, typed commands, `config.json`, and `templates.json` remain compatible.

The 5.7.9 safety behavior remains included: self-service access requests stay enabled by default while approvals remain restricted to administrators and the owner; single-instance startup is tolerant by default with `-RequireSingleInstance` available for strict deployments; settings and template-registry JSON uploads allow up to 10 MiB; and `TemplateRegistryImportMaxTemplates` defaults to 1000.

The default backup example is Cinegy Playout instance 0's local feedback stream: `srt://127.0.0.1:5421`. Change or clear `BackupSourceUrl` for a different instance or to disable automatic failover.

The complete Version 6 delivery record, compatibility promise, validation evidence, merge gate, and follow-up backlog are documented in [`docs/VERSION-6.md`](docs/VERSION-6.md).

## Previous release history

Version 4.2.44 updates restored external on-air records in place when Cinegy later exposes the actual `.cintitle` filename, so main-menu hide buttons no longer retain a legacy generic layer-event label.
Status now presents each active scene with its layer, source, elapsed time, operator Alias or Cinegy event metadata; full status is grouped into operational sections. Administrators can edit or delete each user's Alias directly from user management.

External or scheduled Cinegy scenes now display the actual `.cintitle` template name when Cinegy includes it in the active-item description; the layer remains the reconciliation identity and the generic Cinegy event name is retained only as diagnostic metadata.
Long inline-button labels are shortened safely at `ButtonTextMaxLength` visible text elements (default `32`); set it to `0` in administrator settings to retain full labels.

Version 4.2.43 introduces an explicit runtime-state model and consolidates relay and service-monitoring state, completing the planned gradual state reduction without a broad rewrite. Version 4.2.42 extracts live-relay watchdog policy and completes the first modular separation of scheduling, relay control, and ffmpeg process handling. Version 4.2.41 extracts shared ffmpeg argument and process launch behavior into a tested module used by snapshots and live relay. Version 4.2.40 extracts schedule due and retry policy into a tested module while retaining persistence and playout orchestration in the bridge. Version 4.2.39 extracts Cinegy per-layer reconciliation policy into a tested module while preserving orchestration and live-state safety. Version 4.2.38 extracts interactive flow state and completes the first modular separation of Telegram transport, authorization, and pending workflows. Version 4.2.37 extracts private-chat and role authorization decisions into a tested explicit-input policy module. Version 4.2.36 extracts bounded Telegram send transport and retry behavior into a tested independent module. Version 4.2.35 extracts validated JSON storage into a tested module and organizes modules, administrator scripts, and archived planning documents into dedicated folders. Version 4.2.34 begins the planned modularization by moving setting lookup, normalization, and initialization into a tested independent module while retaining the existing bridge interfaces. Version 4.2.33 adds opt-in (`EnableSafeRollback`, disabled by default) short-lived in-memory safe rollback gated by exact live Cinegy state, without persisting editorial values. Version 4.2.32 adds confirmed template testing on a dedicated non-production layer, mandatory automatic hide, and before/after definition comparison. Version 4.2.31 adds administrator template-registry export and confirmed, validated import with comparison, backup, and live/scheduled-template protection. Version 4.2.30 adds template search, category browsing, a non-mutating detail preview, and persisted last-used times. Version 4.2.29 adds optional CurrentUser DPAPI protection from the administrator settings while retaining plaintext configuration as the default. Version 4.2.28 restricts Windows access to configuration and its backups to the runtime identity, SYSTEM, and Administrators. Version 4.2.27 extends the confirmed administrator runtime cleanup to every direct `.log` file in `logs`, including relay logs, while preserving audit and on-air state. Version 4.2.26 adds Windows CI, persisted Pester results, an allow-listed release ZIP, manifest and SHA-256 checksum, optional Authenticode signing, and documented upgrade/rollback steps. Version 4.2.25 adds bounded, configurable timeouts to Telegram message, photo, and document sends while retaining the existing single transient retry. Version 4.2.24 makes field limits and Telegram message splitting Unicode-aware, preserving emoji, Arabic combining marks, and other text elements. Version 4.2.23 adds schedule pausing, optional advance notifications, reviewed recurrence end dates. Version 4.2.22 adds reviewed copying and time editing for pending schedule events, with timezone ids shown in summaries and atomic rollback on save failure. Version 4.2.21 validates template path syntax, excludes invalid definitions from SHOW controls, and reports shared layers as allowed operational information in health status. Version 4.2.20 adds a private per-user operation page with actionable results and a safe retry button that always returns to SHOW review before Cinegy is changed. Version 4.2.19 keeps validated backups of on-air and schedule state and automatically repairs a corrupt primary JSON file from the last successful state. Version 4.2.18 enforces administrator-defined automatic-hide lifetimes for sensitive templates, including ordinary and scheduled SHOW paths. Version 4.2.17 adds an administrator-only redacted diagnostic ZIP containing a health summary and sanitized recent runtime lines, never configuration, on-air state, editorial values, secrets, or actor identifiers. Version 4.2.16 adds storage-growth warnings and confirmed administrator controls for clearing the runtime or audit history without touching `onair.json`. Version 4.2.15 adds an independent, permanent `logs/audit.jsonl` security and control trail, with UTC timestamps and correlation ids shared with air operations, and keeps helper return values such as `True` out of the runtime terminal. Version 4.2.14 expands administrator diagnostics with build and uptime data,
processor and memory, disk capacity, runtime-file sizes, and in-memory air
operation outcome counters. Version 4.2.13 adds bounded exponential backoff to opted-in scheduled retries,
configured by `ScheduleRetryBackoffFactor` and `ScheduleRetryMaxDelaySeconds`. Version 4.2.12 adds a content-free, machine-readable
`logs/schedule-execution.jsonl` record for every scheduled SHOW attempt. Version 4.2.11 adds an opt-in retry policy for failed scheduled SHOW events,
with safe zero-retry defaults and persisted attempt timing. Version 4.2.10 warns during schedule review when another pending event targets
the same layer within `ScheduleConflictWindowMinutes`. Version 4.2.9 adds administrator-managed `ReservedLayers` and
`DisabledTemplateKeys` safety policies. They block SHOW preparation and final
execution while leaving emergency HIDE and EXIT available. Version 4.2.8 writes one correlatable `AIR_OP` result to `bridge.log` for every
SHOW, HIDE, EXIT, and live UPDATE attempt, including its unique id, duration,
operator, target, result, and failure reason. Version 4.2.7 performs a direct read-only check of the target Cinegy layer
immediately before every SHOW and blocks the command when the layer cannot be
verified. Version 4.2.6 shows the currently tracked scene, its source or operator, and a
freshness warning in the SHOW review before replacing a layer. Version 4.2.5 classifies the current Cinegy state sample as connected, stale,
unavailable, or unknown in both status views, using the configurable
`CinegyStateStaleSeconds` threshold. Version 4.2.4 adds an administrator-controlled maintenance mode that blocks
SHOW, HIDE, EXIT, live-value updates, and new or due scheduled SHOW operations
without changing anything already on air. The administrator-only emergency
hide-all command remains available. Version 4.2.3 records approval provenance and last authorized activity in
`logs/user-profiles.json` without storing message content. Version 4.2.2 adds administrator user management with temporary disable,
confirmed revocation, roles, aliases, and final-admin protection. Version 4.2.1 adds thresholded Cinegy and Telegram outage/recovery alerts and
shows consecutive failures plus outage start time in full status. Version 4.2.0 adds editable per-user favourites and administrator-managed
operator aliases. Version 4.1.2 isolated every test runtime file from the live bridge state.
On-air summaries label external or scheduled scenes as `🟣 Cinegy Air` and
Telegram-operated scenes as `🔵 Bot · operator`. HIDE and EXIT immediately
read the affected layer before changing the local state.
It retains the 4.1.1 live comparison with Cinegy during startup as well as on
operator request. Opening Status or Layers reads
every graphics layer referenced by `templates.json`, reconciles it with
`onair.json`, and makes scenes started directly in Cinegy available for
operator HIDE/EXIT actions. `onair.json` remains current state only; historical
operations and reconciliation reasons stay in `bridge.log`. The bot
intentionally accepts private Telegram chats only.

- Every `SHOW` source—including template buttons, presets, and typed commands—
  passes through a review screen. Required fields, per-layer preparation locks,
  previous/edit/preview controls, and two-step hide-all confirmation reduce
  accidental on-air changes.
- Operator drafts survive a restart for the configured pending-state lifetime.
  Recent field values are stored per user and field as quick choices; fields
  marked `sensitive: true` and secret-like field names are never recorded.
- `📅 الجدولة` supports one-time, daily, and weekly events, verifies the local
  clock/time zone, stores events atomically, lists/cancels upcoming events, and
  records execution before contacting Cinegy to avoid replay after a crash.
  Pending events are restored before the polling loop after a bridge restart;
  when a timer becomes due, the registry is checked again so a removed or
  invalid template is not sent, followed by the live target-layer check in
  Cinegy immediately before SHOW. An occurrence already marked `running` at
  crash time is recorded as `interrupted` and is not replayed automatically.
- Administrators can create, edit, rename, and delete template presets from
  Telegram. Every change is reviewed first, written atomically, and preceded
  by a timestamped `templates.json` backup.

- `ℹ️ الحالة` is a lightweight report available to every authorized user. It
  shows the Air server/channel, template count, and the bridge-tracked on-air
  summary without administrator telemetry.
- `🎚 الطبقات` checks every GFX layer referenced by `templates.json` directly
  against Cinegy and labels it on-air, hidden, external, or unknown. Pressing
  an on-air layer provides the quick hide action; other layers refresh the panel.
- Cinegy `/metrics` is summarized for dropped frames, missing input, read
  errors, read time, output count, and telemetry heartbeat.
- Admins receive deduplicated alerts when a bridge-tracked scene is hidden or
  replaced externally, when Cinegy health becomes bad/unreachable, and once
  again when it recovers.
- `📊 الحالة الكاملة` is administrator-only and combines the real
  layer dashboard with Telegram/Cinegy latency, health history, telemetry, and
  operational details. `/health` remains an administrator-only compatibility alias.
- Admin settings changes create timestamped backups automatically. The
  `🗄 نسخ الإعدادات` screen validates, compares, and restores a selected copy
  only after explicit confirmation.
- `🧪 التشخيص` includes queues, locks, schedule state, Cinegy telemetry, and
  local paths while redacting tokens and stream secrets.
- Permissions remain the same two effective levels: regular authorized user
  and administrator. The bot's intended deployment is private chats; no group
  workflow or migration is required for 3.0.

## How it works

```
Telegram operator  →  Telegram Bot API (getUpdates long-poll)
                            ↓
                   TelegramBridge.ps1 (PowerShell 7, runs on/near Air Pro)
                            ↓
                   Modules/CinegyAirTitler.psm1
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
| `Modules/` | Reusable Cinegy, security, settings, and validated-storage PowerShell modules. |
| `TelegramBridge.ps1` | The bot itself — polling loop, button dispatch, authorization, async ffmpeg jobs, watchdog, logging. |
| `config.example.json` | Bot token, whitelists, Air server address/channel, `LiveStream` and `Settings` blocks. Copy to `config.json` and edit. |
| `templates.example.json` | Named title templates (friendly key → `.cintitle` path, GFX layer, field list, optional `order` and `presets`). Copy to `templates.json` and edit. |
| `scripts/Install-BridgeTask.ps1` / `scripts/Uninstall-BridgeTask.ps1` | Registers/removes a Windows Scheduled Task so the bridge auto-starts at boot and auto-restarts on crash — see "Make it run like a service" below. |
| `scripts/Install-BridgeService-NSSM.ps1` / `scripts/Uninstall-BridgeService-NSSM.ps1` | Alternative to the above: registers/removes a real Windows Service via [NSSM](https://nssm.cc/), with its own stdout/stderr logs. |
| `Run-Checks.ps1` | Required-file and JSON validation + syntax check + PSScriptAnalyzer + Pester in one command. Run it after every change; it touches nothing live. |
| `Tests\` | Pester suites, one file per subject (`Bridge.Templates`, `Bridge.OnAir`, `Bridge.Admin`, `Bridge.Cinegy`, `Bridge.NewsScreens`, `Bridge.SettingsScreens`, `Bridge.Users`, `Bridge.Schedule`, plus `Bridge.Tests.ps1` for the pure helpers). The shared bridge load lives in `Tests\Bridge.TestContext.ps1` and is dot-sourced by each of them. |
| `docs/archive/` | Archived technical reviews and historical implementation logs retained for traceability. |

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
  first run. See `docs/archive/TASKS.md` for the historical settings rationale.

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
  operator must not leave it empty or use the skip button. Use
  `sensitive: true` to prevent a field's values from entering recent-value
  history:
  ```json
  "maxLength": 120,
  "fields": [ { "name": "Ajel.center", "label": "نص الخبر العاجل", "maxLength": 80, "required": true, "sensitive": false } ]
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

> In a lab or on a dedicated non-production Cinegy layer, follow the checks with
> a quick Telegram smoke test: `/بدء` → a template with required fields → review
> → confirm → hide the layer → 🚨 إخفاء الكل → confirm. If the only available
> system is a live working environment, do **not** send test SHOW/HIDE/EXIT
> commands merely to satisfy a release checklist. Record the operational waiver,
> keep a rollback copy, and use the readiness and automated checks instead.

Leave it running — it long-polls Telegram in a loop. Good for a first test;
for anything beyond that, install it as a persistent background task (next
section) so it survives reboots and restarts itself if it ever crashes.

Only one bridge may run at a time: a second instance would compete for
`getUpdates` and make Telegram return 409 Conflict, so startup takes a
global mutex and any extra instance exits immediately with a line in the
log. If Windows cannot create or acquire that mutex, the default is tolerant:
the bridge logs a warning and continues. Add `-RequireSingleInstance` when a
deployment must refuse startup unless the lock is enforceable. **Stop the
service before running manually.** (`-AllowMultipleInstances` overrides this
if you ever genuinely need two, e.g. two different bots.)

### 4. Make it run like a service (auto-start, auto-restart)

`scripts/Install-BridgeTask.ps1` registers the bridge as a Windows **Scheduled
Task** — starts at boot, runs as `SYSTEM` (no one needs to be logged in),
restarts automatically if it crashes. No third-party tool required.

```powershell
cd 'D:\cingy cg\CinegyTelegramBridge'
# Right-click PowerShell -> "Run as Administrator" first, then:
.\scripts\Install-BridgeTask.ps1
```

It'll ask if you want to start it immediately. Useful commands afterward:

```powershell
Start-ScheduledTask -TaskName 'CinegyTelegramBridge'      # start now
Stop-ScheduledTask  -TaskName 'CinegyTelegramBridge'      # stop
Get-ScheduledTask   -TaskName 'CinegyTelegramBridge' | Get-ScheduledTaskInfo   # status / last run
Get-Content .\logs\bridge.log -Wait -Tail 20              # tail the log live
```

To remove it: `.\scripts\Uninstall-BridgeTask.ps1` (also as Administrator).

#### Alternative: a real Windows Service via NSSM

If you'd rather have an actual service entry in `services.msc` — with its
own stdout/stderr logs and more fine-grained restart control — use
[NSSM](https://nssm.cc/) (the Non-Sucking Service Manager) instead of the
Scheduled Task above. `scripts/Install-BridgeService-NSSM.ps1` automates this too:

```powershell
cd 'D:\cingy cg\CinegyTelegramBridge'
# Right-click PowerShell -> "Run as Administrator" first, then:
.\scripts\Install-BridgeService-NSSM.ps1
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
(auto-rotated by NSSM). To remove it: `.\scripts\Uninstall-BridgeService-NSSM.ps1`
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
📅 الجدولة
📸 صورة من البث        ❓ مساعدة
⚙️ الإعدادات           👤 طلبات الوصول    ← مشرفون فقط
⚡ إدارة النصوص الجاهزة                    ← مشرفون فقط
▶️ بدء البث            🔗 رابط البث       ← مشرفون فقط
📜 السجل              🛠 أمر خام         ← مشرفون فقط
```

**For every operator**

- **📋 القوالب** → lists every template from `templates.json` as a button.
  The bot collects editable fields one message at a time, then always shows a
  final review before Cinegy receives `SHOW`; templates without fields and
  preset buttons follow the same review gate. Previous/edit/preview/cancel
  controls preserve the draft while navigating.
- **⭐ المفضلة** → every operator edits an independent list from
  **إدارة المفضلة**. Selections live in `logs/favorites.json`; usage-ranked
  templates remain the fallback until the user makes a selection.
  `SharedFavoritesEnabled` is reserved for a future unified list and is off.
- Administrators set an operator Alias with `/alias USER_ID الاسم` and remove
  it with `/alias USER_ID -`. Aliases are stored in `logs/user-aliases.json`.
- **🙈 اخفاء طبقة** / **🚪 خروج من المشهد** → shows a button per known GFX
  layer (derived from the layers used in `templates.json`) — tap one to
  hide that layer / exit its scene, no need to type a layer number.
- **🚨 إخفاء الكل** → emergency button: shows the administrator-selected
  layers and requires a second confirmation before hiding only those layers
  and cancelling pending timers.
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
- **🔁 تكرار مع تعديل** → opens the last values as a new editable draft.
- **📅 الجدولة** → creates reviewed one-time/daily/weekly events and lists or
  cancels upcoming events. Persistent execution keys prevent replay after a
  restart at the critical moment. The event keeps its captured values, but the
  template key is resolved again at execution time so edits, removals, and
  safety policies are respected after a restart.
- **✏️ تحديث نص** → pick a template (used only as a reference for its field
  names), then pick the field, then send the new text — pushed live via
  `/postbox` without re-showing the template.
- **⏱ عرض مؤقّت** → same as القوالب, but you pick how long it stays up: after
  choosing the template a duration picker appears (⭐ marks the default), with
  **⌨️ مدة أخرى** for any other value in seconds. The bot confirms when the
  auto-hide fires, and warns you if it failed so you can hide it manually.
  The auto-hide deadline is stored in `logs/autohide.json`, so a bridge restart
  restores the remaining timer. Before hiding, the bridge confirms that the
  same tracked scene is still on the layer; if Cinegy or an operator replaced
  it, the old timer is discarded instead of hiding the replacement.
  Some Cinegy installations replace the client `SHOW` event id with an engine
  active id for the same scene. The bridge resolves that identity synchronously
  inside `SHOW` using an exact template-name match, before arming the timer.
  A missing or ambiguous identity leaves no destructive timer behind; every
  later id change is treated as a replacement for safety.
  - The quick-pick buttons come from `AutoHidePresetSeconds`
    (`5,10,15,30,60,120`) and the pre-selected one from
    `AutoHideDefaultSeconds` — both editable in ⚙️ الإعدادات.
  - A timer can also be attached to something **already on air**: every live
    layer in the 🔴 row (and the confirmation after a show) carries an
    **⏱ مؤقت** button. Setting a new timer on a layer replaces any existing
     one rather than stacking, so a layer can never be hidden twice.
- **🔔 تنبيه الظهور** → in **📚 القوالب والإعدادات**, the administrator or
  owner opens a template and selects a number of minutes from 0 to 1440.
  `0` disables it. When that template is shown—manually or by its scheduled
  event—the bridge stores the deadline in `logs/template-reminders.json` and
  later messages the same operator directly—even when the template was launched
  from a group—only if the exact scene remains on air.
  The message includes **✅ تمت المعالجة**. If that operator does not press it,
  one follow-up is sent after `TemplateReminderFollowUpMinutes` (default 5;
  `0` disables the follow-up). The pending acknowledgement survives restart.
  Replacing or hiding the scene silently cancels its reminder. Templates marked
  `longRunning: true` (such as a logo or ticker working 24/7) are deliberately
  excluded from this feature.
- **👥 نشاط المستخدمين** → administrator tools classify each authorized user
  as recently active, idle, or unknown from the last interaction cached by the
  bot. `UserActivityRecentMinutes` controls the recent window (default 5).
  This is deliberately labelled approximate: Telegram bots do not receive a
  real-time online/offline presence signal.
- **📸 صورة من البث** → grabs a single frame from `LiveStream.SourceUrl` via
  ffmpeg and sends it back as a photo. It runs **asynchronously**, so it
  never delays anyone else's command; repeat taps within
  `SnapshotCooldownSeconds` return the last frame instead of re-running
  ffmpeg. Each photo caption names the actual source used: **البث الأساسي**
  or **بث Cinegy الاحتياطي**; the retained cooldown frame keeps its own source
  label. Works independently of the RTMP relay below — no Video Chat or
  `RtmpDestination` needed. If ffmpeg fails, the reply includes ffmpeg's own
  error line, not just an exit code. Snapshot files are disposable and clean
  themselves up: the previous frame is deleted on each success, failed or
  timed-out captures delete their own output, and a sweep every few minutes
  (plus one at startup) removes anything older than
  `SnapshotRetentionMinutes` that a hard kill may have orphaned.
- **ℹ️ الحالة** → a lightweight report for every authorized user: Air
  host/channel, template count, and the bridge-tracked on-air summary.

**Admins only**

- **⚙️ الإعدادات** → eight Arabic sections: security, on-air operation,
  templates/layers, news, scheduling, monitoring, storage, and advanced.
  Each page contains at most eight settings. Booleans toggle in place with
  ✅/❌; numbers open a "send me the new value" prompt. Every change is saved
  to `config.json` immediately and recorded in the audit trail, and
  **♻️ استعادة الافتراضي** resets everything. Full option table in
  `docs/archive/TASKS.md`. **🚨 طبقات إخفاء الكل** opens a checkbox panel: select exactly
  the layers the emergency action may hide, or restore the default of all
  configured layers.
- Settings now show their real units and Arabic purpose, for example seconds,
  minutes, files, characters, and megabytes, while retaining the technical
  key for support.
- Full-row values are bounded to 64 visible characters so long paths and lists
  remain readable and safe inside Telegram inline buttons.
- **🏷️ أسماء الطبقات** lets an administrator choose a layer and enter one
  operational label at a time. The bot stores the format internally, so the
  administrator never has to type a compound value such as `7=عاجل`. The label
  and layer number are shown together in status, layer actions, emergency
  confirmation, and alerts.
- **📚 القوالب والإعدادات** → administrators can always read every parsed
  template definition. `EnableFullTemplateManagement` is off by default and
  protected; once deliberately enabled, it permits reviewed creation, editing,
  and deletion of template definitions. Every successful change is validated,
  atomically saved, and backed up. Template keys cannot be renamed, and an
  on-air or scheduled template cannot be deleted.
- **📊 الحالة الكاملة** → administrator-only layer dashboard, service health,
  telemetry, and operational details.
- **👤 طلبات الوصول** → anyone who messaged the bot but isn't authorized yet,
  each with Approve/Reject buttons. The label carries a live count, e.g.
  `👤 طلبات الوصول (2)`.
- **Automatic Cinegy alerts** → external replacement/hide events and telemetry
  health transitions are sent only to admins. The defaults are controlled by
  `CinegyStateCheckSeconds`, `CinegyHealthCheckSeconds`,
  `CinegyMonitorTimeoutSeconds`, `NotifyAdminsOnExternalChange`, and
  `NotifyAdminsOnCinegyHealth`. Repeated unhealthy samples are deduplicated;
  recovery produces one green notice.
  External-change alerts include the bridge template, layer, original show
  details, current Cinegy item, Air server/channel, and Cinegy client identity
  when the API supplies one. The API does not provide an external program or
  source IP, so the alert explicitly marks that source as unknown when absent.
- **▶️/⏹ البث** and **🔗 رابط البث** → live relay controls, see the next
  section.
- **📜 السجل** → the last 20 on-air actions with who did what and when,
  without opening `bridge.log`.
- **🛠 أمر خام** → still requires typing `/أمر Device Cmd [Op1]` since
  Device/Cmd values are arbitrary (see "Extending" below); everything else
  needs no typing at all.

Every bot reply carries the main menu keyboard again, so operators can keep
tapping through a full session without ever typing.

Show drafts are written atomically to `logs/drafts.json` and restored after a
restart, but still expire after `PendingStateTimeoutMinutes`. This prevents a
stray message sent much later from becoming an unintended on-air value.

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
| `/عملياتي` | `/myoperations` `/myops` |
| `/سجل` `/اعدادات` `/أمر` | `/audit` `/settings` `/cmd` |
| `/تشخيص` `/حزمةتشخيص` | `/diagnostics` `/diagbundle` |

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
      "BackupSourceType": "srt",
      "BackupSourceUrl": "srt://127.0.0.1:5421",
      "RtmpDestination": "",
     "VideoBitrateKbps": 2500,
     "CopyCodec": false
   }
   ```
   - `SourceType`: `m3u8` (HLS), `srt`, or `ndi`.
    - `SourceUrl`: the HLS URL, `srt://host:port?...` URL, or NDI source
      name, matching `SourceType`.
     - `BackupSourceType` / `BackupSourceUrl`: optional standby input. The first
       failed primary probe switches snapshots and the Telegram relay to it; the
       bridge returns to the primary after a successful primary capture. For Cinegy Playout instance
      `N` on the same machine, use `srt://127.0.0.1:<5421+N>`.
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
2. Either add a dedicated function to `Modules/CinegyAirTitler.psm1` (same pattern
   as `Show-TitlerTemplate`), or use the admin-only `/cmd <Device> <Cmd>
   [Op1]` command already wired up as a generic passthrough to
   `Send-AirCommand`.
3. Add a matching case to the `switch` in `TelegramBridge.ps1` once you're
   confident in the values, so operators get a friendly command instead of
   the raw `/cmd` escape hatch.

## Security notes

- This bridge is for one-to-one Telegram chats only. Updates from groups,
  supergroups, and channels are ignored before authorization or dispatch.
- **The bot token is the crown jewel.** Anyone holding it *is* the bot: they
  can read everything sent to it and impersonate it to your admins. Rotate
  the current one (see the warning in Setup), keep it out of source control
  (`.gitignore` covers `config.json`) and out of screenshots.
- DPAPI protection is optional and disabled by default. Enable
  `EnableDpapiSecrets` from the administrator Settings screen while the bridge
  is running under its final task/service account, or run
  `pwsh -File .\scripts\Protect-BridgeSecrets.ps1 -Confirm:$false` as that same account.
  The resulting `secrets.dpapi.json` can be decrypted only by that Windows
  identity on that machine; changing the service account requires disabling
  the option first or migrating again under the new account. Keep the protected
  `config.json.pre-dpapi.bak` offline until the migration is verified, then
  remove it through your normal secure-retention procedure.
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
- Runtime commands and failures are appended to `LogPath` (rotated at
  `LogMaxSizeMB`, keeping `LogKeepFiles` generations). Permanent structured
  control and security events are written separately to `logs/audit.jsonl`,
  with secrets redacted and air-operation correlation ids preserved. The last `AuditTrailSize` actions are also
  readable in-chat via 📜 السجل.
- Self-service access requests are rate-limited (`MaxPendingApprovals`),
  expire (`PendingApprovalExpiryHours`), and can be disabled
  (`EnableSelfServiceRequests`).
`Run-Checks.ps1` passes a temporary runtime directory to the bridge. Tests do
not read or write the live `logs/onair.json`, schedule, draft, usage, or log
files.
# إدارة شريط الأخبار

عند تفعيل `EnableNewsTickerManagement` يظهر زر Telegram دائم باسم `📰 إدارة شريط الأخبار`. يعمل التحرير في مسودة واحدة مقفلة ولا يكتب إلى `NewsFilePath` إلا بعد المراجعة وتأكيد النشر. يدعم الإدخال اليدوي واستيراد ملفات TXT بترميز UTF-8؛ والفاصل الافتراضي `|` قابل للتغيير من `NewsItemSeparator`. ينشئ النشر نسخة احتياطية ويرفض الكتابة إذا تغيّر الملف خارجيًا منذ فتح المسودة.
