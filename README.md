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

## Version 8.38.0

The reports export HTML, which is for reading; an archive, a monthly review,
or a merge with the station's own as-run log needs columns, and a picture of
a table has none. Administrators can now export the operation log window they
are looking at as CSV, filters included. Two details decide whether the file
is usable at all and neither is visible from the code: it is written UTF-8
**with** a BOM, or Excel renders Arabic headlines as mojibake, and it is
written with `ConvertTo-Csv -UseCulture`, because on an Arabic Windows the
list separator is not a comma and a comma-separated file opens as a single
column. Escaping is `ConvertTo-Csv`'s own, since news copy carries commas and
quotes — the row a hand-rolled join breaks on. Editorial values are not
exported: the audit records which template went out, never the words on it.
A partial export says so in its caption rather than becoming the archive
nobody knows has a hole in it.

This also fixed an omission behind it: `Get-ReportRecords` dropped the
`message` field that carries why a failed operation failed, so every report
above it had the fact of a failure and nothing about its cause. It is carried
now, and redacted on the way out — an engine error can quote a URL with a key
in it.

## Version 8.37.0

The operation log could be narrowed to a window and to "mine versus
everyone", and that is not the question a fault raises. "Who touched this
template" and "what did this operator do" were both answered by reading forty
rows looking for one name. The log now has a filter button that offers the
operators and templates **present in the window being read**, most active
first — a picker listing every operator the station ever had, or every
template in the registry, would be mostly choices that return an empty
screen, and an empty screen teaches people to distrust the filter rather than
to narrow it. Filters survive a change of window, since widening from 24
hours to 72 is the first thing anyone does after narrowing. The heading names
whatever is filtered, so a narrowed screen is never read as the whole
picture. Choosing another operator is gated exactly as the all-users view is:
a non-administrator asking for somebody else gets their own log. Both lists
are capped and say what they left out.

## Version 8.36.0

A failed push reported one thing — the error the push came back with — and
that sentence is usually the symptom rather than the cause: a timeout does
not say whether Cinegy is down, the scene file moved, or somebody else holds
the layer. The operator's next move was to open the status screen, the layers
screen and the template screen and assemble the answer mid-shift from three
places. The failure message now carries a "why didn't it appear?" button that
answers in one screen, in the order the question is actually asked: Cinegy's
freshness first (when it is unreachable every other answer is noise), then
whether the `.cintitle` is still where the registry says — the cause no
status screen shows — then who holds the layer, whether this operator is
allowed the template, and whether maintenance is blocking air commands. The
check queries nothing and sends nothing: every line comes from cached state,
configuration or the file system, so running it during a live fault cannot
itself change what is on air.

## Version 8.35.1

Five callers indexed a template's saved presets after checking the upper
bound only, and PowerShell reads a negative index from the end of the array —
`Presets[-1]` is the last preset. So an out-of-range index did not fail, it
quietly selected the wrong entry: the wrong text on air for a preset button,
the wrong preset deleted for the delete button. Two other callers did check
both bounds, which is how a guard drifts — written twice, remembered once.
All seven now go through one `Get-TemplatePreset` accessor that returns
`$null` outside either bound. Nothing reachable sends a negative index today,
since the bridge builds every one of those buttons itself from a loop over
the presets; this closes the missing bound rather than an open hole.

## Version 8.35.0

Every writer of `templates.json` has taken a timestamped copy since the
registry screens were built — preset edits, definition edits, reminder
minutes, registry imports — and there was no way to get one back: the copies
accumulated on the server and an administrator who deleted the wrong template
had to go find the folder. Two things follow from that. The registry backups
now have a restore screen beside import/export, mirroring the configuration
one: it names every template the restore would remove, change or add before
writing anything, refuses outright when a template that is on air or booked in
an upcoming event would be touched, and saves the current registry first so
the restore is itself undoable. And the four writers now share one backup
function, because only one of them pruned — the other three grew
`templates.json.backups` without limit, and the only thing that ever noticed
was the storage warning in the health screen, which offered nothing to do
about it.

## Version 8.34.0

The shift readiness screen read runtime state only — what is on air, what is
pending, which chats are quarantined — and never read configuration. So a
shift could begin on a bridge with safe rollback off and no test layer, and
nothing anywhere said so. Three protections ship off by default
(`EnableSafeRollback`, `TemplateTestLayer`, `EnableDpapiSecrets`), which is
exactly the problem: a protection nobody was told about is a protection
nobody has. The screen now lists every guard currently off, each stated as
its consequence ("no undo after a wrong graphic") with the setting name after
it so it can be found and flipped. A disabled guard is deliberately kept out
of the ready/not-ready verdict: it is a standing configuration choice, not
something the outgoing shift left behind, and a verdict that can never turn
green stops being read.

## Version 8.33.0

A publish from Telegram writes the ticker **and** mirrors it back to the sheet,
and the message said only that the ticker was written. So the one failure that
matters here — the air is right and the sheet is now behind — reached the
operator as an unqualified success, and the sheet stayed wrong until somebody
read `bridge.log`. The publish message now names both, says plainly when the
mirror failed (and that the air is nonetheless correct, which is what stops a
needless re-publish), and stays silent about the sheet when no write-back is
configured. It covers all three publish paths, since they share one function.

The automatic sheet sync publishes to air on its own clock, and its failures
went to `bridge.log` and to a screen you have to open on purpose — which during
a shift means nowhere. An editor whose sheet had become unreachable watched the
ticker keep showing yesterday with no reason to suspect anything. After
`NewsSheetFailureAlertAfter` consecutive failures (default 3, 0 stays silent) an
alert carries the reason and how long since the last successful publish, and a
second line arrives when it recovers. One miss is weather, not news, so the
alert waits for a run; it repeats only once per further run of that length
rather than on every sync; and it carries a `-Cause`, so 8.32.0's hourly cap
bounds it. A cycle skipped because someone holds the draft is the sync working
as designed and does not count, and a sheet that was reached with nothing new
resets the streak.

## Version 8.32.0

Asked after the 8.31.1 flood whether anything caps the number of notifications:
nothing did. `RepeatAlertWindowHours` counted repeats and annotated them but
sent every one; quiet hours are off by default and only defer non-urgent
notices overnight; the outbox cap bounds the queue, not the send rate; and the
429 handler reacts only after Telegram has already refused. The repeat counter
could not even see the draft warning, whose text starts with ⏳ rather than one
of the failure glyphs it matches.

`AlertMaxPerCausePerHour` (default 10, 0 removes the cap) lives under Settings →
notifications. Past it a cause is held, and one line arrives once it goes quiet:
"🔇 كُتم ٤٧ تنبيهًا من نفس السبب خلال الساعة الماضية".

Per cause, never a global budget — a global quota spent by one chatty fault
would swallow the unrelated alert that mattered. Causes come from
`Get-BridgeAlertCause`, which strips numbers, so every repeat of one fault
shares a key however much its layer or countdown differ, and the count is per
chat so one operator cannot mute another's notices.

It is opt-in and must stay that way: only a message carrying `-Cause` is
capped, and only unsolicited notices carry one. An operator putting fifteen
graphics to air in an hour produces fifteen confirmations whose causes are
identical once numbers are stripped, and capping those would hide the air
itself. Every held notice is still written to `bridge.log` — the cap is quiet
towards the operator, never towards whoever maintains the bridge.

## Version 8.31.1

After the bridge was updated, the **⏳ ticker draft is about to expire** warning
started arriving on roughly every tick instead of once — a flood in the chat the
alarms use. The `WarnedAt` mark that prevents the repeat was written with
`Add-Member`, and `Add-Member` on a dictionary adds a note property while
`ConvertTo-Json` serialises only the dictionary's keys: the mark was written,
saved, and silently gone, and invisible to a reader looking the key up. The
8.30.0 `Get-JsonProp` fix did not cause this — it exposed it, because before
that the warning never fired at all (it could not read `OwnerChatId` either).

The **⏳ extend** button had the same fault with a worse effect: it wrote
`UpdatedAt` as a note property while the key kept its old value, so the draft
stayed exactly as idle as it was and the warning kept arriving however many
times the button was pressed. It now actually extends.

Writing state goes through `Set-JsonProp` / `Remove-JsonProp`, the writing half
of `Get-JsonProp`, so no caller has to know whether it holds a dictionary or a
PSCustomObject. All 43 `Add-Member` call sites in the repository were audited:
every other one targets a `[pscustomobject]` or a `ConvertFrom-Json` result and
is correct; one (`Set-AirNoticeMuted`) hand-wrote the rule correctly but tested
`-is [hashtable]`, and now shares the one spelling. `Get-JsonProp` reads the key
first and falls back to a note property, restricted to `NoteProperty` so a
missing key cannot resolve to a real .NET member such as `Count` or `Keys`.

## Version 8.31.0

The 📰 news ticker and 📑 bulletin help chapters now cover what shipped after
they were written. The execution log both screens gained in 8.28.0 was not
mentioned in the guide at all, and the draft hand-over is new in 8.30.0. The
ticker chapter now lays out the three ways a draft can end — publish, hand to
the next editor, or discard with the text returned — plus draft expiry and the
log that says whether the automatic sheet sync ran. The bulletin chapter names
its own execution log, and its appearance-sync explanation, which had been
written out twice, is written once.

The one-screen guide also stops wasting its budget. The manual has been larger
than a single Telegram message for a long time (an operator's serialises to
about 15000 characters against a 12000 limit), and the cap stopped at the first
chapter that did not fit — leaving over a thousand characters unused and
dropping 🆘 حين يحدث خطأ, the chapter most worth having on screen, to keep the
run contiguous. Every chapter that fits is now included, in the manual's own
order, with whatever is missing named as before: an operator sees 9 chapters of
11 rather than 8, an administrator 8 of 14 rather than 7 — and that is with the
new content above, not before it.

## Version 8.30.0

Whoever holds the news draft lock now has a way out that is neither publishing
nor destroying their work: **🤝 سلّم المسودة للتالي** leaves the draft exactly
where it is and simply stops it belonging to anyone, so the next ✏️ adopts it
with every headline intact. A pending unlock request is settled in the
requester's favour and the slot held for them; an open draft keeps whoever
handed it over as the person its expiry warning and hand-back are addressed to,
so it cannot die in silence. 🗑 إلغاء المسودة now returns the text before
deleting — it was the only draft ending that cost every typed word silently.

Openness is marked by an explicit `IsOpen` key rather than `OwnerUserId = 0`,
because 0 is also what an unreadable owner reads as: that spelling made every
draft look unlocked, and a lock that fails open is worse than no lock.

`Get-JsonProp` tested `-is [hashtable]`, but `[ordered]@{}` is an
OrderedDictionary — not a Hashtable, and it exposes no keys as PSObject
properties — so it answered `$null` for every key of anything the bridge builds
with `[ordered]`. That reached further than the feature above: the news draft
expiry warning and its hand-back read `OwnerChatId` through it and so never
fired for a live draft, only for one reloaded after a restart. It now reads any
`IDictionary`.

The 🧾 execution log screens were sending a keyboard Telegram refuses outright.
The back row came out of a `switch` used as an expression, and a switch writes
its result to the output stream, which unrolls one level — stripping the leading
comma that made it a row and leaving a bare button where a row belongs. The
repair warning now names the function responsible and what was wrong with each
row, instead of a count nobody can act on.

## Version 8.29.1

`✅ جاهزية المناوبة` in admin tools did nothing at all: the screen was built and
sent, and Telegram refused the whole message with 400 `InlineKeyboardButton must
be an Object`. One row in `Show-ShiftReadinessScreen` was written with a leading
comma *and* a trailing one — the first makes the row an array, the second joins
it to the next row as a single comma expression, so every row ends up wrapped
twice: `[[button]]` where the Bot API wants `[button]`. Nothing shows on screen,
and the one log line names neither screen nor row.

The repair pass added in 8.27.0 for exactly this shape was silently inert: it
tested each cell with `$_ -is [pscustomobject]`, and since `[pscustomobject]` is
an alias for `PSObject` — which wraps everything coming off a pipeline — that is
`True` for arrays, strings and ints alike. It now tests the real
`PSCustomObject` type, flattens an over-nested row back into its buttons rather
than dropping the row, and counts a repair by shape rather than by cell count so
a single nested button can no longer repair itself in silence. A test scans
`Parts/` and rejects the source pattern outright.

## Version 8.29.0

An audit of every file that records events and what actually bounds it.
`bridge.log`, `audit.jsonl`, snapshots and staged uploads were already bounded
by declared settings. Three were not: `schedule-execution.jsonl` (trimmed at a
number hardcoded in 8.27.0), `schedule.json` (finished occurrences were never
removed, and the whole list is re-serialised on every change), and
`access-guard.json` (nothing ever left it but a manual unblock). Each now has a
registered setting — `ExecutionLogKeepRecords`, `ScheduleHistoryKeepDays`,
`AccessGuardKeepDays` — under Settings → maintenance, where **0 means keep
everything**, since "never trim" is a legitimate answer for an auditable record
or a permanent deny list. Schedule trimming touches only `completed`/`failed`
occurrences; `pending` and `interrupted` are still owed to someone and are
never dropped, nor is any entry whose timestamp cannot be read.

## Version 8.28.0

The execution log now covers everything the bridge fires on a clock, not just
scheduled graphics. A scheduled bulletin's outcome used to live on its own
schedule record and die with it, and the automatic news-sheet sync — which
publishes to air every few minutes — reported only to `bridge.log`. Both now
write to the same log, read by the same screen, separated by a `Kind` field
(`show` / `mojaz` / `news`) with its own glyph per kind. Records written before
`Kind` existed are read as scheduled graphics rather than discarded, so the only
scheduling history the station has survives the change. Reachable filtered from
the bulletin schedules screen and from news-ticker management, or unfiltered
from the schedule menu.

## Version 8.27.0

A new **schedule execution log** screen under 📅 الجدولة. `Write-ScheduleExecutionEntry`
has recorded every fired occurrence since scheduling shipped — template, layer,
due time versus actual time, attempt, result, duration, redacted failure reason —
and a search of the tree found no reader at all: the only consumer was a
file-size row on the diagnostics screen. The screen now answers "why didn't that
scheduled graphic appear?", and leads with how late each occurrence ran, since a
graphic that fired four minutes after its slot did appear and "success" alone
hides that. The file also grew unbounded with no rotation; it is now trimmed to
the newest 2000 lines every 12 hours.

Also fixes a silent failure: one Telegram 400 (`InlineKeyboardButton must be an
Object`) reached the log, which drops the *entire* message — the operator taps
and nothing happens. Auditing every keyboard builder found none malformed, but
revealed that the button-colour-stripping pass rebuilt rows and repaired that
shape *by accident*, and is skipped entirely when `EnableButtonStyles` is on —
the live default. `ConvertTo-TelegramReplyMarkupJson` now repairs malformed rows
at the wire and logs how many, instead of losing the message silently.

## Version 8.26.7

Presentation fixes. The "What's New" renderer prefixes every `Items` element
with a bullet, and the 8.26.2–8.26.6 entries had been written split across
several elements as if they were wrapped lines — so half a sentence rendered
as its own bullet. Each entry is one complete string again, with an Arabic
proofreading pass over the same block. The admin tools picker now packs its
four categories two to a row like the settings picker (three rows instead of
five), and the users/content categories pair their buttons too; the restart
button deliberately keeps its own row, as danger actions do throughout.

## Version 8.26.6

A concurrency/re-entrancy audit found one real bug: `Set-PendingState`
replaced a pending flow without releasing what the outgoing one held. Only
`Complete-PendingStateCleanup` frees a layer lock, and it runs solely on an
explicit clear or on expiry — so leaving a half-built template and tapping an
older inline button still visible in the chat stranded the lock for the life
of the process, refusing every later SHOW on that layer for every operator.
Fixed once in `Set-PendingState` (≈50 call sites), releasing only what the
incoming state does not carry forward, since `show_fields` → `show_review`
legitimately keeps the same `LockLayer`. Everything else checked — single
-threaded guarantees, tick-loop collection snapshots, and the whole
BridgeManager UI/process lifecycle — came back clean.

## Version 8.26.5

Three real bugs from a five-dimension audit, each verified in the code before
being fixed. `Import-ScheduleEvents` emptied the live schedule list before its
parse loop and read a hashtable key with no guard — and a missing key throws
under `Set-StrictMode -Version Latest` — so one entry from an older build wiped
every future scheduled graphic permanently. `Save-DisabledUsers` and
`Save-AccessGuard` bypassed the validated atomic writer, so a torn write
silently re-enabled every disabled account. And the startup guard that drops
stale auto-hide timers ran before the imports that populate them, pruning two
empty lists. Also adds tests for the two highest-risk untested branches: the
pre-show layer clear and the auto-hide refusal when Cinegy is unreachable.

## Version 8.26.4

The admin tools screen (`Get-AdminToolsKeyboard`) was a flat wall of ~15
buttons mixing user management, content, live relay, and dangerous system
actions — the same problem the settings screen already solved with category
tabs. Reused that exact pattern: it's now a 4-category picker (users,
content, health, system), with a new `Get-AdminToolsCategoryKeyboard`
carrying the original buttons unchanged — same `callback_data` throughout,
so no downstream handler needed touching.

## Version 8.26.3

Two follow-ups from the earlier security/performance review: `Complete-StreamUrl`
now rejects any RTMP destination that doesn't start with `rtmp://`/`rtmps://`
(ffmpeg resolves its output protocol from the URL scheme itself), and
`Get-BridgeHealthRows` — read by both the bot's health-center screen and
`health-snapshot.json` — now reports the dead-chat quarantine count as its
own row, so BridgeManager's stability tab picks it up automatically. Also
throttled `Update-DeadChatsSweep`, the one tick step with no self-throttle
guard.

## Version 8.26.2

A documentation-and-UI pass requested after the security review. `Get-ArabicCountNoun`
existed since 8.25.1 but was only used in a few places; this sweep found and
fixed roughly 30 hardcoded number+noun constructions across 16 files in
`Parts/` (reminders, schedule notices, news-lock timers, list headers,
health-center rows, reports, the bulletin loop-fit warning, restart-storm
alerts) that used a fixed noun form regardless of count. Also added three
paragraphs to the bot's own guide for shipped-but-undocumented features:
the material-schedule button, the shift-handover button, and shift
readiness / manual quiet-hours.

## Version 8.26.1

A security-review fix: the snapshot cooldown was keyed off a capture's
*completion* time, so a burst of taps inside the few-second capture window
itself could each spawn a concurrent `ffmpeg` process against the live
source from any allowlisted (non-admin) account. `Start-SnapshotJob` now
refuses a new request outright while one is already in flight.

## Version 8.26.0

BridgeManager (the desktop supervisor) now shows the bridge's own live
health, not just its process uptime: the bridge mirrors its "🩺 مركز صحة
النظام" rows (Telegram connection, Cinegy health, output monitor, relay,
storage, schedule) to `logs/health-snapshot.json` every ~60s, and the
manager's stability tab reads it, flagging the data as stale past five
minutes. That tab also moved from five equal-weight numbers to colour-coded
cards, a template-name/usage-count overlap in the usage chart is fixed, and
every count across both manager windows now uses correct Arabic noun
agreement instead of a fixed plural.

## Version 8.25.2

The news lock hand-over request now survives a restart: it is persisted
on creation, cleared on settlement, and restored at startup, so an
answer window spanning a restart still ends in an automatic grant on the
first tick instead of dying silently.

## Version 8.25.1

A usage-digest correction driven by one live report: the ranking is now
labelled cumulative, the outcome breakdown sits back under its own
since-restart line, every counted noun uses the right Arabic form, the
expired access request reads «طلب صلاحية» instead of its state key, and
the changed-settings line admits how many names its cap hid.

## Version 8.25.0

A log-driven stability release (26 days, 472 pushes): resume snapshots now
survive a transient layer lock, the dead-chat roster gains a one-shot
reachability probe (success restores, failure stays silent), every
unhandled button/photo/document error answers its operator instead of
dying silently, and a fourth startup inside 24 hours notifies admins once.

## Version 8.24.0

Seven post-8.23 proposals: a copy-ready diagnosis twin, pinned recurring
alerts that update in place, per-template last-air in the catalogue, a
two-hour manual quiet inside the quiet-hours path, a read-only shift
readiness screen, 30-day archival of undecided dead chats, and the last
on-air action under each user.

## Version 8.23.0

Three log-measured items: dead-chat quarantine after three undeliverable
failures (401/403 only, admin-rostered with restore and revoke), invalid
templates listed in the catalogue with their load reason and a guarded
delete, and expiry messages that resume the draft to its prompt or review —
never straight to air.

## Version 8.22.0

Four proposed features: a material-end alert (off by default, enabled in
minutes), an auto-attached handover summary (latest failures plus the most
repeated cause), danger styling on both emergency hide-all entries, and an
opt-in engine-health screen (dropped frames as a since-last-look delta,
license state, now and next) behind a default-off setting.

## Version 8.21.0

Five items from the integrated review (docs/REVIEW-2026-09-10.md).

The output-failure alert now names the streaming server itself - read from
the last ffmpeg stderr, kept on every failed capture and cleared on the
first success - and always ends with a next step for the first broken link:
channel, relay, server, or source.

Scheduling can anchor a one-off event to channel material: "show the strap
30 seconds into the segment" instead of a wall-clock time. The event keeps
an absolute fallback, and the queue re-resolves the anchor from the rundown
every tick, so a shifted programme carries its graphic with it.

The rollback review now shows two frames - before the push and as it looks
now, the latter captured on demand when the review opens. Either may be
missing, and then the text review stands alone as before.

The weekly digest folds in two new sections: what the bridge noticed
(screens near their payload cap, templates idle for a month, failures
repeating under one cause, settings differing from defaults by name only)
and flow timing (slowest templates to air, abandoned drafts by label, never
content).

## Version 8.20.0

Two items from the standing backlog, the cheapest and highest-priority ones.

A guidance message already computes the fix it recommends - "the hold is
twice the loop length (750 frames): make it 750 frames or turn on
appearance sync" - and used to leave the operator to retype that number by
hand in a separate free-text prompt. A button beside the warning now applies
it directly, and disappears on its own once the warning does.

The full status screen also names a gap that cost two backlog decisions
before it was measured: the Cinegy HTTP API documentation used to design new
features was Air 26.2, the station's installed engine reports
22.12.0.4921.15212, and one review had to re-derive that fact from the
device before trusting the docs. The status screen now reads the installed
version from the same client identity it already displays and says so when
it differs from the documented baseline.

## Version 8.19.0

Four things, three of them measured on this station's own log rather than
guessed at.

The two status screens no longer fold. Everything they know is on the screen,
in named sections with a rule between them, and the identity, the clock and
the programme the channel is playing sit above the layer table - the last of
those was reaching the screen folded away, which is the same as not reaching
it.

Names: 7 of 8 users in the audit log had none, and 366 records named a raw id
instead of a person, because only an access request ever captured a name and
most operators were added directly by an administrator. Telegram sends the
name with every update; the bridge now keeps it the first time, and an
administrator's own alias still wins.

Recurrence: 707 of 752 warning and error lines belonged to a cause already
seen three times or more - one of them repeated 22 times across a fortnight
with every alert reading like the first. From the third occurrence an alert
says it is a recurrence and when it started. Six-hour window, adjustable, 0
turns it off.

And the full status warns when the Cinegy address is outside a private range.
The Cinegy HTTP interface has no authentication at all: reaching the port is
the authority to put graphics on air.

## Version 8.18.1

The review screen offers an edit button after the fields are typed by hand.
It always had one after values arrived ready-made from a preset, and never
after an operator typed them - the one route where a misspelling is possible
at all. Getting a typo back cost a cancel and a restart.

## Version 8.18.0

Six features from a plan that one question to the station reordered.

The roadmap was ranked by what could be measured in the code. Then the station
was asked what had actually gone wrong on air last, and answered: a graphic
stayed up and was never taken down. None of the top three candidates addressed
that, so it went first.

The alert for exactly that failure existed and still allowed it, because it fired
once, to administrators, with no button - whoever missed it missed it for good.
It now escalates on a widening interval while the record survives, goes to the
operator who published the graphic rather than only to administrators, and
carries the hide button on the notice itself.

The bridge knew what it had put on air and nothing about the programme
underneath. Two read-only calls answer that, both measured against the live
channel before a line was written: the status screen names what is playing with
minutes remaining and what is cued next, a material screen shows the channel day
with the current item marked, and a handover screen gathers what a shift change
needs - what is on air and since when and who published it, the upcoming
schedule, the current programme, and the open drafts with their owners named -
then records the handover. The station said shifts exist and the handover is
usually spoken, which is where what nobody mentions gets lost.

Spell checking arrives under two constraints: the text never leaves the network,
and it never blocks - a breaking headline held back over a proper noun is worse
than the typo. Shape errors need no vocabulary. The second level, "the station
has never written this word", flagged ordinary Arabic on its first build, so the
two lists were given separate jobs: an embedded 422-word Arabic core suppresses,
and the station own vocabulary qualifies, waking the check only once the newsroom
has written five hundred real words. Clitic stripping reads the common prefixes
and suffixes back to their stems.

A failed output capture now names which link looks broken - channel, relay or
source - rather than reporting the symptom. Every check is read-only; SetOutput
changes what goes to air and is never sent.

The proxy warning was measured before it was built: twenty-two of twenty-four
scheduled items carry no local copy, so reading from source is normal here and an
always-on alert would fire on nearly everything. It ships off, as an
administrator option, and distinguishes no copy from a transfer stopped part way.

The repository stopped this work four times: the paging guard twice, both
answered with a written reason rather than a workaround; the analyzer on an empty
catch block, in a tree that had none; and an existing test broken by the new
failure message, which was fixed rather than worked around.

## Version 8.17.0

The rich-table guard, after the classification that was its precondition.

This item had been open in the plan since 8.6, and 8.15 declined to ship it
quickly because a crude measurement - grep over function names - said twenty
tables were offenders, and a guard with twenty exemptions is not a guard.

An AST pass over every Get-*Blocks in Parts found twenty-five functions: twelve
bounded by a named mechanism (Select-RichTableRows, Get-BridgePageWindow, a page
size, Select-Object -First), twelve whose rows are a fixed list - the health
checks, the runtime files, the layers on air, the days of a report window, the
operators on the whitelist - and exactly one growing without a bound. The
distance between twenty and one is the distance between grep and a parser, and a
guard built on the estimate would have been born with an exemption list that
emptied it.

The one offender was Get-TemplateHistoryBlocks, which searches the audit trail
for a template, so its length is the station's history rather than anything the
screen controls: a template used through a busy month returns a table that
crosses the payload limit and loses its rows to the text fallback entirely. It is
now trimmed, and says how many rows it hid, because a table quietly missing its
oldest rows reads as the whole story.

The guard lives beside the button-paging guard: any Get-*Blocks that builds from
a collection in a loop must be bounded by a named mechanism or listed in
FixedRowScreens with a written reason, and a second test rejects an exemption
naming a function that no longer exists. It caught a case while being built -
Get-NewsTickerReorderBlocks is paged, but by hand through Get-NewsTickerPageSize,
with the same arithmetic written twice in the file. Bounded, but not through the
shared helper; its mechanism is named explicitly rather than waved through by a
loose pattern, so that duplication stays visible. Negative-checked by removing
the new trim and watching the guard go red.

## Version 8.16.0

Inspecting the plans, and what the inspection found.

bridge.log had been carrying this line since the day before, and nobody had
looked - me first among them: the rich payload for the full guide measured 21861
characters, 182% of the limit. AGENTS.md says of exactly that line, "watch it
after every addition"; I added to the help in 8.11 and 8.12 and did not.

Measured today: 115% for an operator, 182% for an administrator. So
Send-TelegramRichMessage refused the message every single time and the reader
always fell through to the paged text - the collapsible chapters this screen
exists for had never once rendered for anyone. Not a loud failure: the fallback
works and the manual arrives. The feature was simply dead, quietly. My additions
made it worse rather than causing it; it was over the limit before them.

The guide is now capped by measurement - chapters go in until the next will not
fit, then a line names the rest, because a manual that stops silently is worse
than one that says where it continues - and the measurement is linear rather
than quadratic, the first version having re-serialised the whole growing list per
chapter and slowed the gate by over a minute.

An existing test failed against this: it compared the administrator's block count
with the operator's, and the cap trims from the end for both, so the counts can
now match. The assertion moved to the property that actually matters - no
administrator chapter title in an operator's copy, nor in the line naming what
was left out.

The plan itself described a system nine releases old: its header said 8.6.0, and
its third open item asked for time-based log search in the manager, which arrived
in 8.7. Its first item had been waiting on a full day of running before measuring
the notification numbers; three weeks of log (17 August - 9 September) answer it:
one payload warning in the entire period, for one screen, so every other screen
stayed under 70% against real station data and the 12000 limit is not tight. The
held-notice figure remains unmeasured - quiet hours are disabled here and the
period holds zero holds - and the plan now says so with the numbers.

## Version 8.15.0

The rest of the audit findings, and a regression this work caused.

Moving the one-hand split to send time in 8.9.0 was right - it made the setting
reach every screen instead of one. It also reached the screens whose rows carry
position: the schedule calendar went from nine rows to forty-six, the hour picker
from six to twenty-seven, the minute picker and the small-range setting grid
likewise. The code's own comment says the row a date sits on is how the eye finds
it. No test caught it because the test written at the time measured the main menu
and action screens, not grids. Those five screens now declare KeepRows, which the
single serialisation layer honours and strips before sending, and a test measures
all four pickers.

The deferred postbox write was addressed to a layer, and a layer can be replaced
inside PostShowDelayMs - so the values of the graphic that had just left were
written into the one that replaced it. The queue entry now carries the key and
ActiveId it was made for and is dropped if the layer holds anything else; a hide
or exit cancels it by the same test rather than by separate machinery.

The black-output check slept on the control loop between its two captures,
holding auto-hide timers, the schedule, pending expiry and the heartbeat while a
fade passed. The second look is now booked for a moment and taken by whichever
tick arrives after it. The capture itself stays synchronous: that was a
documented, deliberate trade in the code, and reversing it is a restructure
rather than a line.

Smaller: a failed pre-show clear is logged always rather than only under a debug
setting - it is the condition that leaves the previous headline on air; finished
announcements are capped at fifty behind the live ones; and the test context now
blocks media process launches as it has long blocked the network.

A regression sweep over this session's own changes found the state writers
round-tripping with their backups, the deleted settings read by nothing, and the
bulletin still being stopped on an allowed hide - the half that a refusal-only
guard would not have noticed, since deleting the effect entirely would satisfy
it. Two tests now hold both halves.

Not done, with the reason: the rich-table guard. Six of twenty-six Get-*Blocks
functions call Select-RichTableRows, so the guard needs those twenty-six
classified first or it ships with an exemption list that empties it.

## Version 8.14.0

The fourth tier of the audit plan: maintenance rather than a visible fault, each
item checked against the code before being acted on.

AGENTS.md requires a state file to be written through a unique temp file, a
validated backup and an atomic replace, which is what Write-BridgeValidatedJson
does. Seven sites wrote with a raw Set-Content and a Move-Item instead:
announcements, the usage counter, favourites, user aliases, recent field values,
show drafts and mojaz playback state. None of them kept a backup, so a corrupt
file meant losing favourites, names or drafts outright - and the temp file name
was fixed rather than unique, so two concurrent saves of the same file raced for
it. All seven now go through the shared writer. (The report counted five and did
not mention the fixed temp name.)

In the manager, six of seven timers were never disposed - they are created with
new rather than in the form's components container, so nothing released them.
Process.Start for the logs folder returns a handle-owning object even when
unused, on every press, and is now scoped with using. Adopting a bridge that had
already exited returned without disposing the handle just opened, which is the
common case when a bridge dies between its heartbeat and the read.
StopForSettingsSave blocks the UI thread for up to ten seconds in WaitForExit; it
cannot become async without restructuring the save, but a window that stops
repainting with no cursor and no message reads as a hang - and the operator's
next move is to kill it mid-save - so it now sets a header and a wait cursor,
restored in a finally.

Deliberately deferred: the per-second synchronous reads of bridge.liveness and
bridge.log on the UI thread. The observation is correct, but the fix is a
restructure into async IO with the re-entrancy that follows, which is more risk
than it is worth while the logs are local rather than on a network share.

## Version 8.13.0

A refused request must not change the air.

This release came from external audit reports; every finding was checked against
the code before being acted on.

Three sites, one fault: an effect that touches the air ran before the gate that
decides whether it may, because the effect sat at the top of the function as
housekeeping rather than as an action. Clear-MojazForUrgent ran the moment the
template was resolved - six lines before Test-TemplateAccess and
Test-TemplateShowPolicy - so an operator allowed on the bot but not on the urgent
template pulled the bulletin off air and was then refused. Invoke-HideLayer and
Invoke-ExitLayer stopped the bulletin before the maintenance gate, so a blocked
hide sent nothing to Cinegy while the bulletin was marked finished and the ticker
recalled, the scene possibly still walking rows on air. All three now run below
their gates, and a guard describe plus two maintenance-gate tests fail if the
order returns - verified by restoring the old order first.

relay.pid was written without protection although ffmpeg is already running by
that line, so a failed write read as "the relay did not start" while the stream
was live and untracked. It now reports running and logs that the id could not be
saved. The repository's own guard rejected the first wording: a test forbids raw
exception text on a path holding a credential, and this file handles RTMP keys,
so the message goes through Protect-SensitiveText.

Save-Config wrote its re-read failure with Write-Host - nothing in bridge.log -
then overwrote the file with the in-memory copy, losing any hand edit silently.
The quiet-hours queue, added in 8.9.0 without a ceiling, is capped at 200 with
the oldest shed first and the count reported in the digest. The "quiet runtime
orchestration" test mocked twelve of twenty-seven tick steps, leaving the output
monitor to run ffmpeg against the example config's placeholder URL; it now mocks
the tick's own list. And the six switches in the manager's options menu are
hosted outside any Control.Controls tree, so Theme.Apply never reached them and
the menu reopened light on a dark ground - one of those switches being the theme.

## Version 8.12.0

Checking the manual against the code rather than against itself.

8.11.0 read the manual for contradiction and omission. This one took every
countable claim in it and compared that claim with the implementation, which
turned up two faults only counting finds.

The settings chapter said "the eight doors" and listed eight.
`$script:SettingCategoryDefinitions` holds nine. The one missing - right after
"files and retention" - was the notifications door, whose contents this same
manual had been extended to explain one release earlier. An administrator
looking for quiet hours in the settings screen was reading a list of eight that
did not include the door they were in.

The protected-settings list is introduced with "they are:", a claim to be
complete, and named five. `$script:ProtectedSettings` holds seven: those five
plus BlockRejectedRequesters and LeaveUnknownGroups.

And in the output-monitor section, one line reported the capture interval from
the setting while a line four below told the reader to set it to zero to turn
monitoring off - so anyone following that advice then read "a capture every 0
minutes". It now says monitoring is off when it is.

Two tests were added that compare the chapter's text against the category table
and against ProtectedSettings, so the count cannot go stale by hand again. Both
were checked by reintroducing the faults before being kept.

Verified correct and left alone: the operation-log windows (24/48/72/168 hours),
the notice rate limit (thirty seconds, "half a minute"), that
OutputMonitorMinutes = 0 really does stop the loop, that export emits the
Settings block only - no token, no user lists - that deleting a bulletin cancels
its appointments and is refused while it is on air, that an empty sheet is
rejected rather than clearing the ticker, and that the promised commands exist.

## Version 8.11.0

A review of the manual: what it says, and what it had never said.

The settings chapter contradicted itself within one screen. It opens with "most
values are set by pressing, not typing - numbers have minus and plus", and a few
lines later said a numeric setting "asks for the value in writing". The second
was left over from before the pickers landed, and the repository's own rule is
that numbers are never typed. That line now describes what actually happens.

Three features were missing from the manual entirely - searching it for "quiet
hours", "one-hand" and "your draft" returned nothing at all. Quiet hours were
absent from the notifications chapter, which is their chapter: what is held
overnight, what is urgent enough to arrive anyway, and that held notices now
survive a restart. One-hand mode was undocumented despite being a visible
setting, and is now described as covering every screen rather than the menu
alone. And the draft that comes back after a restart is now noted beside the
input-timeout warning, so nobody's next message becomes a headline unknowingly.
The unconfirmed hide from 8.10.0 was added to the shutdown chapter.

One orthographic outlier was corrected. Chapters were measured after the
additions: the largest is 2472 characters against Telegram's 4096, and the
full one-screen guide still goes out through Send-TelegramPagedText.

## Version 8.10.0

Three moments where the interface said something other than what had happened.

Hiding a layer used to report success unconditionally. Cinegy accepts the HIDE,
but the read-back that follows can fail, and the record is deliberately kept
when it does - losing track of a graphic that may still be on screen is the
worse mistake, and an existing test guards it. That left the operator holding
two answers at once: a green "hidden" over a keyboard still offering "hide layer
7", which reads as a bug rather than as an unconfirmed state. The message now
follows the state: the command was accepted, the removal is not confirmed yet,
and the layer stays listed until it is.

A refusal used to arrive with the whole main menu under it. Seventeen rows below
"this is for administrators only" push the sentence itself off a phone screen,
and none of the seventeen is what the reader wanted - they wanted the thing they
were refused. The four refusal guards and the input-timeout notice now carry a
single way back.

In the manager, every button opens with a glyph, and a screen reader announces
the glyph's own name before the words, so the operator hears "gear" and then
waits to learn what the button is. The spoken name is now derived in the
BaseButton factory rather than at each call site, so it covers both windows and
any button added later; an explicit AccessibleName still wins.

Found by driving the journeys rather than reading them, and each of the three is
covered by a test.

## Version 8.9.0

A review that went looking for switches nothing reads and limits nothing applies.

One-hand mode turned out to reshape a single screen. `ConvertTo-OneHandLayout`
documents itself as "applied as a final pass over a finished keyboard so no
individual screen has to know about it", and had exactly one call site: the main
menu. An operator who switched it on got a single column there and three-across
rows on the fifty-odd screens behind it. The pass now runs inside
`ConvertTo-TelegramReplyMarkupJson` - the one place a keyboard becomes wire JSON,
and where `EnableButtonStyles` was already read - so it covers every keyboard the
bridge sends. The persistent home/help bar carries `keyboard` rather than
`inline_keyboard` and is left alone.

Four numeric ranges were written against names no setting had: `MaxNewsItems` for
`NewsMaxItems`, `AuditMaxLines` for `AuditMaxSizeMB`, `AutoHideMaxSeconds` for
`AutoHideDefaultSeconds`, and `TelegramPollTimeoutSeconds` for
`PollTimeoutSeconds`. The guard in `Set-Setting` is correct but keyed by name, so
it never fired - the screen printed a range under a field that would have taken
two billion. Three are renamed; `AuditMaxSizeMB` takes a floor of zero rather
than a hundred because zero means "never archive" there, and a ceiling in
megabytes rather than the line count an earlier version of the setting counted in.
`PollTimeoutSeconds` is a top-level key that never passes through `Set-Setting`,
so it is clamped where it is read: Telegram refuses a long-poll timeout above 50
and errors on every poll, which reads in the log as the bot being down. A test
now rejects any constraint whose name is not a real setting.

A restored draft now says so. `Import-DraftStates` brings an open show flow back
after a restart and wrote one line to `bridge.log` about it; the operator never
saw the restart, so the next message they sent about something else became the
text of a breaking-news banner. Quiet-hours notices survive a restart too - they
lived in memory alone, so a 03:00 restart dropped everything being held, with no
trace beyond a log line written hours before.

The Mojaz "hold follows the clip" option is gone, along with the chain behind it.
The setting was on the settings screen with a description and was read by no line
of code; the `MediaSeconds` field driving it was read by the planner and written
nowhere in production - only by the tests, by hand - so the branch was green in
Pester and dead on the machine; and `Get-FfprobePath` had no caller at all.
Durations are typed, as they always were in practice.

## Version 8.8.0

One timed-out grab is not a dead source.

At 16:09 a single output-monitor capture exceeded its eight-second timeout while
the machine was busy building and publishing the manager - the source was up the
whole time - and the bridge switched the channel to its Cinegy standby and said
so. Three faults met there. A configured standby switched on the first failure
by design ("do not leave a dead primary for another interval"), so there is now
a second attempt a second and a half later before any failure is counted: eight
seconds against an hour on the wrong source. The next check was an hour away
(`OutputMonitorMinutes = 60`), which is exactly why no recovery notice arrived -
it had not run yet - so a failover now schedules a re-check within minutes and
the message says so. And worst, "the primary is back" was announced without
testing it: the successful grab comes from whichever source is active, which
while failed over is the standby. `Test-PrimaryMonitorSourceBack` asks the
primary directly and restores the state whatever the answer.

In the manager, every button on the action row now shares one width - there were
seven between 118 and 140, and the eye groups by shape before it reads a word -
and the options menu is a straight column with a shared minimum width, so the
ticks line up instead of making a ragged edge to scan.

## Version 8.7.0

The manager's controls say what they are before they are read.

Every button and switch carries a glyph - ▶ start, ■ stop, ↻ restart, ⚙
settings, 📂 logs, 🧹 clear, ☰ options - and keeps its word beside it, because
an icon alone is a guess and these are pressed under pressure. The options menu
follows the theme now (`RenderMode.System` with colours reapplied on each open):
the default renderer paints a light chrome that survives the dark palette, and
the theme can be switched from inside that very menu. Its two groups are named
for what they govern - "🔴 ما يحدث للقناة" and "🖥 هذه النافذة" - rather than
"operation" and "view", which needed explaining.

The tray menu carries the same glyphs, since it is what an operator sees while
the window is hidden, which is most of the time, and a menu that looks nothing
like the buttons it mirrors is a second thing to learn. And the filter box
admits it can search a time: every line opens with its stamp, so "07:2" filters
a twenty-minute window exactly as a word filters a word - it always worked and
nothing said so.

## Version 8.6.0

The manager's window goes back to what it is for: the log.

Fourteen controls stood between the top of the window and the first line of the
thing it exists to show. The six switches moved behind an `⚙️ خيارات` button,
giving a whole row back to what is actually read - they are set once and left
alone for months, two of them about line wrapping and dark mode, so a click each
is the right price. They are the same controls hosted inside the menu rather
than copies of them, so every read of their state elsewhere still works and what
they persist is unchanged.

One primary action at a time: "تشغيل" when it is stopped, "إيقاف" when it is
running, rather than three buttons of equal weight with two of them dead -
during an incident the button that can be pressed is the one that is there. And
a line above the log says what is happening without reading it: the last
operation that reached air with its time, and the number of errors in the last
hour, coloured when there are any. The log is a stream that scrolls past; this
is the summary you glance at.

The manager's version follows the bridge automatically - `Build-BridgeManager.ps1`
reads 8.5.0 and stamps **v8**. It needed no change, only a build made after the
bridge reached eight. Build clean, 121 self-test checks passing, three of them
new for reading an operation line.

## Version 8.5.0

The manual catches up with what the bridge learned to do, and the manager's
switches say which of them govern the air.

A new chapter, `🔔 التنبيهات`, covers what a notice carries (the copy, the
layer, the duration, who ran it), that it never reaches the person who ran it,
the per-person mute and the `تنبيهاتي` command that undoes it, the holding while
somebody is typing, and the one warning that arrives immediately regardless: the
template you are preparing has just gone on or off air. `🔍 المتابعة` gains the
operations log with its four windows and its day-by-day walk; `✏️ التعديل`
explains that editing starts from the current text and that a flow warns a
minute before it expires with a button to extend it; `⚙️ الإعدادات` describes
values set by tapping rather than typing; and `🚪 من يدخل البوت` covers the
two-tap approval, the announcement to every administrator, and the history of
past requests.

In the manager, the six switches became two named groups - "التشغيل" and
"العرض". Three of them decide what happens to the channel when nobody is
watching; three decide what a window looks like. Side by side in identical
style they read as equals, and the row an operator scans during an incident was
half filled with preferences about line wrapping. Build clean, 118 self-test
checks passing.

## Version 8.4.0

The notice waits its turn, and a collision over a template is told to the person
it affects.

An editor entering the third headline of a ticker does not lose their place to
an incoming message - the flow is state on the server, not the last thing in the
chat - but the prompt they were reading scrolls away, and on a phone that is the
same thing. Someone entering a bulletin row, a banner's copy or an urgent
headline is doing the very work the notice is about, and interrupting them to
describe it is the worst moment there is. A notice for anyone mid-flow is now
held and delivered as one message the moment the flow ends ("📣 حدث أثناء
انشغالك (3)") - held rather than dropped, capped at five so a long flow in a
busy hour does not end in a wall, and flushed from `Clear-PendingState`, the one
point every ending passes through.

The layer lock has long stopped two people starting a flow on the same layer,
but nothing stopped a schedule, a preset or an operator on another layer from
publishing the very template somebody was typing into - and the first they knew
was their text failing to appear, or worse, replacing what was already right.
Anyone preparing that template or that layer is now warned the moment it changes
("⚠️ Urgent عُرض على الهواء بواسطة … أثناء تجهيزك — راجع ما أعددته قبل
الإرسال"), and that warning ignores their mute: a mute means "do not tell me
what the channel is doing", not "do not tell me my work has been overtaken".

## Version 8.3.0

Coming off air is news too, and three things the notification path was missing.

A take-down is announced by the same rule that announces a push - one rule per
template covering both, rather than two settings that drift apart - and it
carries how long the graphic was up. That is the question a take-down raises: a
strap that ran four minutes was read, one that ran four seconds was a mistake
somebody has already corrected. It is sent even for a quiet hide, because an
auto-hide timer taking a strap down is exactly the change nobody in the gallery
watched happen.

Three improvements found while adding it. A burst of pushes was a burst of
messages: an operator correcting a headline pushes the same template three times
in twenty seconds, the room sees one change, and three identical interruptions
is how a notification becomes something people switch off - so a notice repeats
at most once every thirty seconds per template, layer and action, the window
kept short because the same graphic returning minutes later is news again.
There was no way out for someone who did not want it: the audience was a
collective decision with no individual answer, so every notice now carries a
`🔕` button whose choice is kept in that person's profile and survives a
restart - a bot with no way out is a bot muted at the operating-system level,
and then the alert that mattered is lost too. And for anyone who muted and then
closed the message, `تنبيهاتي` says where they stand and offers the opposite
button.

## Version 8.2.0

The settings stopped asking to be typed. An audit of all 174 of them, then five
fixes.

What the audit found: 58 booleans with toggle buttons (fine), 7 choice lists, 4
pickers - and **90 integers, every one of them typed**, plus 14 free-text
settings of which half needed no text at all.

Numbers are now set on one screen: `➖ step`, the value, `➕ step`, then the
default, the floor and the ceiling, with a `⌨️` button for anyone who knows the
exact number. The step comes from the size of the number rather than a table - a
timeout in seconds moves by one, a retention of 5000 lines does not need fifty
taps to reach 5500 - and pressing plus at the ceiling clamps rather than
refusing, because that press means "as high as it goes".

The schema has carried `Minimum` and `Maximum` since it was written and not one
setting declared them: `CinegyStateCheckSeconds = 0` was accepted, a bridge
asking the engine for its state without pause, and so was a negative timeout.
Twenty settings declare their range now - the ones whose wrong value is felt on
air or on the engine - and the guard sits in `Set-Setting`, because an import, a
restore and two screens all arrive through it.

A range small enough to show whole is shown whole: an hour of the day is 24
answers and a weekday is 7, so both are a grid with the current value marked and
the day named rather than numbered. The maintenance window is picked from a
clock in two taps - it was free text, where "8:00", "٨:٠٠", "20.00" and an empty
string all looked like an answer while the window silently did nothing - with a
button for no window at all, which is a real answer that had none.

`DisabledTemplateKeys`, `SensitiveTemplateKeys` and `ReservedLayers` were typed
while the picker they needed already served four settings just like them; a
misspelled key in a permission list reads as "not in the list", so the
permission quietly protects nothing and nobody finds out until someone uses what
they should not have. `AutoHidePresetSeconds` is a duration picker now, and
`NewsItemSeparator` a choice of five - a space typed after the separator used to
become part of it, giving every headline on the strip a gap invisible in the
setting.

## Version 8.1.0

The notification rule is chosen by tapping rather than typed.

"Urgent=all, Banner=admins" is a syntax to remember, a template name to spell
exactly, and a scope word in a language the screen does not otherwise use -
three ways to be silently wrong about a setting whose whole purpose is that
somebody hears. It is a screen now: one row per template showing what it will do
when it goes on air, and tapping cycles it through 🔕 nobody, 👮 administrators,
📢 everyone. Nothing to spell, no syntax, and every answer visible at once.

Paged like the other pickers and addressed by position, since a callback carries
64 bytes and a template name does not always fit in what is left; redrawn in
place on each tap so the list does not grow a copy of itself down the chat. A
rule meaning silence is not stored, because silence is the default, and a rule
for a template the registry no longer has is kept - one renamed in the morning
and restored in the afternoon should not lose the newsroom's decision in
between. The setting itself is unchanged: the screen writes the same string that
lives in config.json and in every backup, rather than introducing a second store
to keep in step with it.

## Version 8.0.0

A template can announce itself on air, and nothing expires unannounced.

`TemplateNotifyRules` is one setting an administrator writes from a phone -
"Urgent=all, Banner=admins" - and urgent is the example rather than the rule:
"عاجل" on one station is "Breaking" on another, and which graphics are worth
interrupting a room for is a newsroom's decision, not something a program can
infer. Each template names its own audience (`none`, `admins`, `all`), and a
name written without one means all, because someone who bothered to list a
template wants somebody told.

The message carries what people actually ask: the copy that will be read on
television in a `<code>` span, the layer, how long it stays ("hidden
automatically after 30 seconds" or "stays until someone takes it off"), and who
put it there. It never goes to the person who ran it - they are looking at their
own confirmation, and a second message describing what they just did is the
noise that gets a bot muted. Nothing is sent for a template nobody named: a
station shows dozens of graphics a day.

The extend button covers every input flow - bulletin, ticker, banner, schedule,
templates - because the flow watchdog is indifferent to which mode it is
watching. The ticker draft was outside it: a separate expiry that discards the
whole strap rather than one half-typed field, with the editor learning of it
only from the message counting what they had lost. It now warns five minutes
before, with the number of headlines at stake and a `⏳ تمديد` button that
restarts the clock. The expiry itself stays, because an abandoned draft holds
the ticker - but it is a decision now rather than a surprise.

## Version 7.99.0

The log states the period it covers, can be read a day at a time, and access
requests now have a history.

`📜 السجل` wrote `HH:mm:ss` and nothing else, while restoring fifty entries from
audit.jsonl that on a quiet week reach back several days - so "07:22" meant one
of four mornings with no way to tell which. Today keeps the bare time, anything
older carries its date, and two lines above the entries give the period actually
shown and how many of the stored lines that is: the screen shows a fixed number
of lines rather than a window of time, so how far back it reaches depends
entirely on how busy the station has been.

"What went out on Tuesday" is not a question a window ending now can answer - by
Thursday, Tuesday has fallen out of every readable window. The operations log
now offers `📆 يوم أمس` and walks from there with `◀` and `▶`, with no arrow
past today, because a button whose answer is "no operations" by design teaches
people to distrust the screen. Days are named the way people say them ("أمس ·
2026-09-07"), and the screen is now reachable from `📜 السجل` and `📊 التقارير`
as well as from the operations screen, since that is where supervisors look.

Access decisions were recorded only as an Arabic sentence inside one audit
message, with the structured fields left empty - no screen could be built on
that without parsing prose. Requests, approvals and rejections are now written
as data, and `📜 الطلبات السابقة` on the pending screen shows who asked, the
state, when it was decided, by whom, and how long the person waited. It is built
from the audit file and the user roster together, because neither is complete
alone: rejections leave no other trace, and approvals older than this release
exist only in the roster - which the screen says out loud rather than being read
as the whole story.

## Version 7.98.0

The cause of the silent administrator was the promotion itself.

`Set-AdminRole` added to `AdminUserIds` and left `AdminChatIds` exactly as it
found it, so everyone promoted from inside the bot became an administrator with
no notifications: able to approve a stranger into the on-air controls, never
sent a request. It was not a misconfiguration but the promotion path. It fills
both lists now - one is who may decide, the other is who is told there is
something to decide, and freezing the second makes the first blind.

The original caution stands: a group chat's id is negative, so no promotion can
turn one into an audience for administrator notices; what gets added is always a
private chat id, which is the user's own id.

A one-time repair runs at startup (`Repair-AdminChatIds`), because anyone
promoted by an older build stays where they are however the path is fixed - and
cannot discover it, since what they are missing is messages that were never
sent. It only ever adds, and it names in the log whoever it added rather than
changing a configuration file in silence.

## Version 7.97.0

Two incidents from the air: an access request that never reached one of its
administrators, and an editor cut off mid-sentence.

`AdminUserIds` held three administrators and `AdminChatIds` two. Nothing checked
that the two lists agreed, so the third could approve a stranger into the on-air
controls and was never told one had asked - nor of a Cinegy alert, nor of the
weekly digest. The request reached two of the three, one approved it inside a
minute, and the third heard about it from a colleague. `Send-AdminBroadcast` now
messages both lists (a private chat's id is the user's own id), the black-output
alert and the sheet notice use the same audience, and the health screen names
anyone who is in one list and not the other - the fault is silent by nature,
since the person missing cannot notice a message that never arrives.

Every consequential action here confirms - hiding a layer, restarting, clearing
a log - except the one that hands a stranger the on-air controls. An
administrator reported an approval he had no memory of making, which is exactly
what a stray tap on a message sitting in a chat produces. Approval now takes two
taps: the first asks, naming the requester, and the second is a red button
reading "نعم، امنح الوصول" rather than a bare yes. Every approval is then
announced to all administrators, because a grant of on-air control should not be
visible only to whoever made it.

And an editor writing a headline was cut off with "the time ran out, start
again" - the first he knew of any clock. He was not abandoning the flow; he was
being interrupted by the rest of his job. A flow now warns a minute before it
ends and offers an extend button that restarts the clock; expiry itself is still
right, because an abandoned flow swallows the next message its owner sends, but
it no longer arrives as a surprise. The shipped default rises from five minutes
to ten - five is shorter than writing a headline while the phone rings - and an
installation that set its own value keeps it.

## Version 7.96.0

And a full week, because that is the span a newsroom reviews.

`🗓 7 أيام` joins 24, 48 and 72 hours: "did that banner run on Tuesday" is a
weekly question, not a three-day one. It costs nothing the other windows do not
already pay - the table caps at forty rows however wide the window, and
`Get-ReportRecords` reads the same bounded number of lines for a week as it does
for the month reports, saying so out loud when it reaches that limit. It is
named as days rather than 168 hours, which is a true number and a useless label,
and the window buttons now sit two to a row like the report periods: four across
one row of a phone leaves every label too narrow to read.

## Version 7.95.0

The operations log now reaches back 72 hours, and reads the file rather than
memory.

`🧾 آخر عملياتك` showed the last ten operations and nothing older, from memory:
twenty entries per person, forgotten at a restart. A supervisor asking what went
out last night was handed this morning's list. The new screen reads audit.jsonl
through the same report machinery - the permanent record, which survives a
restart and reaches into the rotated archives, which is what a 72-hour window
needs.

Three windows: 24, 48 and 72 hours. Two days is the shift-handover question and
three covers a weekend, which is clearer than one vague "recent"; the window
being read is marked on its own button. The table gives the time as day and
hour (over three days "21:40" alone is ambiguous), the operation, the template
and layer, and the outcome - with a verdict above it, so failures are not
counted by reading forty rows. Administrators get a `👥 كل المشغّلين` button,
and the guard for it sits in the command rather than only on the button, since
a callback can arrive without one being pressed. Capped at forty rows like every
other table, and it says both what it trimmed and whether the log hit its read
limit.

Caught by its own tests before anyone saw it: `foreach ($hours in ...)` inside a
function whose parameter is `-Hours`. PowerShell variable names are
case-insensitive, so the loop was overwriting the parameter - every window came
out marked as the current one, and the scope button carried whichever window the
loop ended on.

## Version 7.94.0

A stability audit: three screens that would have repeated the 7.87 outage, one
latent crash, and five dead functions.

Three rich tables had no row cap. Measured on the real serialiser against the
12000-character limit: 40 rows is 4088 characters (34%), 250 rows is 24399
(203%), and 700 rows is 68049 - **567% of the limit**, worse than the banner
report that cost every screen its tables in 7.87. That report was capped then;
these three were not. The bulletin report grows a row per run, so a station
running one every hour makes about seven hundred rows in a month; the bulletin
library grows a row per saved bulletin and nothing prunes it; and the publish
review shows every removed headline and every added one, two rows per item, so
replacing a forty-item ticker is eighty rows. The cap now lives in one place
(`Select-RichTableRows`), because a cap written four times is a cap that gets
raised in three of them, and every trimmed table says what it left out rather
than being read as the whole story.

`Get-MojazRunDuration` read `$Run.DurationMs` directly. A run record carries
only the fields the version that wrote it knew, and the store outlives the
version - under StrictMode a missing field is not a zero but a crash, on the
reports screen, for every run in the window. It goes through `Get-JsonProp` now.
Found by a test built from realistic records rather than complete ones.

Also removed: five functions with no caller anywhere in the repository and no
test - 124 lines. What the audit found healthy: not one empty `catch {}` in the
codebase, a polling loop guarded per update and per handler, and the per-user
operation history capped at twenty.

## Version 7.93.1

"Once per screen" meant once per number.

The size warning added in 7.93.0 was keyed on the screen's heading as written,
and eight headings carry a count or a period inside them - "الأحداث القادمة
(12)", "تقرير الموجزات - هذا الأسبوع". So the warning repeated whenever the
number changed, and the table of already-warned screens gained a key for every
distinct count, for as long as the bridge ran. The key is now the heading with
its digits removed. Found by a stability audit an hour after it shipped.

## Version 7.93.0

Every screen now measures its own payload, so the limit is not discovered by an
operator whose table has vanished.

The 7.87 outage was found only after a report had already stopped rendering for
a whole session. Nothing watched the size until it was too large, and a screen
crosses the limit gradually as a station's day fills up. Now every rich payload
is measured as it is serialised, a warning is logged once per screen at 70% of
the limit - while it still works, and while there is still time to cap a table -
and the operating-numbers screen carries a line naming the biggest screen sent
this run and its percentage of the limit.

Found while reviewing: `editMessageText` built a rich payload with no size check
at all, though `sendRichMessage` has had one since 7.87. An oversized edit is a
400 like any other, and a 400 narrows or disables a block type for the rest of
the session - and the reorder screen re-renders on every arrow press, so it
would have paid that price repeatedly. It has the same gate now, and its
failures carry the payload length so no block type is blamed for a size problem.

Also fixed: fifteen tests were making real requests to api.telegram.org and
waiting out a 401 each, roughly a second apiece on every run of the gate. Since
screens began trying `sendRichMessage` before their text, any test that drove a
real screen while mocking only `Send-TelegramMessage` had its rich attempt
escape the mocks - and the answer was never useful anyway, the token in
config.example.json being a placeholder. The mock now sits at the real boundary,
`Invoke-RestMethod` inside the `BridgeTelegram` module, rather than at the
wrapper: everything above it still runs and is still measured, including the
retry and the timeout, whose own tests mock that same command and whose mock
wins over this one.

## Version 7.92.1

The button itself cannot change after the press, so it changes before it.

Asked whether the copy button's label or colour could flip to show the copy had
happened: checked against the Bot API changelog through 10.3 (24 August 2026,
the newest), it cannot. Pressing a `copy_text` button sends the bot no update at
all, so nothing arrives that an edit could be built on, and no field makes a
button restyle itself once pressed. A button's label and colour are chosen when
the message is sent or not at all.

So the colour is spent on what the button *is* rather than what it did. Blue is
this bridge's colour for the action a screen offers, and the copy button was the
last one on these screens wearing none - which left the one button that behaves
unlike every other looking exactly like them. Older clients ignore `style` (Bot
API 9.4) and `EnableButtonStyles` strips it from the wire when it is off, so the
label still carries the meaning on its own.

Corrected: `copy_text` is Bot API 7.11 (31 October 2024), not 8.0 as the 7.91.0
and 7.92.0 notes said.

## Version 7.92.0

A copy button now says what it will do, because nothing can say it afterwards.

The request was to confirm that the text had been copied. The bridge cannot: a
`copy_text` button (Bot API 7.11) is carried out by Telegram on the device and
sends no callback, so the bot never learns the button was pressed and has
nothing to answer with. Telegram's own client shows a brief confirmation of its
own.

So the notice is written before the press instead of waited for after it. One
line names the button exactly as it is labelled and says where the copied text
is meant to go - which makes Telegram's confirmation expected rather than a
surprise, and turns a button that looked inert into an understood action. Both
screens that carry a copy button have it: the text editor ("paste it in the
message box and edit it") and the operation history ("send it to an
administrator with what happened"), and the wording lives in one function so no
two screens promise it differently. Whether the operations screen carries the
button at all is now decided by a single function that both its body and its
keyboard ask, since the two are built in different files and would otherwise
drift into a screen promising a button it does not show.

## Version 7.91.0

Editing text starts from the text, and what will appear on screen is marked as
such.

The ticker's edit screen said "أرسل النص البديل للخبر:" and showed nothing at
all, so an editor correcting one word was retyping the whole headline from
memory or from a screen further back. No bot can fill a person's input box —
Telegram does not offer it — so the nearest thing is one tap to the clipboard,
and it is given twice: the current text sits in a `<code>` span, which Telegram
makes tap-to-copy, and a `📋` button using Bot API 7.11's `copy_text` copies it
outright for anyone who does not know that. It is the one button in the bridge
with no `callback_data`, because the copy happens on the device and the bridge
never hears the press.

The text is shown whole however long it is: a truncated "current" is worse than
none, because an editor who copies it loses the tail without being told — the
mistake the screen exists to prevent. The bulletin row edit gets the same
treatment; it had been showing its current text as prose on the end of a line,
readable but not copyable on a phone without a careful long press.

The pre-send review — the screen where an operator decides whether to put a
graphic on air — showed the copy with nothing distinguishing it from the field
labels describing it. Telegram gives a bot no text colour, and a monospace span
is the strongest distinction it does have, so one rule now runs through that
screen: everything that will appear on television is a `<code>` span and nothing
else is. A field left empty says "(متروك)" in italics rather than sitting in a
span that implies it will be shown.

## Version 7.90.0

Elapsed time reads in months and weeks, not minutes for ever.

The user-activity screen said "منذ 4320 د" — a number the reader divides twice
before it means anything, on the very screen where an administrator decides
whether someone still needs access. It goes through `Format-DurationMinutes`
now, and that formatter names months and weeks as well as days: a fortnight read
as "14 يومًا", which is not what a person says.

A month here is thirty days and a week is seven, and neither pretends to be
exact: this answers "how long ago", not a calendar, and an exact month would
make the same elapsed time read differently depending on which month it fell in.
It names the two largest units and stops — "شهر و12 يومًا و7 ساعات و20 دقيقة" is
precise and nobody says it, and someone deciding whether an account is dormant
does not care about the minutes.

The rest of the bridge was checked. Most mentions of minutes are settings an
administrator chose — "every 60 minutes", "remind after 30 minutes" — and are
right as they are. The unbounded elapsed cases were four: the user activity and
three in the banner report, where a banner up all evening read as "300 د".

The banner report's tests now load `Bridge.Core.ps1` so they measure what the
code actually prints; a stubbed formatter would have had its own idea of how
"300 minutes" reads.

## Version 7.89.0

The four remaining lists become tables.

The upcoming schedule shows template, time and recurrence. Its text version
keeps the `tg-time` entity that renders the moment in each reader's own zone; a
table cell cannot hold an entity, so the station's own time is written out —
which is the time a playout schedule is written in anyway.

Pending access requests show the id, the name and how long ago. Someone granting
the ability to put graphics on air is comparing those three across the requests,
which is a table rather than a paragraph each. The bulletin library shows rows,
revision and state — four facts the text has to run together on a second line
under every name. The template history shows when, who, what and how it ended.

An empty list says so instead of drawing a header over nothing, and a template
history with no search term returns no blocks at all, so the caller falls through
to the text that carries the instruction. A bare pending-approval record no
longer takes the screen down: these are written at more than one call site, and
a missing key under StrictMode would have broken the screen an administrator
opens to answer someone who is waiting.

## Version 7.88.1

`📊 ملخص الاستخدام` becomes two tables — and a correction to 7.88.0.

7.88.0 said "no screen is left without a table". That was not accurate. Screens
without a rich builder remain, and this was one of them. Most of the rest are
prompts, confirmations and single values, where a table is the wrong shape — but
several are lists that deserve one: the upcoming schedule, pending access
requests, the bulletin library, the settings backups, and a template's usage
history.

Two tables rather than one, because the screen answers two questions — which
templates carry the work, and how the shift's operations ended. A single table
would need a column meaning one thing in half its rows and something else in the
others. The ranking is `# · template · times · last used`, with a dash rather
than an empty cell for a template never used; the outcomes are successful,
failed and blocked; and a third table appears only when a cancel reason has been
recorded.

The scheduled weekly digest deliberately keeps its text. It goes out through
`Send-AdminBroadcast`, which holds a non-urgent notice for the quiet-hours
digest and stores only the text, so a table would arrive hours later as nothing
at all.

## Version 7.88.0

No screen is left without a table.

Three screens had no rich path at all — they were text however the text was
formatted, which is why they stayed unlike the rest no matter how the lines were
arranged.

The menu screen is the one an operator lands on most. What is on air is rows of
columns by nature — layer, template, how long, whose — four facts the text has
to run together across two lines each. The verdict becomes the message's
heading, because it is what must land before anything is read. There is no cap
here: the text version stops at four layers because each costs it two lines,
but a table is read down its columns and a cap would only hide a live graphic.

The operating numbers are a label-and-value list, which is a two-column table by
nature. The runtime-file health screen is the other half of a question whose
first half has had a table since 10.1, so the two looked like different
products; broken files come first, as they do in the health centre.

The rich-then-text decision for the menu now lives in one place
(`Show-MainMenuScreen`) rather than being made separately at three call sites.

## Version 7.87.1

One keyboard row was taking down the bulletin, news and banner reports.

Telegram said why itself, thanks to 7.86.2: `Bad Request: expected an Array of
InlineKeyboardButton`. Not an HTML problem at all — the reply markup. And
because the rich message and its text fallback carry the same markup, both paths
failed together, which is what made it look like a formatting fault.

The cause was one character of PowerShell. The "⬇️ download" row was written as
`$(if (...) { , @($button) })`, and the `$( )` unrolls the wrapper the comma had
just built, so the row arrived as a bare button object rather than an array of
one. `تقرير العمل` is the only kind with no download row, which is exactly why it
was the only report still working.

Rows are appended one at a time now rather than listed inside a single `@( )`,
so there is no place for the comma to be undone. A test sweeps every keyboard
the bridge can build without arguments and checks that each row is an array —
the fault is one character and can be written into any of them. That sweep
immediately caught a shape I had not accounted for: the persistent reply
keyboard carries `keyboard` rather than `inline_keyboard`, and asking for a
missing key under StrictMode throws rather than answering false.

## Version 7.87.0

One oversized report was costing every screen its tables until the next
restart. This is the reason the design "got worse", and it has nothing to do
with the recent text work.

The banner report is the default one, and as rich blocks it serialises to 44,937
characters for a month and 30,105 for a week. The largest payload ever seen
rendering on this installation is the news report at 4,095. Telegram refuses it
with a 400 — and because it can be the *first* rich message of a session, the
narrowing logic finds no block type "proven yet", blames all four, and disables
`heading`, `table`, `paragraph` and `details` for the rest of the session. Those
four are what build ℹ️ الحالة, 📊 الحالة الكاملة, 🩺 مركز الصحة, 🕘 ماذا فاتني and
every report, so all of them silently drop to their text fallback.

The log says both halves plainly: at 18:59:54 "every block type in it has
rendered before, so nothing was disabled" — a session where something small
rendered first — and at 19:11:39 "those block types are disabled for this
session" — a session that opened with the report. The fault is order-dependent.

A payload far larger than anything that renders here is no longer sent at all
(`Test-RichPayloadSize`, 12,000 characters): that screen alone falls back to
text and no block type is blamed. A 400 on an oversized payload never disables a
type — that is a size, not a missing capability — while the narrowing still does
what it was built for, disabling an unproven type refused at a normal size.

The banner report's table is capped at forty rows, taking it from 45 KB to
9,789, and says "the newest 40 of 300" rather than implying it is all of them.
The text version still carries every row.

## Version 7.86.2

A refusal says why now.

`Invoke-RestMethod` gives only the status line — "Response status code does not
indicate success: 400 (Bad Request)" and nothing else — which is what the log
held when the reports screen broke, and why finding the cause took rebuilding
the whole path against the live audit trail instead of reading one line.

The answer is in the response body, which PowerShell puts in
`ErrorDetails.Message`:

```
{"ok":false,"error_code":400,
 "description":"Bad Request: can't parse entities: Unclosed start tag at byte offset 91"}
```

That description is Telegram's own wording: it names the tag it choked on and
the byte offset. It is read and appended to the error on every failure now, 400
and 429 alike. A body that is not the JSON expected — a gateway's error page,
say — is taken raw and trimmed at 300 characters, so it cannot fill the log.

The 7.86.1 fix was verified by rebuilding the reports path and all four status
screens against the real 604 KB audit trail and inspecting every payload sent:
the banner report for a month (43,210 characters) degrades to valid plain text,
the other three reports and all four status screens send valid HTML, and not one
message is unbalanced or over the limit.

## Version 7.86.1

The reports section stopped working in 7.86.0. This is why, and the fix.

A page was being cut inside a blockquote. `Split-TelegramText` cuts at the
character limit and knows nothing about tags, so a cut inside a `<blockquote>`
left page one with it unclosed and page two with a `</blockquote>` opening
nothing — and Telegram answered 400 to both.

The banner report is the default one, and it runs to 43 KB over a month:
thirteen pages, every one refused. Measured against the real audit trail —
today 4,683 characters over 2 pages, a week 24,428 over 8, a month 43,210 over
13, all three unbalanced before and balanced after. The other three reports were
working because they come in under 4096 characters and are never split.

`Repair-TelegramHtmlChunks` closes what each page leaves open and reopens it at
the start of the next, outermost first so the nesting survives the cut. The
opening tag is remembered whole, so `<blockquote expandable>` comes back
expandable rather than as a plain quote. `code` and `pre` are never reopened:
they cannot contain other entities, so reopening one would swallow the rest of
the page as literal text.

If closing a page off pushes it past the limit, the markup comes out and the
text goes plain — the same degrade `Send-TelegramMessage` makes for the same
reason, rather than sending something that will be refused.

The fix is in the pager rather than in the report, because the help screens, the
release notes and the bulletin preview all take the same path and were exposed
to the same fault.

## Version 7.86.0

The remaining screens take the health centre's design.

The usage summary's tail was three sentences in three different shapes after a
carefully built ranking — a week's estimate, a run total and an outcome tally,
none of them resembling the others or the list above. The two figures the screen
is opened for lead now, with the outcome breakdown quoted under them.

All four reports follow: work, bulletins, news, banners. Totals first, the
per-row detail in a blockquote that folds itself past three rows. In the work
report the shift total had been *below* the people it summarises — on a busy day
the line an operator had to scroll past eleven others to reach.

Not one `━━━` divider is left in the repository. A blockquote separates for real,
and folds; a row of dashes was a picture of separating.

The reports go out as `parse_mode=HTML` now, with every field escaped through
`ConvertTo-HtmlText` — the escaper already living in the reports file, because
these screens are built almost entirely out of what people typed: operator
names, template and bulletin names, and the banner copy itself.

## Version 7.85.1

The fixed-width table made the text small, and that trade went the wrong way.

`<pre>` does align its columns, and Telegram draws it two sizes down. On a phone
that costs more legibility than the alignment buys, and the reports screens —
the ones that read well — never used one.

The rhythm comes from every line opening with the same two glyph slots instead,
state then identity: a column the eye follows without any character having been
counted, at full text size. The vocabulary is the reports screens' own — `·` as
a separator, `—` between a label and its value, the name in bold — so there is
nothing new for an operator to learn.

`Format-BridgeTextTable` is deleted. It has no caller left, and leaving a dead
function behind a day after an audit that counted the dead ones would contradict
the audit.

## Version 7.85.0

Real tables, and "why" written where it is asked.

`Format-BridgeTextTable` renders rows as an aligned `<pre>` block. Telegram HTML
has no table element and `<pre>` is the only fixed-width surface it offers:
inside one a padded column actually lines up, so a state column can be read
straight down instead of every line being parsed on its own. It is the same
shape the rich-message table gives where `sendRichMessage` is available, which
is exactly what these screens are the fallback for. Applied to the health
centre, the operating numbers and the usage summary. Each glyph column holds
exactly one emoji per row, so the widths match whatever an emoji turns out to
be, and the last column is never padded — trailing spaces buy nothing and cost
the wrap point on a narrow phone.

The log said "Cinegy health changed from healthy to unhealthy" and nothing else.
`unhealthy` never meant unreachable: Air answers, and its own telemetry crosses
a tolerance. Which tolerance, and by how much, was computed for the admin
broadcast alone and only once the alert threshold was reached — so the only way
to learn why was to read the metrics by hand after the moment had passed. The
reason is on the line now, and in the recent-errors row, which used to repeat
what its own colour already said.

Recovery is announced whenever the state was not healthy before, not only when a
warning had already gone out. The warning waits for consecutive failures, so a
dip that cleared just under the threshold left the screens saying "unhealthy"
for minutes and then went quiet, and an operator who looked in the middle of it
was never told it was over. The notice now carries what the warning carries: how
long, why, and the numbers it is at now — and says plainly when no warning
preceded it. A first reading of `unknown` to `healthy` is a startup rather than
a recovery and announces nothing, because a bridge that reports a recovery on
every restart is one whose alerts get muted.

## Version 7.84.0

A design pass on two screens: the one that is typed into, and the one searched
for a fault.

The field prompt says what to do now. Every other screen in the bridge answers a
button press with more buttons, so an operator who has just pressed one waits
for the next — and this is the single screen that wants typing instead. It said
"send the field text" inside a sentence about the template and left the rest
implied. The last line is now an instruction: write in the message box below and
send. Progress is drawn as well as counted — `▰▰▱  2/3` is read without
arithmetic, and the number stays for anyone who wants it — capped so a template
with twenty fields cannot draw a bar wider than the screen. Four lines, in the
order the question is actually asked: which template, how far through, what this
field is, what to do about it.

The health centre gives every component its own glyph — 📡 Telegram, 🎛 Cinegy,
👁 output monitor, 📶 relay, 💾 storage, 📅 schedule, ⚠️ recent errors. A column
of seven 🟢 says everything is fine and nothing about which row is which; these
are told apart at a glance and at arm's length, which is how the screen is
actually read. What needs attention is lifted above the fold and left unquoted —
it is the screen's answer — and what is healthy folds behind a count, the same
shape the runtime-file screen uses, so one habit covers both.

Order inside each group is untouched. Sorting the whole list by severity would
move Cinegy off the second row to wherever its colour put it today, and an
operator who has learned where to look would lose that.

## Version 7.83.0

The reporting screens take the grammar الحالة الكاملة already used: a verdict
first, the evidence under it.

The health centre now leads with one. It was answering its only question — is
anything wrong? — by making the operator read seven rows and notice a colour.
The verdict is read off the icons the rows carry rather than recomputed, so the
heading can never say "all clear" over a red row, which is the exact failure a
verdict is added to prevent.

The operating numbers get one too. That screen was figures only: someone opening
it because "something feels off" had to already know what a bad number looks
like. It is judged on uptime — a bridge up for eleven minutes has been
restarting — with Telegram's flood limit beside it, the other thing that can be
wrong while every individual figure still looks ordinary.

The runtime-file health screen lifts what needs attention above the fold and
folds the rest behind a count. Sixteen lines of "not written yet" gave a healthy
install the same weight on screen as a broken one, which is the opposite of what
a health screen is for.

Every reporting screen carries its own clock now, so a screenshot sent to a
colleague says when it was taken instead of being asked.

## Version 7.82.0

A secret that could have left in an error message.

`Protect-SensitiveText` has stripped bot tokens and stream keys for releases,
but ten sites went around it. The Telegram file-download URL carries the bot
token **in its path**, and the relay output URL is `rtmp://host/s/<stream key>`;
both end up inside library exception messages, and each has a chat and a log to
leak into.

Every exception message that reaches a chat now goes through the redactor —
seven sites. A chat is the widest audience the bridge has: an import failure is
read by every operator in the group. Redaction costs nothing on a message
carrying no credential, so all of them pass through it rather than each site
being reasoned about separately.

Three log sites too, only from the paths that hold a credential: the relay
source switch, its auto-restart, and the bulletin photo download. Deliberately
narrower than the chat rule — `bridge.log` is private, and redacting a failed
local file write would only make the log harder to read for nothing.

Three tests hold the line: one proving the redactor erases a realistically
shaped token and stream key, and two sweeping the source so a new site cannot
slip past.

The audit behind this also found 907 functions with only five never referenced
anywhere (0.5%) and nine covered by tests with no production caller — listed
rather than deleted, the list being more useful than the removal right now — and
no site anywhere logging a raw URL or `$apiBase`.

## Version 7.81.0

The last of the plain-text screens, leaving only what should stay plain.

The field prompt — the screen an operator actually types into — puts the field
being asked for in bold with the raw variable name under it in monospace. The
variable is a Titler identifier like `Ajel.center`, and monospace is what says
"this is the machine's name for the field, not a label to read". Where a
template offers no friendly label, the raw name stands alone.

The setting prompt puts the current and default values in monospace so they line
up under one another and can be compared at a glance, with their digits staying
left-to-right beside the Arabic. The bulletin's sync note gets a bold verdict,
monospace figures, and `LoopEndFrame` marked as the Titler field name it is
rather than a word to read.

All of it is escaped: template key, field label, variable name, setting
description and both values. `templates.json` is written by hand, so a `<` can
arrive in any of the three the field prompt shows at once — pinned with a test
on a template carrying all three.

`Get-OnAirShareText` remains plain, as its own comment has always asked: it is
meant to be pasted into another app, where markup is the one thing that breaks
it.

## Version 7.80.1

The manager logs its own exit, so the absence of that line becomes evidence.

Closing the program from the tray icon was not recorded at all, so a manager
that had vanished from the tray left the same trace whether it closed itself or
something outside ended it: nothing. Every deliberate way out writes a line now,
and the value is mostly in its absence — a manager that is simply gone with
nothing in `manager.log` was ended from outside, by a task manager, an
installer, or a build that needed the exe unlocked.

Which is what had happened: a report that the manager was "closing by itself"
turned out to be the build commands in a development session ending the process
to free `BridgeManager.exe` before publishing. The log could not say so. Now it
can.

## Version 7.80.0

A hardening pass: two faults an operator could see, and the three biggest files
split up.

The "still running" balloon fired on every close. The comment above it has said
"once" since the balloon was added and the code never did it, so an operator who
hides this window a dozen times a shift saw a dozen notifications and read them
as the window asking permission to close. It shows once now, remembered in the
manager's settings so reopening does not make it new again.

A fault in the manager's UI opened a dialog every second. The clock timer ticks
once a second; a fault inside it is caught, reported, and thrown again on the
next tick — one modal dialog per second, faster than an operator can dismiss
them, while the bridge being supervised runs on perfectly well. The first
occurrence is reported and the rest are logged, with the dialog free to return
after ten minutes.

The audit found less than feared and one real thing. The single
`Measure-Object -Maximum` is guarded a line above it; there are no empty
`catch {}` blocks anywhere in `Parts/`, `Modules/` or the main script; and of
the 84 sites that looked like swallowed errors, most are `-ErrorAction
SilentlyContinue` on best-effort cleanup and fourteen return a failure envelope
the caller inspects. The one real finding: a failed enumeration of other bridge
processes returned an empty list, and the caller turned that into a confident
wrong sentence — "the lock is held but no other bridge process can be found, so
a console is holding it". The failure is said out loud now, so "none" cannot be
mistaken for "could not look".

Three files were three times over the size this repository asks for. They are
twelve now: `Bridge.Mojaz` (2733) became four, `Bridge.ShowFlow` (2733) became
four — the release notes and the operator manual were never the show flow — and
`Bridge.Admin` (2149) became five. Dot-sourced parts share one scope and load
order between them does not matter, so this moved text and nothing else. Not one
of the 1398 tests changed, which is what says so.

## Version 7.79.0

The quote bar gets one meaning.

The problem was never the shape — it was that the bar meant two things. On one
screen "material taken from somewhere else", on another "a list of details", and
an operator working under pressure learns nothing from a mark that means two
things. It has one meaning now: **detail you may skip**, with the verdict above
it rather than inside it.

So it comes off the user-activity list, which is that whole screen rather than
evidence under a verdict it has already given; a bar around the only thing on
the screen teaches nothing, which is the single job a consistent mark has.

It stays where the block really is evidence: the health-centre rows, the
runtime-file list, the secondary counters in the operating numbers, the usage
ranking, and the notable events in the handover digest — those last genuinely
quoted, being lines the bridge wrote elsewhere.

Long lists now fold themselves away. Folding is the one thing the quote gives
that spacing cannot: the verdict above the list and the advice below it both
stay on the first screen of a phone instead of being scrolled past. The
threshold is five rows, or ten lines in the file-health screen, where each file
costs two.

## Version 7.78.0

The menu screen loses the quote bar and gains who put each layer up, and when.

The `<blockquote>` is gone. Its heavy bar down the side reads as material taken
from somewhere else, and this is the screen's own answer — on a screen an
operator opens dozens of times a shift. A blank line above the block and another
below groups it just as well and claims nothing.

Under each layer is a line saying how long it has been on air and who pushed it:
the two questions an operator asks about a graphic they did not put up
themselves. Both facts were already recorded — the hide confirmation has printed
them for releases — and the screen an operator actually lands on did not say
them. A scene the bridge did not push has no operator to name, so it says
"Cinegy (خارج الجسر)", which is how an operator learns it came from the engine
rather than the bot.

The list caps at four. Each layer costs two lines now, and eight of them would
push the engine and operator lines off the bottom. Nothing is lost: the keyboard
under the message carries a named hide button for every live layer, and the
screen says how many it did not list. The count in the heading is the real one,
not the shown one.

A record carrying neither a time nor an operator no longer takes the screen
down. These are written by a dozen call sites and each carries only what it
cares about; under StrictMode an absent key would have brought down the screen
opened when something has already gone wrong.

## Version 7.77.0

The manager carries its own version now, not the bridge's.

`BridgeManager.exe` is stamped with the major version only: `v7`. The two drift
apart on purpose — the bridge ships several times a day, the exe is republished
only when the manager itself changes — so a manager stamped 7.76.0 beside a
bridge at 7.79.0 reads as out of date when it is current. The major number is
the compatibility claim it can actually keep: this is the v7 manager, for a v7
bridge.

That made the status line actively misleading: it read "running for … · pid
28728 · version v7" where every other figure on it belongs to the bridge, so the
manager's version was read as the bridge's. It now names both — "الجسر v7.76.0 ·
المدير v7" — with the bridge's read off the startup line it prints into the log
the manager is already tailing, and forgotten on stop, because a stopped
bridge's version is last run's.

The line grew by two versions, and a fixed-height docked label cuts a too-long
string off mid-character with nothing to say it did — losing the end, which is
where the versions are. It ellipsises now, with the whole line on hover.

`F5` and `Ctrl+L` existed for a release with nothing on screen saying so, which
is the same as not having them. Both are named in their button tooltips now —
recognition over recall, the same reason `(Ctrl+F)` is written in the filter box.

## Version 7.76.0

The last four screens move to `parse_mode=HTML`, and nothing is sent as plain
text now except the one thing that must be.

The operating numbers, the usage summary, the template preview and the
favourites screen. Uptime leads in bold because it is the number that screen
exists for — a bridge up for eleven minutes has been restarting — and every
figure beside it is a `<code>` span that stays left-to-right and is tap-to-copy.

The template preview now leads with what is read just before something goes to
air: which template, and whether it is already up. The detail sits under them in
a blockquote instead of a row of `━━━` over one flat column. On the favourites
screen the explanatory line is italic — it is the whole point of the screen,
explaining the two states the tick marks cannot, and it read as a second
instruction.

`Get-OnAirShareText` stays plain on purpose. Its own comment says why: it is a
summary meant to be pasted into another app, and markup is the one thing that
breaks it there.

The validity test covers these screens too, including a hostile template with
`<` and `&` in its key, description, category and field names — all of it comes
out escaped and reads back correctly. That test caught a fault written during
this very change: a `<code>` inside an `<i>` on the favourites screen. The
counts there are plain digits inside the italic sentence now; splitting the
sentence into three spans to buy monospace would have cost the sentence.

## Version 7.75.1

Two lines from 7.75.0 would have stopped their screens arriving at all.

`<b>…<code>n</code>…</b>` looks like ordinary nesting and is not. Telegram's
entity rules are explicit: bold, italic, underline, strikethrough and spoiler
entities cannot be combined with `code` or `pre`, and the API refuses the whole
message with a 400 rather than dropping one of the two entities — which on the
phone is a button that does nothing. The two places were the failed/blocked
line in the handover digest and the "files needing attention" line in the
runtime-file health screen; both are side by side now rather than one inside
the other.

A test keeps it out. It checks the allowed tag set, that tags balance, that no
blockquote sits inside a blockquote, and that `code` never shares characters
with an emphasis entity — on the screens as they are actually built, and across
every source file, because the combination is easy to write and impossible to
see.

## Version 7.75.0

The rest of the screens move to `parse_mode=HTML`, and the menu gets structure
rather than a drawing of structure.

The menu's on-air block is a `<blockquote>` now. The screen had been sent as
HTML since 7.73.0 but spent the markup on emphasis alone, so it still read as
one flat column with two rows of `━━━` scratched across it. A blockquote is the
structure itself — Telegram draws the bar and the indent, which is what
separating a block means — so the verdict above it and the engine line below it
are outside something rather than merely between two rows of dashes. It folds
itself away (`expandable`) past four layers: a gallery with eight up pushed the
engine and operator lines off the bottom, and those are the two lines an
operator quotes when reporting the very fault they are looking at.

Five more screens converted: the handover digest, the health centre, the
runtime-file health screen, the user-activity list and the template-history
answer. Section headings are bold so a long screen can be scanned rather than
read; clock times and counters are `<code>`, which keeps digits left-to-right
beside the Arabic and makes each one tap-to-copy; and material quoted from
elsewhere sits in a blockquote. On the activity list the caveat is italic and
set apart from the list — "active" there means "spoke to the bot recently", not
"online", and reading it as one more list row is the misunderstanding the
caveat exists to prevent.

Everything a person typed on those screens is escaped: template names, operator
display names, aliases, free-text audit messages, and the search term typed by
whoever ran `/who` — the string closest to a user's hand on any screen here. A
single `<` would cost the whole screen a 400, which reads on the phone as a
button doing nothing.

## Version 7.74.0

A shorter menu, a log pane that is never left blank, and a heartbeat that
retries before it complains.

The admin menu was sixteen rows — a wall on a phone, and every row above the
on-air controls is a row to scroll past while a wrong graphic is live. Three
pairs now share a row, paired by meaning rather than to save space: the two
status screens are one question at two depths, the schedule and the reports are
both "what is coming / what happened", and the ticker and the bulletin are the
words going out under the picture. One-hand mode still splits every pair back
apart — the pairing is a layout choice, and an operator saying they are holding
the phone in one hand outranks it.

An empty log pane is not neutral: this window's whole job is to say whether the
bridge is alive, so a blank column reads as "it stopped logging". Typing a
filter that matches nothing produced exactly that, with only a small
"المعروض: 0 من 1842" at the foot of the window to say otherwise. The pane now
says which of the three situations it is in and how to get out: nothing has
arrived yet, the filter excluded everything, or the errors-only chip did — and
that last one says a clean log is the point, not a fault.

`F5` restarts and `Ctrl+L` clears the pane. Both go through the same buttons the
mouse uses, so the confirmation is the same, and `F5` does nothing while its
button is disabled — otherwise a keyboard restarts a bridge already stopping.

The heartbeat write is retried once before anything is logged. The failure this
file actually sees is a reader landing on the instant of the write: four in a
fortnight on this installation, every one gone by the next loop, each logged as
though the watchdog had stopped — which teaches an operator reviewing the log
that the line means nothing.

## Version 7.73.0

The status screens are built as `parse_mode=HTML` now, and the bulletin warns
when a row hold does not fit the template's loop.

ℹ️ الحالة, 📊 الحالة الكاملة and the menu screen were flat columns of text. The
verdict is bold now, because it is the one line that has to land in a glance,
and the six section headings in the full status separate thirty-odd lines that
were read as one block. This text path is the screen an operator actually sees:
`sendRichMessage` is Bot API 10.1 and most servers refuse it, so the fallback is
the design rather than a degraded copy of it — and it was going out with no
formatting at all.

Every figure an operator quotes — the engine address, the channel, the clock,
the counters — is a `<code>` span. Not decoration: monospace renders
left-to-right, which stops digits reordering against the Arabic around them, and
Telegram makes each one tap-to-copy for someone writing a fault report.
Everything a person typed — a template name, an alias, a store error — is
escaped, because a single `<` in a template name would cost the whole screen a
400, which reads on the phone as the menu button doing nothing.

`/بدء` and `/إلغاء` passed an intro that replaced the screen, so the two
most-used doors into the bridge still ended at "اختر من القائمة:" — the
data-free line this screen was rebuilt to stop showing. An intro leads the
screen now; it does not replace it.

A live bulletin held every row 1500 frames against a 750-frame loop, so each
headline played twice and read on air as a bulletin stuck on one item. Both
numbers were already on the screen and nobody compared them. The bulletin says
it now — under the two figures, on the duration prompt, and in the log at
playback start — and stays quiet when «مزامنة الظهور» is on, because that
setting takes its pace from the loop and cannot drift from it.

## Version 7.72.0

The menu screen now names the operator it was built for. A `👤` line at the
foot of it, built with the same `Format-UserAuditActor` helper ℹ️ الحالة uses
rather than a second piece of formatting — so one person is written one way on
both screens, and the bracketed id stays pinned left-to-right after an Arabic
name instead of rendering as `)8201739556(`. Asked for without an operator, the
line stays out rather than printing a bare zero.

## Version 7.71.0

Formatting for the menu screen, and a fault the formatting test then found.

The screen is three separated blocks now — the verdict, what is on air, then
the engine and channel. Run together they read as one paragraph an operator has
to take apart under pressure, and the first line is the one that gets looked at
in a glance. Each on-air layer gets its own line, too; joined with a separator
they were a single run of text you had to read word by word to find one layer.

The verdict is the same wording ℹ️ الحالة uses, read off the stored freshness
rather than a live Cinegy sweep, because this screen opens on every menu press
and cannot pay for a round trip to the engine each time.

And "all clear" is now claimed only on a confirmed reading. The test written
for the formatting caught it: a bridge that had never reached Cinegy once still
announced 🟢 all clear — an assertion with nothing behind it, and the same false
comfort as a stale "on air" that reads like a fresh one. Green requires a
confirmed check; stale, unreachable and not-yet-checked all say so instead.

## Version 7.70.0

Pressing the menu used to produce two messages, and the first carried nothing.

That first message said only "use the 🏠 menu button below to come back here",
and existed purely to pin the persistent reply keyboard. Telegram keeps a reply
keyboard until it is replaced, so re-sending it on every press bought nothing
and cost the operator a message telling them the menu exists, sitting directly
above the menu they had just opened. It is pinned once per chat now, so what
someone sees when they press the menu is the menu.

The menu screen also answers instead of pointing. It was a single on-air line;
it now carries what is on air, how old the last Cinegy check is — a stale "on
air" reads identically to a fresh one, which is what let an exited scene sit
unnoticed — and which Air engine and channel the claim is about. An operator
who opens the menu gets the answer there, without spending a tap on ℹ️ الحالة.

## Version 7.69.0

Finishes what adoption left half-done in 7.68.0, and answers a question the
header was never answering.

"Running" only ever meant the *process* was alive. A bridge Telegram has
refused, or one that cannot reach the Air engine, is alive and useless at the
same time, and telling those apart meant reading log lines. The bridge
announces both transitions itself, so the header now reads those lines as they
go past and keeps the answer on screen: **Telegram: connected** and **Cinegy:
healthy**, green while they hold and red when they drop. Both reset to a dash
on every restart, so a previous bridge's state is never shown as the present
one's.

The log pane is no longer blank after adoption. A bridge this window did not
start owns its stdout, so the pane came up empty and sent the operator to a
file in Explorer — the last thing adoption left unfinished. The bridge writes
those same lines to `logs/bridge.log`, so the pane follows the file instead:
seeded with the last hundred lines, because an empty pane for a bridge that has
been quiet for hours is indistinguishable from a broken one, then appended to
every second. A read that lands mid-line holds the fragment back rather than
drawing half a line and then drawing it again in full, and a rotation — the
file shrinking under the read offset — restarts from the top instead of
skipping the whole beginning of the new file. Following stops the moment a
bridge is started from this window, whose stdout the pane already has, so no
line is ever printed twice.

The manager self-test grew from 77 checks to 101, all of them on the new pure
logic: splitting complete lines, spotting a rotation, and reading a health
line's destination rather than its origin.

## Version 7.68.0

Three fixes a review of three days of logs found, rather than a user report.

The work report counted a refusal and an engine failure as the same number.
`blocked` means a person was stopped — a missing permission, a maintenance
window — and `failed` means Cinegy did not do what it was told; merged, a shift
full of refusals read exactly like a shift full of engine errors, and the two
call for opposite responses. They are separate now, and neither is printed when
it is zero: a "0 blocked, 0 failed" on every clean line teaches the reader to
skip the symbols that matter on the line that is not clean. The report also
answers the three questions a supervisor asks after "how many": how many
operations actually reached air (a successful SHOW — a hide is not air time and
a blocked show never left the building), which template the operator spent the
shift on, and when they were last active, plus a shift total once more than one
operator is involved.

That report shipped in 7.66.0 with no test at all. It has eight now, and the
first of them immediately caught a `.Sum`-on-an-empty-collection throw that had
just been reintroduced in the totals line — the same fault that took the
bulletin report down on a quiet day once before. A quiet day is exactly when a
report gets opened to check.

The manager reported "stopped" beside a bridge that was plainly on air. Closing
the manager leaves the bridge running by design, but reopening it showed
"stopped", and both auto-restart and hang detection sat idle because they watch
a process that window never started. The bridge now writes its process id as a
second line in `logs/bridge.liveness` — an older reader still sees the stamp on
line one — and the manager adopts a live bridge on open instead of taking the
graphics down for the seconds a restart would cost. The one thing adoption
cannot recover is the log pane: stdout belongs to whoever launched the process,
so the window says so rather than looking broken.

Reading that heartbeat no longer blocks writing it. `File.ReadAllText` opens
with `FileShare.Read`, which denies the writer, and the bridge log carried
"Could not write the liveness stamp … used by another process" three times in
three days. Nothing broke — the bridge rewrote it on its next loop — but an
observer has no business blocking what it observes.

Finally, one `<Plate>` without a `File` attribute no longer costs the whole
bulletin picture measurement. Reading `.File` off every node throws under
`Set-StrictMode -Version Latest`; the plate is selected in XPath now, so an
absent attribute is simply not a match.

## Version 7.67.0

Bulletin recovery verifies the confirmed live scene identity before resuming
row updates or exiting a scene. Deferred Telegram retries now use one background
request, keeping network timeouts out of the air timing loop. Queued uploads own
temporary copies (64 MiB total per run), so report cleanup cannot invalidate a
retry; copies are removed when sent, discarded, or during normal shutdown.

Manager save-and-restart verifies that the bridge has stopped before writing
permissions. Failed writes release the configuration lock and clean private
staging files; a failed save leaves the bridge stopped. The live log retains
arrival order while preferentially preserving warnings under load. Manager
builds now carry the full bridge version and support isolated output for checks.

## Version 7.66.0

The weekly usage digest now reads the last seven days of audit records instead
of process-local counters, so restarts do not erase its estimate. Reports gain
a Work report that groups successful and unsuccessful on-air actions per operator.

## Version 7.65.2

Saving permissions in an already-open manager window now preserves a newer
BotToken, Air server address, or channel value written to disk by the bridge.

## Version 7.65.1

Flood-limit deferral now includes photo, document, rich-message and rich-edit
requests, replayed through their original Telegram endpoint. Callback answers
remain immediate because their query may expire before a deferred retry.

## Version 7.65.0

The manager's live log now highlights the timestamp, level, Air operation id,
layer and result without exposing settings secrets. Its display queue is bounded
and drained in short batches, so a burst cannot freeze the UI; warnings and
errors run ahead of ordinary output, very long display lines are shortened, and
filtering waits briefly for typing to pause.

Telegram's 429 retry outbox is also bounded to 200 messages and sends at most
three due messages per poll cycle, prioritising warning/error notifications.
This keeps long-running monitoring and scheduled work responsive after a flood
limit clears. The settings window is resizable on short screens, and its manual
config editor is unavailable while the bridge owns `config.json`.

## Version 7.64.0

This reliability release rechecks authorization at the final step of pending
flows and on-air callbacks, protects the configured owner, and verifies the
live Cinegy item before Mojaz recovery resumes or exits it. Telegram flood
waits are deferred through the tick so polling and watchdogs remain responsive.

Manager restarts wait for the old process to exit. Config writers share a lock
and unique temporary files, invalid sheet imports preserve another editor's
draft, and yesterday's report stops before today begins.

## Version 7.63.0

A full review of `BridgeManager.exe`, the desktop control program. Every change
below fixes something that was wrong, not something merely missing.

"Start with Windows" only ever brought back the supervisor: the machine
returned from a power cut with the manager window sitting over the playout
screen and the bridge still stopped — the exact gap the checkbox exists to
close. Its Run-key entry now carries `--autostart`, so the manager comes up
straight into the tray and starts the bridge itself.

Editing the chat/user id whitelists while the bridge was running was reverted
in silence. `Save-Config` lists `AllowedChatIds`, `AdminChatIds`,
`AllowedUserIds` and `AdminUserIds` as bridge-managed and writes its in-memory
copy over whatever is on disk, so an id added from the manager disappeared at
the bridge's next save, with no message anywhere — and plain "Save" is the
dialog's accept button, so pressing Enter took that path. The form now compares
what was edited against what it loaded and, if one of those four changed while
the bridge runs, offers the restart that makes it stick.

The bot token was displayed in clear text, which `AGENTS.md` forbids outright.
It is masked now, behind a "show" toggle. Where DPAPI protection is enabled the
file holds `dpapi:BotToken`, and the form used to present that as though it
were the token — inviting an operator to "fix" it by pasting the real one, and
putting a plaintext secret on disk in an installation that had deliberately
encrypted it. The field is disabled in that case, with a note pointing at
`scripts\Protect-BridgeSecrets.ps1`.

Config writes are atomic. The bridge writes via a temp file and keeps backups
because a truncated `config.json` stops it from starting at all; the manager
used a plain `File.WriteAllText`. It now writes `.tmp` then `File.Replace`
(which keeps a `.bak` and preserves the file's existing permissions), and
applies the same user/SYSTEM/Administrators ACL as `Protect-BridgePathAcl` when
it creates the file.

Windows shutdown is no longer cancelled — that produced the "app is preventing
shutdown" wall, a forced kill with nothing logged, and a ghost tray icon.
Toolbar toggles persist between runs, so turning auto-restart off for a
maintenance window stays off.

The manager now also detects a *hung* bridge, not just a stopped one. It
deliberately does not infer this from log silence: measured against this
installation's own `bridge.log`, a healthy bridge prints nothing from about
22:30 to 09:00 night after night, once for a continuous 17.8 hours, so any
silence threshold short enough to catch a hang would have restarted a working
bridge on air every night. The bridge instead stamps `logs/bridge.liveness`
after each poll loop and the manager watches that. Every ambiguity resolves
towards doing nothing: a bridge still booting, an older bridge that publishes
no stamp, or a stamp left by a previous run all count as healthy, and the
second case is announced once rather than looking like a watchdog that works.
The threshold lives in `BridgeManager.settings.json` as `HangWatchdogMinutes`
(default 5); the on/off switch is the 🩺 checkbox on the toolbar.

The log pane colours errors and warnings, filters by text or "errors and
warnings only" (Ctrl+F), and counts its lines instead of estimating them.
Output is batched every 100ms rather than marshalled per line, process and icon
handles are disposed, dialogs raised from the tray bring the window forward
first, and the single-instance lock is now global so two Windows sessions
cannot supervise one bridge.

The window itself was redesigned. Eleven controls sat in one row at equal
visual weight - "Stop" looked like "Clear screen" - and the bridge's state was
an 11pt word wedged between them. There is now a header that states the state
in 16pt against a colour-coded bar, readable across a room, with uptime and pid
under it; a real hierarchy between the buttons that change what is on air and
the ones that merely open something; a status bar carrying line count, the age
of the last heartbeat and the bridge path; and a tooltip on every control.

**Light is the default and dark is a toggle** (the 🌙 chip), applied live
without a restart. The manager is opened during the day beside Explorer and the
Cinegy client, where a lone black window reads as a different application; dark
stays for whoever is sitting next to a programme monitor at night.

Permissions are now a list rather than five boxes of comma-separated numbers.
Each account is a row with its role and kind, added through a field and a role
picker, removed behind a confirmation that names the ids losing access. Only
one direction is rejected: a negative id in a *user* role names a group where a
person is required. A positive id in a *chat* role is not an error - Telegram
gives a private chat the same id as the person in it, and this installation's
`AllowedChatIds` is full of them.

Anything that weakens control now asks first: restart, switching off
auto-restart, switching off hang detection, and removing accounts. Only in the
switching-off direction - a box that appears both ways teaches people to
dismiss it - and never on the paths the watchdog or "save and restart" take,
where nobody is standing in front of the screen.

Finally, `--selftest` actually runs. It had existed for releases without being
called by `Run-Checks.ps1`, `Build-BridgeManager.ps1` or CI, which is the same
as not existing; the build script now runs it after every publish and fails the
build on a non-zero exit. It grew from 6 checks to 30.

## Version 7.62.0

The bridge now says when the logo or the news strip is not on air. These are
graphics nobody expects to come down, and their absence was noticeable only by
looking at the screen.

It asks Cinegy rather than its own record, which is the whole point: what
matters is that the graphic is gone, not who took it, and the bridge's record
only ever describes what the bridge itself did - an absence caused from
outside would have passed unnoticed. The set needs no new setting either: a
template marked longRunning is exactly one nobody expects to take down, and
the logo and the strip already carry that mark.

It waits for the miss to be confirmed, because a permanent graphic is
legitimately down for the seconds a swap takes and an alert on every such
moment is one nobody reads. It says so once, and once more when the graphic
returns. A layer the engine did not answer for says nothing about what is on
it, so it is left alone. It costs no extra request: it reads the layer sweep
the Cinegy watchdog already performs.

The log also now records where a bulletin took its timing from - the engine's
clock or the bridge's. It logged the refusal of an anchor but never its
acceptance, so "anchored" and "the engine said nothing, we fell back" looked
identical from outside. A feature whose claim is millisecond accuracy has to
report what it actually did.

## Version 7.61.0

Unreferenced bulletin pictures are kept for forty-eight hours rather than
twenty-four. That is a change of default only: a running installation already
holds the value in config.json, so the live one is changed from Settings ->
On air -> picture retention, or by resetting that one setting after upgrading.

The bulletin is now timed from the engine's clock. Researched first: Cinegy
exposes no loop counter and no timeline position - only /metrics,
/gfx_N/status and /gfx_N/status/active answer here, everything else is 403,
and /metrics is channel health rather than the position of any scene. But the
active item carries ScheduledAt to the millisecond and it does not move while
the scene loops, so it is the one true zero, replacing a stopwatch that
started when the SHOW request returned - a round trip later and jittered by
the poll loop. An anchor that is not believable is refused, because a wrong
one moves every write out of the 1.2s fade, which is worse than the jitter it
removes. The anchor is kept with the run, so a bulletin resumed after a
restart recovers the scene's real loop phase instead of approximating it.

Groundwork for the generated row screen also lands: what a row is asked for
now comes from the design - editorial order from the registry, Arabic wording
from its fields list, and a variable no element consumes left out because
filling it would put the value nowhere. Reading a row tries its field bag and
falls back to the three properties it has always had, so a bulletin written
before designs existed plays on one without being rewritten.

## Version 7.60.0

Sync-to-loop is now explicable from the screen rather than from watching air.
The button said yes or no and nothing else, for an option that governs the
pace of the whole bulletin: it now says what it does - pace from the loop, or
pace from your dwell - the plan line states the cost outright when it is on,
with the loop's length in seconds beside it, and the help chapter explains the
mechanism. The scene loops, and at the wrap the content drops to nothing and
fades back; off, a row is written when its time comes and may be seen
changing; on, it is written inside that fade and arrives looking as though it
had just entered. The price is that the pace becomes the loop's length rather
than the dwell you typed, and it is changed by re-cutting LoopEndFrame in
Titler.

The first step of the creation wizard lands behind the option that ships off:
a new bulletin is asked for its design before its name, because the design
decides what a row will be asked for at all. The question appears only when
there is a choice - one design is not a choice - and a template becomes a
design by declaring itself one rather than by having a loop and a text field.
Each is read from its own scene: how many media and text fields, and whether
it walks a list or carries a single story. A declared design that cannot be
read stays in the list with the reason, because somebody who declared it and
cannot find it deserves to be told why. Swapping the design of a bulletin
that is on air is refused.

## Version 7.59.0

A bulletin on air now survives a restart of the bridge. Reported as "the last
one stuck looping on story eight and I had to take it off by hand"; the log
said the bridge had been restarted three minutes and forty seconds into a five
minute run, which at thirty seconds a row is story eight. Cinegy knew nothing
about that, so the scene stayed exactly where it was, looping - what died was
the plan that walks the rows and sends the EXIT.

Everything else the bridge holds already survived a restart: what is on air,
the auto-hide timers, the template reminders, the schedule. The bulletin
playback was the one exception. It is now written when a run starts and
dropped when it ends, and on startup a run still within its time is picked up
at the row the clock says - the plan holds absolute moments from the start, so
elapsed time alone says which row is due and the run rejoins its own schedule
rather than restarting. Past its exit it is taken off instead. If the layer no
longer belongs to the bulletin nothing is touched, because somebody dealt with
it while the bridge was down and acting there would remove whatever replaced
it.

An operator can also set the exit outright. A video report is one story, not a
list: it has nothing to walk through, and asking somebody to express "keep it
up for forty seconds" as a row dwell plus an intro plus a last-row hold is
asking them to do arithmetic to say something simple. Zero leaves the row
timing in charge, which is every bulletin that exists today. And an uploaded
clip that knows its own length supplies that duration when none was typed -
never over one that was.

Behind an option that ships off, the bridge now reads a design's fields out of
the scene file itself rather than from a hand-written mirror that drifts
silently. Two rules I had written and got wrong were corrected with it: a
design need not have a title and a story, since a video-only design is a
perfectly good bulletin, and it need not have a loop, since one carrying a
single story enters, plays and leaves.

## Version 7.58.0

Announcements. An administrator writes a notice and it reaches whoever they
choose. The log and the audit trail record what the bridge did; this carries
what a person needs the others to know, and it is the only message the bot
sends that nobody asked for - so every part of it is bounded.

Who: everyone, operators only, or administrators only, with the roster read at
send time rather than frozen at composition, so somebody granted access this
morning is reached and somebody whose access was revoked at noon is not. How
long: one, six, twenty-four or seventy-two hours, after which it retires
itself. How often: once, or every one, three, six or twelve hours - hours and
never minutes, because this interrupts people who are working, and a notice
that nags teaches them to dismiss the next one unread. A "read" button stops
the repetition for whoever presses it, which is its whole purpose, and the
screen says how many have. Pinning adds one line above the main menu for those
who have not read it, capped at eighty characters because it sits on a screen
used under pressure. It never reaches its own author, and a repeat falling
inside quiet hours is held for the first sweep afterwards rather than dropped.
The text was written by a person, not the bridge, so it is escaped like any
other untrusted input.

## Version 7.57.0

Settings gain a Notifications section. Everything that decides whether the bot
speaks to somebody was spread across five categories - monitoring, schedule,
on-air, news and templates - so an operator asking why it woke them at 3am was
reading four screens. Twenty-three settings now sit together: quiet hours, the
five admin alerts, the schedule pre-notice, the bulletin notices, the forgotten
template reminder, the heartbeat and the weekly digest.

Two new switches. The access-request broadcast has one at last - the request is
queued either way, and this decides only whether it also interrupts somebody.
And the guard now tells the administrators when it blocks a chat: it used to
block, write a log line, and nothing else, and a block nobody is told about is
one nobody knows to lift. Administrators only - blocking stays silent towards
the blocked chat, and a rejection an administrator just made is not news to
them.

## Version 7.56.0

Reports gain a bulletin section, which needed a record that did not exist: a
bulletin reached air as an ordinary air_control SHOW of the Mojaz scene, saying
that a graphic went up and nothing about which bulletin it was, how many
stories it carried, or whether a person or a schedule started it. Every run now
writes a permanent mojaz_run record at its start and another at its end under
one operation id. The report pairs them, so a bulletin still on air has a start
and no end and says so rather than being dropped or counted as finished, and
the duration comes from the playback's own clock rather than the gap between
two audit stamps. The run is closed from both endings - the bulletin's own stop
and the layer being taken by something else - because closing it in only one
would leave runs reading "still on air" for ever.

The period you are reading is now marked in the report buttons: four identical
buttons above a report that does not repeat its own window left the operator
guessing which they had pressed.

The Mojaz picture sweep was verified and tightened. Its conditions were already
right - only files the bridge named itself, inside the bulletin picture folder,
unreferenced by any saved row or running snapshot, and older than a day - but
it walked the directory on the polling thread every time round the loop, for a
job whose whole premise is that nothing has touched those files in a day. It
runs hourly now, and its window is a setting (MojazImageKeepHours, 24; zero
keeps every picture).

## Version 7.55.0

A consolidation pass after a run of feature work. Four dimensions were audited
mechanically and one systemic fault came out of it: three screens built a
keyboard from a collection that grows, with no paging - the bulletin library,
its schedule list, and the upcoming-events list. The last of those draws three
buttons per event, so it filled a message faster than anything else here: a
fortnight of daily events was already past what Telegram will send, and its
text went out stripped of markup for the same reason. All three page now.

More to the point, that is the fourth time this same fault has been fixed in a
different screen. Fixing it a fifth time by hand is not a plan, so the rule is
enforced: a test walks every keyboard builder and fails any that loops over a
collection without Get-BridgePageWindow. A screen whose collection cannot grow
is exempted by name with the reason it cannot, and a second test fails any
exemption naming a function that no longer exists, so an exemption cannot
quietly become cover for the next offender.

What the audit found clean, recorded so it is known to have been checked: all
162 settings are read, labelled and categorised with no dead entries; no
untrusted text reaches an HTML message unescaped; and no callback branch
mutates anything without a permission gate.

## Version 7.54.0

The claim is withdrawn at its source. Naming an unnamed item from the template
registry (7.52) and then marking it yellow (7.53) both treated the symptom: the
bot still said there was a bulletin when there was none. The rule is gone - an
item the engine will not name is not adopted at all - which is the right
behaviour while nothing distinguishes a layer whose scene has exited from one
that is showing.

The stale record is cleared too. The one written at 21:19 survived the restart
in onair.json and went on claiming air; reconciliation now drops any
*discovered* record whose layer the engine will not name. A bridge-pushed
record is never touched by that rule: it is the bridge's own knowledge of what
it did, and a read that cannot represent an exit is not evidence against it.

No control is lost. The layers screen reads Cinegy live and already offers
"hide" for every layer the engine reports on air, with no onair.json record
involved - which is the honest place for it, since the bridge cannot verify
visibility itself.

## Version 7.53.0

The bot said a bulletin was on air when the screen was blank. It had been
exited at 18:14 - the bridge dropped its own record then, correctly - and the
new discovery adopted it again at the 21:19 restart.

The reason was already written down in `Remove-OnAirRecord`: HIDE makes Cinegy
mark the item `IsEmpty="y"`, but EXIT_SCENE_LOOP ends the animation and leaves
the playlist item Active under the same Id with no marker at all, so a layer
that has played its way off the screen reads exactly like one still playing.
Measured: layer 5 (exited bulletin) and layer 8 (visible strip) were identical
in every field the engine exposes - IsOnAir, ActiveId, LogId, ScheduledAt,
Duration, ManualEnd, OutputState - and both `/status/active` and `/item/<id>`
are 403 on this installation.

With no evidence that separates them, the claim is corrected rather than
withdrawn. An unnamed item proves a scene is loaded on the layer, not that
anything is rendering, so it is still adopted - the operator needs the button
that releases the layer - but under the source `cinegy-unconfirmed`: a yellow
mark in the menu instead of the red one, and "loaded from Cinegy, may not be
visible" on the status screen. A scene the engine names itself stays plain
`cinegy`, because a name from the engine is evidence of a rendering scene.

## Version 7.52.0

External discovery was not merely missing from the periodic check - it was
dead everywhere. The resolver demanded positive evidence that a layer was
really playing something, and the only evidence it accepted was a describing
name; this engine names nothing it plays, returning every active element as
`<Item Id=.. LogId=.. ScheduledAt=.. Duration=.. ManualEnd=../>` with no Name
and no Description. So the rule refused every layer, and not one external
scene had been discovered since it was written.

There is a second route now, and it invents no name either: hard evidence that
a real item is playing - a non-zero active id, a non-zero LogId, a parsable
ScheduledAt, and no IsEmpty from the engine - plus a name the bridge already
knew, the template registered for that layer. Without the evidence, or without
exactly one template claiming the layer, nothing is added. Ambiguity still
never adds a record. Measured live, the two cases separate cleanly: layers 5,
8 and 9 carried a LogId and no IsEmpty; layer 7, the husk of a spent item,
carried no LogId and said IsEmpty outright.

The thirty-eight Telegram disconnections in one evening were not
disconnections. Each was a long poll that outran its transport deadline,
logged as an error, flipping the state to disconnected and back, and costing a
full timeout of dead polling. The margin over the long poll is now a setting
and defaults to twenty seconds rather than a fixed ten - it covers connection
setup and the trip home as well - and a configurable number of consecutive
late polls is tolerated before the connection counts as lost. A real failure
still takes the old path on the first occurrence.

## Version 7.51.0

A graphic somebody starts in Cinegy now appears in the bot within seconds. The
only periodic reconciliation ran without external discovery and without the
layer dashboard, so it verified the layers the bridge had put up itself and
nothing else - startup discovered external scenes, the status screen discovered
them, and nothing in between did. The news strip was on air and the menu did
not know it.

The users screen draws one row per person instead of five. Ten people made
fifty rows, and finding somebody meant scrolling past nine other people's
buttons with a revoke among them; now the list names people and pressing one
opens their card, where those buttons live and cannot land on the wrong person.
The template-permission screen pages, two to a row: a hundred templates drew a
hundred rows into one message, which Telegram will not send, so the screen
stopped opening on exactly the installations big enough to need it.

BridgeManager - the Windows Forms control program that starts and stops the
bridge, tails its log and edits settings without opening config.json by hand -
is now named in the release notes and documented, and AGENTS.md records how
this repository is developed, documented and tested.

## Version 7.50.0

Five locks on a bot that strangers can find, each with its own switch.

Rejecting a request now blocks the chat, because rejection used to remove the
request and nothing else - the same chat could ask again a second later, for
ever. Blocking is silent towards the blocked chat on purpose, so a Blocked
screen carries the reason, the date and who did it, and lifts a block with one
button. A join code, when set, is asked for before any administrator hears of
the requester; wrong codes are counted, not explained, and enough of them in a
day block the chat. A per-chat daily limit stops one stranger filling the queue
by tapping start, in a window that restarts rather than slides. A daily report
names the authorized users who have gone quiet, with an option to disable them
- never the owner, and never someone with no recorded date, since no record is
not evidence of absence. And the bot walks out of any group it is added to
that nobody whitelisted, saying where it had been.

## Version 7.49.0

A preview button on the bulletin screen shows every row's title and story in
full, with the picture each will really display once inheritance is resolved.
The table keeps trimming to 24 and 60 characters, which is what makes it four
columns that fit a phone - but it was also the only place the copy appeared,
so an editor could not read back what they had written. The preview pages
itself, since a bulletin long enough to need checking is longer than one
Telegram message.

## Version 7.48.0

The row dwell joins the other two timings in frames, so one unit describes the
whole bulletin, with a setting for the newsroom default; bulletins and legacy
playlists holding seconds are converted rather than reset.

Whoever asks for access is asked for their name, and that name becomes their
alias the moment access is granted, so no administrator types it in. The
question comes after the admins are told, never before, since a requester who
never answers must still have a request waiting. It is the one flow a chat
without access can reach, so it checks for itself that the chat is really in
the queue, caps the text and flattens what would break a roster line - and an
alias somebody already chose is left alone.

## Version 7.47.0

Two notices the bulletin did not send: one when a run ends by itself, which is
the only ending nothing else announces since it happens minutes after the
operator stopped watching, and one a minute before a booked bulletin starts.
The warning is marked on the appointment once sent, because the tick runs
every second and an appointment sits inside the window for the whole minute.
Each notice has its own setting rather than one switch for both.

## Version 7.46.0

The bulletin's two animation-tied timings are set in frames, because that is
the unit the animation is cut in, and the rounding to whole seconds is gone
with them: a 30 frame entrance is 1.2 seconds rather than 2, a 168 frame exit
6.72 rather than 7, and the clock runs on the fractions. Two settings carry
the newsroom defaults, taking effect over the scene since a default the scene
always overrides would never apply. A channel frame rate setting - 25, 50 or
60 - is used wherever a scene cannot state its own; where it can, it wins,
being the thing actually being timed.

## Version 7.45.0

The template list is filtered by the permission of whoever opened it: a
template an operator may not put on air is left out rather than offered and
then refused, since a list that shows what pressing it will reject teaches
people to press and see. Search, categories, timed shows, field updates and
scheduling all filter the same way, so there is no back door to a protected
template.

The layers screen - hide, exit, push to a bare layer number - can be kept to
administrators or the owner with one setting, and the callback refuses as well
as the button disappearing, because someone with the old button in their chat
history can still press it.

## Version 7.44.0

The confirmation before hiding or exiting a graphic now shows what it says.
It named the layer, the template, how long it had been up and who pushed it -
everything except the words on screen, which are the one thing an operator can
check against the output under pressure. Fields the template marks sensitive
are named but not quoted. The copy is stored apart from the audit one, since
that is gated by a setting because audit.jsonl is kept for ever while this is
read once and thrown away with the record.

## Version 7.43.0

The layer permission lists are picked too, and every layer shows by its name -
"9 · the logo" rather than "9" - because an administrator protects the logo,
not a number; the number is what gets stored. One picker serves all four
lists, differing only in where the candidates come from, since a second copy
would drift from the first at the next change.

## Version 7.42.0

The two template permission lists are picked from the registry rather than
typed: a row per template, ticked or not, toggled by pressing it. A misspelled
key reads as "not in the list", so a typed permission can protect nothing
while looking set; a picked one cannot be misspelled. Saving goes through the
same path the typed value used, so the log and the audit trail read alike
either way. The layer lists stay typed - a layer number is short and hard to
get wrong.

## Version 7.41.0

"Start later" on a bulletin now asks the way template scheduling asks: the
+15/+30/+60 buttons and a calendar down to day, hour and minute. Typing still
works. It is the same keyboard and the same parser the templates use, so the
picker cannot produce a moment the parser would refuse and the two flows
cannot drift; only where the chosen moment goes afterwards differs.

## Version 7.40.0

The in-chat manual gets a chapter for the bulletin - open to every operator,
since writing one is the operator's job - covering the library, row editing,
the three picture modes (including the inherit mode that lets one picture
serve several rows), the timing and the loop sync, appointments and that they
play the latest saved rows, and which of the bulletin and the urgent yields.
The settings chapter now explains the show and hide permissions. Tests assert
the manual mentions the parts an operator cannot guess from the buttons.

## Version 7.39.1

The four permission settings were read by the show and hide paths but never
declared, so they had no value, no label and no place on the settings screen -
the feature was inert while its own tests passed, because those set the values
directly. Declared now, with an audit that scans every `Get-Setting` name in
the source and fails on any the defaults table has never heard of.

## Version 7.39.0

Showing and hiding a graphic can now be restricted per template and per layer:
four settings name the templates and layers only administrators may touch, and
those only the owner may touch. Empty means everyone, which is what the bridge
did before. Where a template rule and a layer rule both apply the stricter
wins, since a permission that loosens when you add a second rule is not one.

Hiding is governed the same as showing - taking a protected graphic off air
changes the screen as much as putting it on - but only where a person pressed
the button. Auto-hide timers, hide-all and the bulletin's own exit are never
refused: a blocked show leaves nothing on air, while a blocked hide leaves a
graphic up, which is worse than what the permission guards against.

## Version 7.38.0

The row picture's size is a setting now - 538x303, what Titler's exporter
really produces - rather than only what the plate declares in scene units
(525.38x291.61). A measured number beats a derived one. Zero in either
setting reads the plate again, so a template resize still carries for anyone
who has not set it.

## Version 7.37.1

The strip stays up through a bulletin by default: the newsroom tried the
stand-down and chose to keep it. The behaviour is unchanged and still there
under the "hide the strip during a bulletin" setting.

## Version 7.37.0

The news strip and the bulletin share the bottom of the screen, so the strip
stands down when a bulletin starts and comes back when it ends - by EXIT
rather than a cut, so it leaves the way it was drawn to. The logo is not
touched. The return waits out the bulletin's outro, read from the scene, since
putting the strip back underneath a scene still playing its way off is the
overlap the stand-down existed to prevent; booking it on the tick also keeps
one show from running inside another. A strip that was not on air before the
bulletin is never put on air after it.

## Version 7.36.0

The urgent template outranks the bulletin. Anything that puts it on air - a
button, a schedule, a rollback - pulls a running bulletin off first, stated
once inside the show pipeline that every show passes through, so an automated
urgent never waits on a question.

The asking happens earlier, at the confirmation, where there is still time for
it: send the urgent now and lose the bulletin, or hold it until the bulletin
ends - held ones go out by themselves the moment it does. In the other
direction, starting a bulletin while the urgent is up offers to wait for it,
which books an ordinary appointment due now, so the queue that already holds
work while the air is busy handles the waiting, survives a restart, and can be
cancelled from the appointments screen.

## Version 7.35.0

An uploaded picture is now checked and sized before it reaches the folder
Cinegy reads. A phone photo arrives four thousand pixels wide in a shape the
plate is not, which is a known reason for a picture never appearing on air, so
the file lands in a temporary folder first, is decoded - which is the check -
filled and centre-cropped to the plate's own declared size, and saved as PNG
like the scene's own picture. The size comes from the scene:
`<Plate Size="525.38;291.61" File="${mojaz_img}" />`, so resizing the plate in
Titler resizes future uploads. A file that is not a picture is refused with a
message rather than becoming a row that shows nothing.

The main menu's hide button for the bulletin is now always present rather than
appearing and vanishing, coloured only when there is really something on air.

## Version 7.34.0

The main menu gets a hide button for the bulletin, shown while its layer is
occupied - by a run, or by a scene left up after one. It stops the run and
leaves by EXIT so the outro plays, where the plain hide above it would cut the
scene. That plain hide also knew nothing about a bulletin: the layer came down
while the run kept writing rows into a scene nobody could see, and sent an
exit of its own minutes later. Any hide or exit of that layer now ends the run
with it, guarded in the one place both paths pass through.

## Version 7.33.0

The row change can now be hidden by the scene's own animation. At every loop
wrap the scene drops its content to zero opacity and fades it back in over the
entrance frames; with sync on, each row is written just inside that fade, so
the new story is already there by the time anything is visible. That only
lines up when one loop is one story, so the loop length becomes the dwell -
re-cut LoopEndFrame in Titler and the bulletin follows - and the screen says
so, and warns when the loop is long. EXIT is sent on the wrap rather than
after it, where the content is still at full opacity, so the join is seamless.

Timing underneath it was rebuilt: every row has an absolute moment measured
from the start of the run on a monotonic clock, instead of a delay measured
from the previous send that accumulated every round trip; the poll loop now
knows a bulletin is playing, which it did not; and the bridge waits out the
last fraction of a second itself rather than missing the window waiting for
the next tick. Two settings calibrate it against air.

## Version 7.32.1

The row-edit screen was rejected by Telegram and answered nothing - a
keyboard row was flattened into bare buttons. Fixed, with a test that asserts
the shape of every Mojaz keyboard.

## Version 7.32.0

A row can be edited now - press its number for a screen that changes the
picture, the title or the story - and each row states its picture in one of
three explicit modes: its own, the template's, or inherited from the row
above. Inheriting sends no image variable at all, so the picture already on
screen stays, which is how one picture serves a run of rows; the template mode
reads the path the scene declares for itself, so a row that was given a
picture can be put back. The table's picture column shows which mode each row
is in, and a picture already uploaded to the bulletin can be reused with one
press instead of being uploaded twice.

## Version 7.31.0

The single Mojaz table became a library of named bulletins - a morning one, an
evening one, as many as the newsroom keeps - each with its own rows and
timing. Rows now live in one place: every edit writes the library through a
validated atomic save, so a failed write changes nothing and never claims it
saved, and what a restart reads back is exactly what the screen last showed.
The old single table migrates into the library once, and the legacy file is
only archived after the new one is safely on disk.

"Start later" is a saved appointment rather than a promise held in memory, so
it survives a restart; a bulletin can hold several, each resolves the latest
saved revision when it fires, and two appointments never fight for the layer -
the second waits for the first with a single notice. A run works from a
snapshot taken at start, so editing or clearing the table mid-bulletin changes
what plays next time, not what is on air now.

## Version 7.30.0

The bulletin's timing is read from the scene instead of guessed. A Cinegy
scene already says where its loop starts and ends, and those markers are the
three durations this screen needs: 0 to LoopStartFrame is the entrance,
LoopStart to LoopEnd is the part that repeats, LoopEnd to Duration is the
exit. Re-timing the scene in Titler re-times the bulletin with nothing to
change here - the read is cached on the file's write time.

## Version 7.29.0

The two special timings are buttons on the Mojaz screen now: the extra the
first row gets for the entrance animation, and how long the last row holds
before EXIT. Both are saved with the bulletin rather than in settings, because
one bulletin can need its own pace; sending 0 puts the default back. There is
also a deferred start - "play later" - written in the same words the
scheduling screen takes (+30, بعد 90, 21:45, غدًا 07:00) and read by the same
parser.

## Version 7.28.1

Fixes a bug in 7.28.0 that answered every text message - including /start -
with "no picture is expected right now". The photo branch tested for a picture
with @(...).Count on a field that is absent, and @($null) has one element, so
every message looked like a photo. The test is a named function now, with a
test of its own.

## Version 7.28.0

A Mojaz bulletin screen: the editor writes a table of rows - picture, title,
story - sets how long each row holds, and presses play. The scene is shown
once and the following rows are written into it through the postbox, because
re-showing it per story would replay the entrance animation and flash the
screen between them. The first row holds for its dwell plus that animation,
and the last holds for half before EXIT plays the outro. Pictures upload
straight from the phone and are saved beside the scene, where the bridge's own
upload sweeper cannot delete one that is still on air.

## Version 7.27.0

The home button was dead on seven screens. The router knew `menu` and not
`menu:main`, which is what diagnostics, quick start, both report screens, a
help chapter, the help index and my-operations send - so the press fell to the
default branch, answered "unknown option", and left any half-finished input
pending: the one button an operator presses to get out of a flow was the one
that did not clear it. The audit that found it is now a test: every
callback_data the keyboards emit must have a handler.

## Version 7.26.0

Both backup screens are lists now. A timestamp on a button does not say what
is inside that copy, and restoring a ticker backup puts its text on air, so
each entry says how many items it holds and how long ago it was saved; the
configuration backups say the same, with what a restore costs. The listing of
configuration backups had been written three times as an if-expression, which
hands back no files as $null and throws on .Count - on the empty screen. It is
one reader now, covered by a test.

## Version 7.25.0

The authorized users screen is a list again. It was four buttons per person -
the alias three times over - and never the user id, the one thing that ties
someone to their line in the log, to an operation reference, and to the access
request just approved. A tally and one entry per person now sit above the
buttons, numbered to match them, and anyone with no operational name is said
to have none rather than having their id printed twice.

## Version 7.24.0

The pending access requests screen shows what the decision needs: the user and
chat ids, how long ago the request was made, and when it expires on its own.
It used to be a title over buttons carrying a name - a name the requester chose
- while the press granted the ability to put graphics on air. That name is the
one piece of text on the screen a stranger wrote, so it is escaped and capped.

## Version 7.23.0

Restoring every default now asks first, and the question says how many
settings would go back and names the first few - it was the one button that
rewrote all of them on a single tap while every sibling stopped to confirm.
Six destructive buttons that the written colour policy already covered -
clearing either log, revoking access, restarting the bridge, restoring a
config backup, rolling a layer back - are now coloured like the rest.

## Version 7.22.0

The confirmation of a settings change speaks the same language as the screen
it came from: the setting's Arabic name, and what the value was before as well
as after. It used to read "EnableSnapshot = False" - the JSON key and a
PowerShell boolean - and never said what the value had been, so an
administrator who mistapped had nothing to put back. The single-reset button
now asks with both values in the question.

## Version 7.21.0

Setting buttons are names again. A setting with no short label of its own
inherited its description as one, so 77 buttons were whole sentences; each now
has a short name, with the description on the line above it. The list and
search screens say how many settings matched, explain the ones on the page,
and say plainly when a search found nothing instead of showing a bare title
over an empty keyboard.

## Version 7.20.0

Every setting now has a description and every category a summary line, shown
above the buttons they describe - 53 of 134 settings had no explanation at
all, and the ones that did only showed it on a numeric prompt. The release
notes screen gains a button that sends CHANGELOG.md itself. The copy-reference
button now copies the failed operation's reference: the screen prints a
reference beside a failure only, so copying the newest operation handed the
operator eight characters that appeared nowhere on their screen.

## Version 7.19.0

The manual gains a settings chapter - the screen that changes every other
behaviour was the one with no explanation - and the help screens are sent as
HTML. Two rules carry the hierarchy without marking up every line: a line
ending in a colon is a section head, and a word that is the name of a real
setting is set in code so it can be copied into the settings search.

## Version 7.18.1

The release notes screen is sent as HTML: the version number is bold above
its changes and the running build is code-styled, so the eye can tell where
one release ends. Every tag stays inside a single line - the splitter cuts on
line boundaries, and a tag cut in half is a message Telegram refuses.

## Version 7.18.0

The config restore confirmation says what each setting would become, not just
which settings differ: a three-column table of setting, current value, and
the value in the backup. Anything whose name reads like a credential is shown
as its length and a list as a count, because config.json is the one file that
holds the bot token. The old text message stays as the fallback.

## Version 7.17.2

Reference lookup results come back in a monospace block. A log line is
columns held together by spaces, and it is the one thing on these screens a
proportional font actively breaks: id=, action= and result= stop lining up
between rows and the eye loses the column it was following.

## Version 7.17.1

A refused rich message no longer costs the session every rich screen. Only a
404 - the method not existing here - stops all of them, because that is the
one refusal true of every screen. A 400 is blamed on the block types in the
payload that have never rendered before, so adopting a new block risks that
block and nothing else; when every type in it has rendered before, the fault
is that message rather than a capability and nothing is disabled.

## Version 7.17.0

Favourites were losing everything past the first pick: the writer built the
list with `$x = if (...) { @(...) } else { @() }`, an if branch is a pipeline,
a pipeline unrolls a short array, and the `+=` that followed concatenated
strings - two favourites became the single key `urgenttickr`, which names no
template, so every reader filtered it out and the whole selection vanished
with no error anywhere. The management screen also read the capped menu list
to decide its ticks, which made any pick past FavoritesCount impossible to
remove.

Status and full status now carry the operator's own id above the fold, which
is what they are asked for when requesting access or reporting a fault.

The news lock holds up under simultaneous requests: a repeat tap no longer
re-arms the countdown, a hand-over refuses to delete a draft that changed
hands while the window was open, and the freed slot is held for the granted
requester instead of going to whoever taps first. Both sheet pulls now sit
inside the lock - they rewrite the ticker like any other edit, so they are
neither drawn nor honoured for anyone who is not the current writer.

## Version 7.16.0

The reorder screen becomes a table - number, headline, length - with the
length column flagging any headline near NewsMaxItemLength, which an editor
previously discovered only when the publish was refused. What is on air sits
folded under the draft rather than behind a preview button, and the publish
confirmation shows the words it would change instead of counting them.

## Version 7.15.0

Withdraws the table-direction changes from 7.14.0 and 7.14.1. Both were
built on a description of what appeared on screen rather than on anything
the documentation says about how Telegram lays a table out, and testing on
the device showed the tables were not reversed to begin with. Tables return
to what 7.13.0 sent.

## Version 7.13.0

Status and full status become blocks: the verdict as a heading, the layers
on air as a table, and the machine detail folded underneath. What is on air
is the one genuinely tabular thing on a status screen and it was a run-on
sentence. Both screens pass their existing lines through rather than
rebuilding them, so the text and the blocks cannot disagree.

## Version 7.12.0

The health centre becomes a table whose state column can be read straight
down, with any fault sorted above the healthy rows - a screen opened because
something broke should not put the break in row six. Both the table and the
lines are built from one set of rows, so they cannot drift into disagreeing
about whether a subsystem is healthy.

## Version 7.11.0

Hiding and exiting now name the banner that came off and quote its copy.
They were recording a layer number and nothing else, so my operations could
say "layer 7 was hidden" but never which strap was on it - the copy was not
being captured at all. The on-air record carries it now, read before the
operation empties the layer. A failed or blocked show records what it would
have said, too.

## Version 7.10.1

My operations was spending five lines on each entry, most of it true of
every row. A successful operation is one line now, the reference appears
only where somebody has to report it, and a tally at the top answers the
question the screen is opened with: did anything I did fail?

## Version 7.10.0

The handover screen opens with what is on air instead of ending on it, keeps
failures in view and folds the general activity away. The banner copy comes
back to its report in a block under the table, having been dropped when the
table narrowed. My operations keeps the three newest open and folds the
rest.

## Version 7.9.0

Redesigns the reports for the day they actually have to survive: an editor
touching the strip ten times. Telegram divides a table's width evenly, so
six columns give each a sixth of a phone screen - the same mistake the news
list fixed in 6.9.3. Four short columns now, with the range the strip moved
through standing in for the trail, and the readings, the working span and
the operators folded into a details block that has the whole width. The
banner table drops to four as well, carrying the layer on the name.

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
| `Manager/BridgeManager/` / `scripts/Build-BridgeManager.ps1` | A third alternative: a WinForms `BridgeManager.exe` with Start/Stop/Restart, a live log view, and a settings editor — for running the bridge without installing a service or opening PowerShell. See "A desktop manager app (BridgeManager.exe)" below. |
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

#### Alternative: a desktop manager app (BridgeManager.exe)

If you'd rather not install a service or open PowerShell at all, build the
included WinForms supervisor once (requires the
[.NET 9 SDK](https://dotnet.microsoft.com/download) on the build machine
only — the published exe is self-contained and needs nothing installed to
run it):

```powershell
.\scripts\Build-BridgeManager.ps1
```

This produces `dist\BridgeManager\BridgeManager.exe`. Run it, point it at
`TelegramBridge.ps1` the first time it asks, and it gives you:

- **Start / Stop / Restart** buttons, plus a tray icon so it keeps
  supervising while minimized.
- **Auto-restart on crash** (checkbox, on by default) — belt-and-suspenders
  if you're not also running it as a service/task. A crash-loop breaker stops
  after 5 restarts that each died within seconds, so a bad token or an
  unreachable engine surfaces instead of hammering Telegram forever.
- **🩺 Hang detection** (checkbox, on by default). A stuck bridge keeps its
  process alive, so watching for exit is not enough. The bridge stamps
  `logs\bridge.liveness` after every poll loop and the manager restarts it if
  that stamp goes stale — 5 minutes by default, changed with
  `HangWatchdogMinutes` in `BridgeManager.settings.json`. It deliberately does
  *not* infer a hang from log silence: a healthy bridge is routinely silent for
  10+ hours overnight. Against an older bridge that publishes no stamp, the
  watchdog says so once and stays out of the way.
- **🔁 Start with Windows** (per-user Run key, no admin rights). The manager
  comes back straight into the tray and starts the bridge with it, so a power
  cut or a Windows update does not leave the bridge stopped until somebody
  notices.
- A **live view of everything the bridge prints** (the same lines that go to
  `logs\bridge.log`), with errors and warnings coloured, a filter box and an
  "errors and warnings only" toggle (Ctrl+F).
- An **⚙ الإعدادات** button to edit the bot token, Air Pro engine
  address/channel, and the chat/user id whitelists — the only `config.json`
  fields *not* already editable live from the bot's own in-chat Settings
  screen. The token is masked; where DPAPI protection is on it is not editable
  here at all (use `scripts\Protect-BridgeSecrets.ps1`). Because the bridge
  owns the four id lists while it runs, editing one of them offers a restart —
  without it the bridge's next save would quietly put its own copy back.
- Its own log of what the *manager* did, in `logs\manager.log`, so "why did it
  restart at 3am" is answerable after the on-screen scrollback is gone.

Do not run this alongside the Scheduled Task or NSSM service — pick one
supervisor, not two. Only one manager runs at a time, machine-wide: a second
launch (including from another Windows session) points at the one already
running rather than starting a rival supervisor.

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
