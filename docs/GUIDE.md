# Operator and administrator guide

Everything the bridge does, in the order you meet it: install it, point it at
Cinegy, let people in, put a graphic on air, and run the boards that do it for
you. The bot has its own manual under **❓ مساعدة** — that one is written for
somebody holding a phone mid-shift. This one is for whoever sets the thing up
and has to understand why it behaves as it does.

The bot's screens are Arabic by default and can be switched to English
(**⚙️ الإعدادات → 🌐 English**); see [Language](#language). This document is
English throughout.

---

## Contents

1. [What this is, and what it is not](#what-this-is-and-what-it-is-not)
2. [How a press becomes a graphic](#how-a-press-becomes-a-graphic)
3. [Install](#install)
4. [Configure](#configure)
5. [Templates](#templates)
6. [Who may do what](#who-may-do-what)
7. [Language](#language)
8. [The main menu](#the-main-menu)
9. [Putting a graphic on air](#putting-a-graphic-on-air)
10. [Taking it off](#taking-it-off)
11. [The four content systems](#the-four-content-systems)
12. [Scheduling](#scheduling)
13. [Watching the output](#watching-the-output)
14. [Settings](#settings)
15. [What gets written where](#what-gets-written-where)
16. [Running it as a service](#running-it-as-a-service)
17. [The desktop manager](#the-desktop-manager)
18. [When something goes wrong](#when-something-goes-wrong)
19. [Upgrading](#upgrading)
20. [Developing on it](#developing-on-it)

---

## What this is, and what it is not

A Telegram bot that drives the Titler graphics layer of **Cinegy Air Pro** from
chat. An authorised operator presses a button; a named title template goes on
air with their text in it. They can update the text while it is live, hide it,
or exit its scene.

**It is not** a playout automation system, a scheduler for clips, or a
replacement for Air Pro's own controls. It writes to the Titler layers and to
the postbox, and reads state back. Everything else on the channel is somebody
else's job.

**It assumes a trusted network.** Cinegy's control port has no authentication —
anything that can reach `5521 + channel` can drive the graphics. The bridge does
not add authentication to that port and cannot; it adds authentication in front
of *itself*, so that reaching the bot is not the same as reaching the port.

---

## How a press becomes a graphic

```
Telegram operator  →  Telegram Bot API (getUpdates long-poll)
                            ↓
                   TelegramBridge.ps1 (PowerShell 7, on or near the Air Pro box)
                            ↓
                   Modules/CinegyAirTitler.psm1
                            ↓
      HTTP POST  http://<air-host>:<5521+channel>/video/command   (SHOW / HIDE / EXIT)
      HTTP POST  http://<air-host>:<5521+channel>/postbox         (live SetValue)
                            ↓
                     Cinegy Air Pro engine → on-air graphics
```

**No inbound port is opened on the playout machine.** The bridge only makes
outbound calls: to `api.telegram.org` to long-poll for updates, and to the Air
Pro engine on the LAN. Run it on the Air Pro box itself, or on any
Windows/PowerShell 7 host that can reach the engine.

Every air-changing command passes through one funnel, `Invoke-AirOperation`,
which is what gives each of them the same audit record, the same maintenance
check, the same per-layer permission, and the same correlation id in the log.
That is deliberate: a second path to air would be a second set of bugs.

---

## Install

### Prerequisites

- **PowerShell 7.x** on the machine that will run the bridge.
- Network line of sight to the Air Pro engine's control port
  (`5521 + channel number` — `5521` for channel 0).
- A **bot token**: message **@BotFather** on Telegram, run `/newbot`, follow the
  prompts, copy the token.
- The **chat id(s)** that may operate the bot: message your new bot once from
  each account, then open
  `https://api.telegram.org/bot<token>/getUpdates` in a browser and read
  `message.chat.id`.

### First run

```powershell
Copy-Item config.example.json config.json
Copy-Item templates.example.json templates.json
# edit both, then:
.\Run-Checks.ps1
.\TelegramBridge.ps1
```

`Run-Checks.ps1` validates the required files, parses every script, runs
PSScriptAnalyzer and the full Pester suite. **It contacts neither Telegram nor
Cinegy and does not touch `config.json`**, so it is safe to run on the playout
machine while the bridge is live. Run it after every change.

---

## Configure

`config.json` is the only file you must edit. It is **not** in version control —
`config.example.json` is the shipped template.

```json
{
  "BotToken": "<token from BotFather>",
  "AllowedChatIds": [111111111, 222222222],
  "AdminChatIds": [111111111],
  "OwnerUserIds": [111111111],
  "AirServerAddress": "127.0.0.1",
  "AirChannelNumber": 0,
  "TemplateRegistryPath": ".\\templates.json",
  "LogPath": ".\\logs\\bridge.log",
  "PollTimeoutSeconds": 30,
  "Settings": { }
}
```

| Key | What it decides |
|---|---|
| `BotToken` | The bot. Treat it as a password — anyone holding it is the bot. |
| `AllowedChatIds` | Who may operate at all. Anyone else gets a polite refusal, logged. |
| `AdminChatIds` | Subset allowed into Settings, the relay controls, the audit log, and `/أمر`. |
| `AllowedUserIds` / `AdminUserIds` | The same two lists as Telegram **user** ids. In a private chat these are identical to the chat ids; in a **group** they are not, and the user id is the one that identifies a person. |
| `OwnerUserIds` | The owner role. Inherits every administrator permission. Some templates and layers can be reserved to the owner alone. |
| `AirServerAddress`, `AirChannelNumber` | Where the engine is. The port is derived: `5521 + channel`. |
| `Settings` | Everything else, and everything in it is editable from the bot. See [Settings](#settings). |

**Do not hand-edit `config.json` while the bridge is running.** The bridge owns
that file: it writes a timestamped backup and replaces it atomically on every
change made from a screen. An edit underneath it is lost on the next save, and
in the worst case interleaves with one.

The token can be protected with CurrentUser DPAPI
(`scripts\Protect-BridgeSecrets.ps1`). Plaintext remains the default because
DPAPI ties the file to one Windows account on one machine, which is the wrong
trade for a station that images its playout boxes.

---

## Templates

`templates.json` maps a friendly key to a `.cintitle` file, the GFX layer it
goes out on, and its fields.

```json
{
  "Templates": {
    "Lower": {
      "Path": "C:\\Titler\\lower-third.cintitle",
      "Layer": 4,
      "Fields": ["Name.Text", "Role.Text"],
      "Order": 1,
      "Presets": { "Anchor": { "Role.Text": "مذيع" } }
    }
  }
}
```

- **`Layer`** is the identity the bridge reconciles against Cinegy. Two
  templates on one layer is the `Multi` scene mode; one at a time is live on
  that layer and HIDE/EXIT remain layer-wide.
- **`Fields`** are the scene's variable names, exactly as Titler declares them.
  The bridge does not invent field names anywhere — several features read the
  scene's own declaration instead, and say so on screen when a scene declares
  none.
- **`Presets`** are named sets of values for one-press recall.

The registry is editable from the bot (**🗂 أدوات الإدارة → القوالب**), with
export, validated import, comparison against the current file, a backup, and
refusal to overwrite a template that is live or scheduled.

---

## Who may do what

Three effective roles, in a strict hierarchy:

```
owner  >  administrator  >  operator
```

An explicit owner inherits every administrator permission without needing a
duplicate id in `AdminUserIds`. An administrator never inherits owner powers.

| | operator | administrator | owner |
|---|---|---|---|
| Show, hide, exit, update text | ✅ | ✅ | ✅ |
| The content boards (news, mojaz, urgent, programme) | ✅ | ✅ | ✅ |
| Settings, user management, audit log, raw `/أمر` | — | ✅ | ✅ |
| Templates or layers marked administrator-only | — | ✅ | ✅ |
| Templates or layers marked owner-only | — | — | ✅ |
| 🚨 **Hide all**, including protected layers | partial¹ | ✅ | ✅ |

¹ An operator's hide-all clears what they are allowed to touch and **names the
layers it refused, with the reason** — kept separate from failures, because a
refusal and a Cinegy timeout are different news and only one is worth retrying.
An administrator's hide-all clears everything, logo and ticker included: that is
what the button is for, and an emergency a rule can veto is not an emergency
control.

**Self-service access.** A stranger who messages the bot can request access; an
administrator approves or refuses from **🚪 من يدخل البوت**. Requests are rate
limited, expire, and can be turned off entirely.

---

## Language

One choice for the whole bridge, not one per operator: a gallery reads one
language, and a per-user setting would mean the same layer described two ways in
the same audit trail.

- **⚙️ الإعدادات → 🌐 English** (or **🌐 العربية**) toggles it. The button names
  the language it switches *to*, and the confirmation arrives in the new
  language — the only way somebody who pressed it by accident can tell it worked.
- The same choice is the `Language` setting (`ar` / `en`), filed under
  **🛠️ خيارات متقدمة** beside `OneHandMode`, which is where a search for
  "language" finds it.
- It applies immediately to everyone. No restart.

**Translation status.** The catalogue lives in
`Modules/BridgeLanguage.psm1`; a test asserts that every key in it carries both
languages, is non-empty, and keeps the same `{0}`-placeholders in each. Screens
that have not been moved into the catalogue yet still render Arabic in both
modes. `Get-BridgeTextMisses` reports keys asked for at runtime and not found.

---

## The main menu

The menu is built from what is actually true right now, so it differs between
two operators and between two minutes:

- **Live rows first.** Every layer currently on air gets its own hide button,
  and a timer button if timed show is on. Nothing about "what is on air" is
  inferred from memory — it is reconciled against Cinegy.
- **Feature doors appear only when enabled**: 📰 شريط الأخبار, 📑 إدارة الموجز,
  🚨 إدارة العواجل, 🗂 محتوى البرامج, 🎞 جدول المواد, 🤝 تسليم.
- **⚙️ الإعدادات** and **🗂 أدوات الإدارة** only for administrators.
- **🤏 One-hand mode** turns every screen into one full-width button per row,
  for a phone held in one hand with the clock running.

### If you get lost

Three ways back, on every screen: **🏠 القائمة** returns to the menu,
**↩️ رجوع** goes one screen up, and **❌ إلغاء** abandons whatever you were
typing without saving it.

---

## Putting a graphic on air

1. **📋 القوالب** — or a ⭐ favourite, or **🔁 تكرار مع تعديل** to reuse the last
   one with changes.
2. Fill the fields. Values are typed, or taken from a preset, or recalled from
   this field's recent values.
3. **Review.** The bridge shows exactly what it is about to send, including the
   layer, and warns if that layer is reserved or already carries something.
4. Confirm. The command goes out, the result is audited with a correlation id,
   and the menu comes back with the new live row on it.

**Before every SHOW** the bridge reads the target layer from Cinegy and refuses
if it cannot verify it. A graphic sent to a layer whose state is unknown is how
two things end up on screen at once.

**While it is live:** **✏️ تحديث نص** writes new values through the postbox
without re-showing the scene, so the entrance animation does not replay.

**⏱ عرض مؤقّت** shows with an automatic hide after a chosen time. Some templates
are marked sensitive and carry a maximum air time that applies whether or not
you asked for one; when that ceiling is about to expire the bridge offers to
extend rather than simply pulling the graphic.

---

## Taking it off

| Control | What it does |
|---|---|
| 🙈 **اخفاء طبقة** | `HIDE` on one layer. The scene stops being visible; it is not exited. |
| 🚪 **خروج من المشهد** | `EXIT_SCENE_LOOP` — the scene plays its outro and ends properly. |
| 🚨 **إخفاء الكل** | Emergency. Hides every layer the administrator selected in `HideAllLayers`. See the permission note in [Who may do what](#who-may-do-what). |
| ↩️ **تراجع** | Within a short window, restores what was on that layer before the last change. Off by default. |

`HIDE` and `EXIT` ask the same per-layer permission question that `SHOW` does.
Taking a protected graphic off air changes the screen as much as putting one on
it — and for a while, typing `/اخفاء 9` reached Cinegy after the *button* had
refused the same operator, with the audit recording it as a success.

---

## The four content systems

Four systems, because they are four different jobs with four different
divisions of labour. They are not variations on one table.

### 📰 شريط الأخبار — the news ticker

Edits a text file that Titler reads as a crawl. One locked draft at a time;
nothing reaches the file until you review and publish. Manual entry, or import a
UTF-8 `.txt`, or pull from a **Google Sheet** (manual or on a timer). Publishing
takes a backup and refuses to write if the file changed underneath the draft.

### 📑 إدارة الموجز — the bulletin (mojaz)

A full bulletin from a table: each row is an image, a headline and a story,
played in order **in one scene that is not re-shown between rows**. A library of
saved bulletins, each with its own rows and timing. Per-row image choice
(own upload / follow the previous / the template's own), uploads validated and
resized to the template, and per-row durations. Scheduled runs survive a
restart. Breaking news outranks it: an urgent item pulls the bulletin, and you
are asked whether to send it now or after the bulletin ends.

### 🚨 إدارة العواجل — the urgent board

A table that advances by itself. Interval, repeats, mode (text / exit motion /
auto-hide), a total-time ceiling, and a deliberate gap between stories in exit
mode. In exit mode the layer is hidden before each re-show, because a scene
that is re-shown without being hidden keeps the values it was loaded with — the
board looked stuck on the first story while the engine was in fact advancing.

### 🗂 محتوى البرامج — programme content boards

For programme banners, where the producer writes the episode's texts in
advance and the operator on air only chooses which line goes up and when. There
is no fixed number of these, so it is a general mechanism rather than a fourth
hard-coded board.

**Every board is bound to a template you choose, and the template decides each
row's fields and the layer.**

1. **➕ جدول جديد** → **step 1**: choose the template. Each shows its field
   count; ✅ usable, ⛔ ineligible **with the reason** (a scene that declares no
   text field cannot carry a board, so it is not offered and then failed).
2. **Step 2**: name the board as the operator will see it on the button.

The template does not change afterwards — another programme means another board.
The board header always states its template, its layer and **its fields by
name**.

Rows are entered one at a time or as one pasted block (one line per row, fields
separated by `|`; short lines fill their tail fields, over-long ones are
refused **by line number with the reason**). Rows reorder, can be disabled
without deleting their text (ten prepared, six needed today), and delete.
▶️ shows through the same funnel as every other graphic.

**Who may fill a board** is per board — everyone / administrators / the owner —
and is cycled from a button that shows the current setting on its face.

If a scene is later re-cut in Titler and a field disappears, the producer's text
for it is **kept and not sent**, and the screen names the missing field. Losing
a producer's work to a designer's edit is the wrong answer to the wrong person.

Text only, deliberately. Images are a different problem — upload, storage,
lifetime — and are out of scope here.

---

## Scheduling

**📅 الجدولة** holds future SHOW events. They survive a restart, warn when two
target the same layer inside a configurable window, can be paused, copied,
retimed, and given a recurrence with an end date.

- A scheduled event runs the **latest saved version** of what it points at, not
  the version that existed when it was booked.
- Failed events can retry, with bounded exponential backoff, if you opt in.
  Zero retries is the default.
- Every attempt is recorded in `logs/schedule-execution.jsonl` — content-free,
  machine-readable, and enough to answer "did last night's bulletin actually
  start, and how late".

---

## Watching the output

The bridge can capture the channel's output and send you a still or a short
clip in chat, using **ffmpeg** against the playout feedback stream (SRT by
default). It also watches the source and alerts when it goes away — and, since
8.51.0, when it **flaps**: a source that fails and recovers repeatedly never
tripped a consecutive-failure counter, even though monitoring could not see the
output half the time.

Snapshots are throttled and retained for a configurable window. Keeping the
playout machine's CPU free matters more than a fast preview: the capture runs as
a bounded background job with its own watchdog and restart limit.

---

## Settings

**⚙️ الإعدادات** — administrators only. Changes take effect immediately and are
saved to `config.json` without a restart, except where a screen says otherwise.

**Eleven doors:**

| | | |
|---|---|---|
| 🔐 الأمان والصلاحيات | 🔴 التشغيل على الهواء | 📚 القوالب والطبقات |
| 📰 شريط الأخبار | 🚨 جدول العواجل | 🗂 محتوى البرامج |
| 📅 الجدولة | 📊 المراقبة والتنبيهات | 🗄️ الملفات والاحتفاظ |
| 🔔 الإشعارات | 🛠️ خيارات متقدمة | |

Every setting lives in **exactly one** door, and a test enforces it — as it
enforces that the manual names every door the code defines, which is how a list
saying "the eight doors" was caught listing eight of nine.

**Most values are set by pressing, not typing:** numbers with ➖/➕ at a step
suited to their size, showing the default and the range, with a ⌨️ button for
anyone who knows the exact figure; hours and weekdays as a grid; templates and
layers as pickers that cannot be misspelled. Out-of-range values are **refused,
not clamped** — silently changing a number somebody typed is worse than telling
them it will not fit.

**Finding things:** 🔎 بحث matches the setting name or its Arabic description;
📝 المعدّل فقط lists everything that differs from its default, which is the first
place to look when the bridge behaves unexpectedly; 🧭 مبسّط and 🛠 متقدم split
daily settings from technical ones.

**Secrets** are shown by length, not value, in lists and in import review, so a
token does not end up in a chat history or a screenshot. The single-setting
screen does show the value, because a join code is something an administrator
needs to read in order to hand it over.

---

## What gets written where

| Path | What | In git? |
|---|---|---|
| `config.json` | Everything configurable. Backed up on every save under `config.json.backups/`. | No |
| `templates.json` | The template registry. | No |
| `logs/bridge.log` | Runtime log, rotated at `LogMaxSizeMB`, keeping `LogKeepFiles` generations. | No |
| `logs/audit.jsonl` | **Permanent** structured control and security trail. UTC timestamps, correlation ids shared with air operations, secrets redacted. | No |
| `logs/onair.json` | What is on which layer. Backed up and self-repairing from the last good copy. | No |
| `logs/schedule-execution.jsonl` | One record per scheduled attempt. | No |
| `logs/boards/` | One file per programme content board. **The directory is the index** — no index file to fall out of step with it. | No |
| `dist/`, `artifacts/` | Build output. | No |

Tests never touch any of these: `Run-Checks.ps1` hands the bridge a temporary
runtime directory.

---

## Running it as a service

Three ways, in increasing order of ceremony:

1. **Scheduled Task** — `scripts\Install-BridgeTask.ps1`. Starts at boot,
   restarts on crash. The lightest option and the usual choice.
2. **Windows Service via NSSM** — `scripts\Install-BridgeService-NSSM.ps1`. A
   real service with its own stdout/stderr logs.
3. **BridgeManager.exe** — a desktop app; see below.

Each has an uninstall script beside it. `scripts\Test-ServiceLifecycle.ps1`
exercises the managed lifecycle and runs in CI.

---

## The desktop manager

`Manager/BridgeManager/` — a .NET WinForms app for running the bridge without
installing a service or opening a PowerShell window. Build it with
`scripts\Build-BridgeManager.ps1`; CI builds it and runs its `--selftest`, which
is the only test framework it has.

- Start / Stop / Restart, a live log pane, and a settings editor.
- **Start on open** — starts the bridge whenever you open the app, not only when
  Windows launches it from the Run key. Off by default: a bridge that starts
  itself is a decision about the air, made deliberately rather than inherited.
- It **adopts** an already-running bridge rather than starting a second one.
- "Errors and warnings only" includes the alarms the manager raises about
  *itself* — a launch that fails before PowerShell writes anything produces no
  `[ERROR]` line, and the pane used to read "no errors" while the bridge was
  dead and auto-restart was off.

---

## When something goes wrong

**First stop: 📝 المعدّل فقط in Settings.** It lists every setting that differs
from its default. Unexpected behaviour is usually a setting somebody changed.

**ℹ️ الحالة / 📊 الحالة الكاملة** — Air server, channel, tracked templates, each
live scene with its layer, source, elapsed time, and the operator alias or the
Cinegy event metadata.

**🧪 التشخيص** (administrators) — queues, locks, schedule state, Cinegy
telemetry, local paths, with tokens and stream secrets redacted. It can produce
a redacted ZIP containing a health summary and sanitised recent log lines, and
**never** configuration, on-air state, editorial values, secrets or actor
identifiers.

**📜 السجل** — the last `AuditTrailSize` actions in chat, with who did each.

**Common situations:**

| Symptom | Where to look |
|---|---|
| Bot silent | Is the process running? `logs/bridge.log` tail. Telegram connectivity line. |
| "Not allowed" for someone who should be | `AllowedChatIds` vs `AllowedUserIds` — in a **group** the chat id is not the user id. |
| SHOW refused | The layer could not be read from Cinegy, or it is reserved, or the template is disabled, or maintenance mode is on. The refusal names which. |
| Graphic stuck on screen | 🙈 hide the layer, then 🚪 exit the scene. 🚨 إخفاء الكل if more than one. |
| Board repeats its first row | Fixed in 8.52.0 — the layer is now hidden before each re-show. If you see it, you are on an older build. |
| CI red, local green | The tests pin the shipped `templates.example.json`; a local `templates.json` must not leak into them. |

**Never send test SHOW/HIDE/EXIT commands into a working environment.** Use the
dedicated non-production layer that `TemplateTestLayer` configures. Status reads
are always safe.

---

## Upgrading

Releases are built by `Build-Release.ps1` into an allow-listed ZIP with a
`release-manifest.json`, a SHA-256 checksum and optional Authenticode signing.
The package carries only what the bridge loads by name — a gate fails the build
if a required file is missing from it.

Side by side is the documented path: unpack the new version beside the old one,
point it at the same `config.json` and `templates.json`, run `Run-Checks.ps1`,
then stop the old process and start the new one. Rolling back is the same
sequence in reverse; state files are versioned and migrate forward, and a
corrupt primary JSON repairs itself from the last good backup.

See [`RELEASE.md`](../RELEASE.md) for the release ritual and
[`docs/RELEASES.md`](RELEASES.md) for what each version changed.

---

## Developing on it

Read [`AGENTS.md`](../AGENTS.md) first — it is the house style, and it is kept in
sync with the code. The short version:

- **PowerShell 7**, `Set-StrictMode -Version Latest`. `Parts/*.ps1` are
  dot-sourced and share the bridge's scope; `Modules/*.psm1` are real modules
  with no knowledge of Telegram, Cinegy or the disk.
- **A guard is written once, at the source** — not at each of the N mouths that
  reach it. That is why `HIDE` and `EXIT` ask their permission question inside
  `Invoke-HideLayer` rather than in the four callback branches that used to.
- **Every guard gets a test, and the test is seen red first.** A guard nobody
  has watched fail is a guard nobody knows works.
- **State files** need a unique temp name, a verified backup, and an atomic
  replace. `Write-BridgeValidatedJson` already does all three; use it.
- **A setting is registered in four places**: the default, the schema
  description, the category, and the label.
- `Run-Checks.ps1` is the gate: required files, JSON, parser, PSScriptAnalyzer
  (warnings fail), and Pester. Green before every push.

**Telegram limits worth memorising**, because each has cost this project a bug:
`callback_data` ≤ 64 **bytes** (an Arabic key is two bytes a character), a
message ≤ 4096 characters, `copy_text.text` ≤ 256, and a rich payload ≤ 12 KB.

---

*Bot screens: **❓ مساعدة** in the bot. Repository documentation:
[`README.md`](../README.md). Release notes: [`CHANGELOG.md`](../CHANGELOG.md)
and [`docs/RELEASES.md`](RELEASES.md). Security reporting:
[`SECURITY.md`](../SECURITY.md).*
