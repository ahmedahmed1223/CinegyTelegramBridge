#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The release notes an operator reads in «🆕 ما الجديد», held here rather
    than parsed out of CHANGELOG.md: the changelog is written for whoever
    maintains the bridge, and this is written for whoever operates it.

    Split out of Bridge.ShowFlow.ps1, which had grown to 2733 lines by
    accumulating three things that are not the show flow: the release notes,
    the operator manual, and the audited air operation underneath every push.
    Nothing moved between scopes - dot-sourced parts share one.
#>

function Get-WhatsNewSectionsEn {
    <#
        The English half of the release notes, the way Bridge.Help.En.ps1 is
        the English half of the manual.

        The ten newest releases, and deliberately not the whole archive. There
        are 248 of them, written for one Arabic station about screens as they
        were; an English operator opens this screen to learn what changed
        recently, and CHANGELOG.md ships beside the release for anything
        older. Half-translating the archive would be worse than leaving it:
        the page would change language partway down.

        Keep this in step with the Arabic when a release is cut. A test
        requires the versions here to be the newest Arabic ones in the same
        order with the same number of items, and no Arabic letter to survive
        in an English note.
    #>
    return @(
                @{ Version = '8.71.13'; Items = @(
                        '📋 **Paste several stories at once** — 📋 on the urgent board, or several lines typed into "add": one story per line, shown for review first, then added in order with one tap. If a sequence is live, they join its end too.'
                    ) }
                @{ Version = '8.71.12'; Items = @(
                        '🔴 **The red "on air" mark is believed only while it is true** — a story shown alone is marked on air only while its scene is still what the layer holds; a record left over from before a restart, or from a story that left by any road, is dropped instead of shown with a stop button that can only refuse.'
                    ) }
                @{ Version = '8.71.11'; Items = @(
                        '⏹ **No stop button left hanging** — a story shown alone that left air by its timer, by another operator or from outside kept reading "on air" with a stop button that could only refuse. It now goes off the moment the layer does, and open boards remember their message across a restart.'
                    ) }
                @{ Version = '8.71.10'; Items = @(
                        '🔄 **Every open board follows the air** — when the urgent is hidden by another operator, put up by another operator, or dropped from outside the bot, each chat''s board message is redrawn with a line saying so and by whom. Boards that can no longer be edited are left alone; the next open sends a fresh one.'
                    ) }
                @{ Version = '8.71.9'; Items = @(
                        '📍 **The board appears where you are** — opening it from the main menu sends a fresh board at the bottom of the chat; since 8.71.7 it had been editing the old menu message wherever that had scrolled to. Inside the board, buttons still redraw in place.'
                        '✍️ **Adding a story keeps a way back** — the "send the story" prompt now carries a back button and says what to type; a story shown alone answers on the board with its hide button.'
                        '✅ **Show and hide say so** — starting a sequence says which story is up and how many follow; hiding from the board says the urgent is off air. Both on the board message.'
                    ) }
                @{ Version = '8.71.8'; Items = @(
                        '⚡ **No flash of the previous story** — a new urgent came up wearing the previous story''s text for a second or two, then changed. The text is now written to the scene''s postbox before the scene loads, on every show and every line of a sequence.'
                    ) }
                @{ Version = '8.71.7'; Items = @(
                        '🖥 **The urgent board is one screen** — every button on it, and every typed reply (a new story, a replacement text, a number), redraws the board message you are working on instead of sending a new copy. Starting a sequence and its end are said on that same screen. Only if the message can no longer be edited is a fresh one sent, and that one becomes the screen.'
                    ) }
                @{ Version = '8.71.6'; Items = @(
                        '➕ **A story added during a live sequence joins it** — type a new story while the board is on air and it plays after the last one; the board tells you which headline number it became. A hand-picked (selected-only) run does not grow by itself, and the board says so.'
                        '🔢 **The sequence plays in the order you see** — with the "newest" view the table is numbered newest first, and the run now follows that order instead of the stored one.'
                    ) }
                @{ Version = '8.71.5'; Items = @(
                        '📝 **Every story in a sequence now shows its own text** — from the second story on, the scene kept the first story''s words. The board now writes each story through the same channel the first one uses.'
                        '⏹ **Stop, pause, resume and skip answer on the message you pressed** — one line above the board says what happened, and the board redraws in place instead of sending a new copy.'
                    ) }
                @{ Version = '8.71.4'; Items = @(
                        '⏱ **The timed button picks its duration** — "⏱ on air for a while" beside "put it on air" now opens the same presets a template''s timed show offers, with the story''s own gap starred and "another duration" for a typed number. The plain button is unchanged, and the "hide a story shown alone" setting from 8.71.2 is gone: in a sequence the gap already decides. The board''s "hides after 1800 s" button is gone too: it only opened the timing screen, where nothing edits it.'
                        '🔁 **A sequence puts its line back** — if the layer goes empty in the middle of a run, the board re-shows the current story once and carries on; only if the same story is cleared again does the run stop and raise the external-change alarm.'
                        '⏱ **The gap button now says "auto-hide"** — same button, same number: in a sequence a story stays for its gap and is then hidden.'
                    ) }
                @{ Version = '8.71.3'; Items = @(
                        '⏱ **Two buttons to put a story on air** — on a story''s screen, beside "put it on air", a "⏱ on air for N s" button. The plain one stays up until you hide it, as before; the timed one goes off by itself after the board''s "hide a story shown alone" time, or the bridge''s default hide time when the board has none. The review and the live message say which you chose.'
                        '👤 **Manual or sequence is yours, not the chat''s** — the urgent board remembers your choice by who you are, keeps it across a restart, and writes a log line each time it changes.'
                    ) }
                @{ Version = '8.71.2'; Items = @(
                        '⏱ **A story shown alone can hide itself** — in urgent management, under the board timings: "hide a story shown alone after". Set it once and every single story shown by hand goes off air by itself after that many seconds; the confirmation and the live message both say when. Zero keeps today''s behaviour: only the hide button.'
                    ) }
                @{ Version = '8.71.1'; Items = @(
                        '🔄 **Refresh stays on one message** — when a table screen could not be edited in place and came as a new message, the next screen in that chat kept chasing the old one and arrived as a duplicate. It now redraws the new one.'
                        '🔍 **Who cleared the graphic** — when a template leaves air from outside the bot, the log now quotes Cinegy''s own words: the connected client and the item that took the layer.'
                        '💾 **A shelf that could not be saved says so** — pausing a headline or saving a ticker set now leaves a warning in the log if the file could not be written, instead of vanishing after a restart.'
                    ) }
                @{ Version = '8.71.0'; Items = @(
                        '🗂 **Saved ticker sets** — 🗂 on the news screen: save your draft under a name (a normal ticker, an election one) and load it back into a draft later. Loading changes only your draft; nothing reaches air until you publish. Up to 20 sets; a set is deleted, after a confirmation, only by whoever saved it or an administrator.'
                    ) }
                @{ Version = '8.70.9'; Items = @(
                        '📅 **Publish the ticker at a set time** — 📅 on your draft: type 18:00 or a full date, or pick in 15, 30 or 60 minutes. The draft stays editable until then, and whatever it holds is published, exactly as the publish button would. If the ticker on air changed meanwhile, nothing is overwritten: you are told and the draft is kept.'
                    ) }
                @{ Version = '8.70.8'; Items = @(
                        '📊 **The ticker and the programme boards show a table**, as the bulletin does — number and headline (and 🆕 or on air on your draft); number, the first two fields and ✅/🚫 on a board. Where tables are not available the screen reads as before.'
                    ) }
                @{ Version = '8.70.7'; Items = @(
                        '📋 **Paste many bulletin rows at once** — 📋 Paste rows beside ➕ Add row: one per line, title | story, or the story alone. They take the picture on screen; change it per row afterwards.'
                        '🔍 **A paste is reviewed before it is added, on boards and the bulletin as on the ticker** — how many rows, the first few, what was skipped. Nothing is added until you press Add, and a long paste Telegram splits into several messages joins one batch.'
                    ) }
                @{ Version = '8.70.6'; Items = @(
                        '⏸ **Pause a headline instead of deleting it** — on a headline''s own screen. It leaves the draft, is kept on a ⏸ Paused shelf that outlives publishing, and comes back into the draft with one tap.'
                        '⏸ **Sit a bulletin row out of the run** — on the row''s screen. It stays in the table marked ⏸ and is not played; ▶️ brings it back. A picture set on the paused row still reaches the next row that inherits it.'
                    ) }
                @{ Version = '8.70.5'; Items = @(
                        '🧹 **Bulletin rows and programme boards are cleaned like the ticker** — invisible direction marks that reorder words on air, zero-width characters and soft hyphens are dropped from what you type or paste. Line breaks inside a bulletin story stay, and emoji stay whole.'
                    ) }
                @{ Version = '8.70.4'; Items = @(
                        '📑 **The bulletin screen updates in place** — moving, deleting, paging, sync and fit-to-loop redraw the same message instead of sending a new copy each time.'
                        '📚 **Fixed: the bulletin library''s next page opened the selected bulletin** instead of the library''s second page.'
                    ) }
                @{ Version = '8.70.3'; Items = @(
                        '🔄 **Every Refresh button now updates the message it is on**, on every screen, instead of sending a new copy. An unchanged screen stays as it is rather than being sent again.'
                    ) }
                @{ Version = '8.70.2'; Items = @(
                        '🚨 **Fixed: a graphic left on air all night raised no alarm.** An urgent stayed up eleven hours with the one-hour alert set. Every graphic from this station goes to Cinegy as "until stopped", and the alert took that as "meant to stay". It no longer does; the ticker and the logo, marked long-running, stay quiet as before.'
                        '🗂 **➕ Add row on a programme board takes a paste** — several lines add several rows. It used to keep the first line and drop the rest without saying so.'
                    ) }
                @{ Version = '8.70.1'; Items = @(
                        '✏️ **The news screen shows your draft while you edit it** — what you are about to publish, 🆕 on what is new against the air, and how many live headlines publishing would drop. Others still see the live ticker.'
                        '📤 **Review and publish comes first** on your draft, as ▶️ play does on the bulletin. Long headlines are cut on the screen, and 🔄 refresh redraws the same message instead of sending another.'
                    ) }
                @{ Version = '8.70.0'; Items = @(
                        '🗂 **Settings are sorted into groups** — a large door opens on its groups first (On air: showing and hiding, time on screen, connection, maintenance), then the settings inside the one you pick. Small doors open straight on their settings as before.'
                        '📑 **The bulletin has its own door**, out of On air; **🩺 Cinegy health and connection** has its own, out of Monitoring, which is now 📡 The feed and its watch.'
                        '🔇 **Two hours of quiet moved** beside the quiet hours it overrides: ⚙️ Settings → Notifications → Quiet. Nothing in config.json changed.'
                    ) }
                @{ Version = '8.69.10'; Items = @(
                        '⏱ **Fixed: a custom maximum air time for a template could not be typed.** The ⌨️ custom-amount button answered "the buttons have expired". It now asks for the duration, as 2:30 or 90, and digits typed on an Arabic keyboard are read too.'
                    ) }
                @{ Version = '8.69.9'; Items = @(
                        '🧾 **Fixed: the ticker execution log always said nothing had run.** Only the automatic sheet sync wrote to it, and this station publishes by hand. Every ticker publish is now there — from the draft, pulled from the sheet, or automatic — each named for how it was made.'
                    ) }
                @{ Version = '8.69.8'; Items = @(
                        '📋 **Paste several headlines at once** — ➕ Add headline now takes one or many, one per line. Several get a review first: how many are new, which are already in the draft, which are too long or have no room. Nothing is added until you press Add, and they go in in the order pasted. A long paste Telegram splits into several messages joins one batch.'
                        '🧹 **Pasted text is cleaned before it reaches the ticker** — list numbers and bullets, the invisible direction marks that reorder words on air, tabs and line breaks inside one headline. Emoji stay whole.'
                    ) }
                @{ Version = '8.69.7'; Items = @(
                        '🛡 **A removal confirmation belongs to the scene you reviewed** — a changed scene, expired request or repeated tap cannot remove a different graphic. Request a new confirmation when prompted.'
                        '👤 **Editing accounts keeps the existing administrator order and shows the effective owner** — saving managed permissions requires applying them through a restart, rather than offering a save that can be overwritten.'
                        '📡 **Unavailable on-air records are marked as unknown** — the last readable record stays visible with its reading time and a warning if the bridge heartbeat is old.'
                        '📊 **Manager reports scroll to every displayed bar and refresh the error count** — chart labels are available to assistive readers, buttons are more readable, and saving keeps the window responsive.'
                    ) }
                @{ Version = '8.69.6'; Items = @(
                        '📴 **When Cinegy takes a graphic off air, the chats that were told it went up are told it came down** — with how long it stayed and a line saying it ended from the Cinegy side, not through the bridge. Before, only a take-down from the bridge was announced.'
                    ) }
                @{ Version = '8.69.5'; Items = @(
                        '📰 **News, bulletin, breaking news and boards are back on a row each**, full width and easier to hit.'
                    ) }
                @{ Version = '8.69.4'; Items = @(
                        '📡 **The feed watch button warns from the menu** — 🔴 while the feed is not arriving, 🖤 while the screen is black. No mark when all is well.'
                        '📰 **The content screens sit two to a row** — news with the bulletin, breaking news with the boards — so the menu is shorter. One-hand mode still gives each its own row.'
                    ) }
                @{ Version = '8.69.3'; Items = @(
                        '🧹 **With nothing on air, 🚨 Hide everything is now 🧹 Clear the layers**, and no longer red. It still clears the same layers — something left from before a restart, or put up from Cinegy — without looking like an alarm. While something is live it stays 🚨 in red.'
                        '⏱ **The timer button no longer shows negative seconds** on an old menu; past its moment it reads ⏱ Timer.'
                    ) }
                @{ Version = '8.69.2'; Items = @(
                        '🏠 **One way home, one name** — every button back to the menu now reads 🏠 Menu; some said ⬅️ Main menu and looked like a different place.'
                        '🧰 **Home from inside the admin tools** — each tools page has 🏠 beside back, so the menu is one tap away, not two.'
                    ) }
                @{ Version = '8.69.1'; Items = @(
                        '🔄 **Refresh on the feed watch updates the same message** instead of sending a new copy each press, so the chat no longer fills with old states.'
                        '📡 **One damaged outage record no longer hides the screen** — it is skipped, and the rest of the history shows.'
                    ) }
                @{ Version = '8.69.0'; Items = @(
                        '🎬 **A clip from air** — beside 📸. 📸 says what is on screen; 🎬 says what it is doing: seconds of the channel output, sent as video. The length is a setting (8s), and it is copied rather than re-encoded, so playout pays nothing.'
                        '📺 **Watch the feed inside Telegram** — a button opens a page playing the channel output without leaving the app, handed the same link the monitor watches. Hidden until the page is hosted and its address set in ⚙️.'
                        '⚠️ **The stream server sends its CORS header twice**, so iPhone plays and Android and Desktop are blocked. The page names the cause. Easiest fix: host it on the stream server itself.'
                    ) }
                @{ Version = '8.68.0'; Items = @(
                        '📡 **A new button: the feed watch** — is the feed arriving and since when, the source and the cycle behind it, and the last day''s outages with their lengths, with 📸 a snapshot beside them. Refresh grabs one frame to measure; nothing is sent to Cinegy.'
                        '🔔 **Fixed: you were never told your own graphic had left the air.** The external-change alert went to the administrators alone. You now get your own line — what left, from which layer, and whether something took it or the layer simply emptied.'
                        '📉 **And outages are recorded now**, so "how long was the feed gone last night" survives a restart. It had lived in a counter the next success reset.'
                    ) }
                @{ Version = '8.67.0'; Items = @(
                        '🌐 **The conversion is finished: every screen the bot draws speaks both languages.** 3023 texts in one catalogue, each with both, and a test that requires it of every key. What stayed Arabic stayed on purpose: the words you type, the Arabic machinery in the headline checker, and the release archive.'
                        '🆕 **The what''s-new screen has an English half** — the ten newest releases. A test fails the gate if a release is cut in Arabic and forgotten in English.'
                        '⏱ **Fixed: durations stayed Arabic on an English screen.** Two counting machines lived here and only one had learned English. They are one now, and the Arabic did not change.'
                    ) }
                @{ Version = '8.66.0'; Items = @(

                        '📖 **The whole manual in English:** seventeen chapters and the quick-start card. A test requires the chapters to be **the same ones, in the same order, for the same readers** in both languages, and no Arabic letter to survive in an English chapter — which is the mistake two parallel files invite.'

                        '⚙️ **The two hundred and eight setting descriptions in both languages** too, which completes the settings area: the sections, their summaries, the labels and the descriptions.'

                        '✅ **The confirmations, the template screens and what is on air:** hide, exit, send, approve, refuse and undo, the timer buttons, the template list with its card and its search, and the days of the week.'

                        '📏 **Still to do:** the administrator screens, the reports, the alerts and the three system screens show in Arabic in both modes until they are converted. None of them shows blank, and none shows a key name.'

                    ) }

                @{ Version = '8.65.0'; Items = @(

                        '⚙️ **Every setting now has a name in both languages:** two hundred and eight of them, so an English screen no longer carries one lone Arabic label in the middle of it. Their sections and summaries came with them.'

                        '🔒 **And a test that stops the Arabic drifting from itself:** the catalogue holds both languages together, so if an Arabic label is edited in its old place alone **the gate fails** and names the setting that drifted — rather than the operator reading one label while the test approves another.'

                    ) }

                @{ Version = '8.64.0'; Items = @(

                        '✅ **Fixed: "an external change in Cinegy" was accusing somebody who was never there:** when your scene ends by itself, the spent Cinegy item stays on the layer **with its id and with no name**. The bridge read the presence of an id alone as proof that a stranger had taken the layer, and said "replaced from outside · an unnamed item · an unidentified outside source" — **while the log line for that very same decision said Cinegy had confirmed the layer hidden**. Two stories from one decision, and the alarming one was the wrong one.'

                        '📝 **And the message now says what actually happened:** "no longer on air" instead of "replaced from outside", with one line beside it: **nothing else is on the layer — the scene ended or was hidden from outside the bot, and no one took it.** No "source" is named for an empty layer, because naming one sends an operator looking for an intruder who never existed.'

                        '🛡 **The real warning has lost nothing:** if a **named** scene genuinely takes the layer, the warning stands as it did, with its name and its source.'

                    ) }

                @{ Version = '8.63.0'; Items = @(

                        '🌐 **The main menu and the settings sections speak both languages:** every button in the menu — from the on-air rows to the undo, the favourites and the eleven sections with their summaries — is drawn from the one text catalogue. A test requires the menu to be drawn in both languages **with the same number of buttons**: a translation changes what a button says, not how many there are.'

                        '🧱 **The translation is resolved when the text is read, not when it is loaded:** the setting names and their sections are built once as the bridge starts, and the language changes while it runs — so they are now translated at the moment they are shown. **Anything not yet translated stays Arabic as it was**, rather than appearing blank or as its key, so the translation fills up one setting at a time without breaking anything.'

                        '📏 **Where it stands:** 134 keys in the catalogue, and converted so far: the main menu, the settings screen and its sections, hide-all, the refusal messages, and "content boards" in full. Some 4200 Arabic lines remain in the other files — the work goes on.'

                    ) }

                @{ Version = '8.62.0'; Items = @(

                        '🛠 **Fixed: "content boards" failed on the first press:** your report. The template was read through a cache created inside the function itself by a line that **could never run**: it read the variable before anything had been assigned to it, and that alone throws. So the function was already broken on any station where the bulletin screens had never been opened — and the programme boards were the first to call it, so the first to fall. It is now declared at load.'

                        '🌐 **English — the foundation:** one setting for the whole bridge (**⚙️ Settings ← 🌐 English**) switches the language at once for everyone. A text catalogue holds both languages side by side, and a test requires every key to carry both of them in full with the same placeholders. Converted so far: the main settings menu, hide-all, the refusal messages, and "content boards" in full. **Anything not yet converted shows in Arabic in both modes** — and the conversion goes on.'

                        '📖 **A full English guide in the repository** (`docs/GUIDE.md`): installation, setup, rights, the four systems, scheduling and diagnosis.'

                    ) }

                @{ Version = '8.61.0'; Items = @(

                        '📐 **"Content boards" now says which template it is built on:** every board is **built on a template you choose**, and the template is what decides the fields of each row and the layer it goes out on. The screens used to say "fields: 2" without saying what they were. Now the template picker explains what the choice means and numbers the two steps (choose the template ← name the board), and the board''s own heading gives the template, the layer and **the field names**, and says plainly that the template cannot be changed after the board is made — another programme gets another board.'

                        '🛡 **The "who fills the board" button actually exists now:** the manual described it and the right was stored and honoured in the code, but **there was no screen that set it** — so a board created open stayed open for ever. It is now a button that cycles through everyone, the administrators and the owner, shows which one is set, and records the change in 📜 the log.'

                        '📖 **A "🗂 Content boards" chapter in the manual** explains the two steps and where its settings live.'

                    ) }

                @{ Version = '8.60.0'; Items = @(

                        '🚨🗂 **The urgent board and content boards each got their own settings section:** they had lived inside "📰 News ticker" because they were born from it, not because they belong to it, until that one section carried three systems and thirty-four settings. **And somebody looking for the urgent board''s timing does not think to open a section called News ticker** — which is how "the gap between headlines" stayed lost until release 8.57.0. There are eleven sections now, and the news ticker is the news ticker again. No setting changed and no value changed; what changed is where you look for it.'

                    ) }

                @{ Version = '8.59.0'; Items = @(

                        '🚨 **"Hide all" now honours a layer''s protection in front of an operator:** the emergency button was the only one that skipped the question "whose layer is this?", so a layer the ordinary hide button refuses to let an operator touch came down from here. Now what they hold the right to is hidden, and what they do not **is named to them with its reason** — not listed under "failed" beside a Cinegy fault, because those are two different pieces of news. **An administrator — and the owner with them — hides everything as before, the logo and the ticker and every sensitive or long-running template included**: that is exactly what the button exists for, and an emergency a rule can overrule is not an emergency.'

                    ) }

                @{ Version = '8.58.0'; Items = @(

                        '🗂 **Content boards — a table of ready text for each programme:** a new door in the main menu lets whoever prepares a programme write the whole episode''s text into a table in advance, so at air time the operator has nothing left to do but press the row they want. An administrator creates the board and chooses a template for it, and the fields come from the scene itself — they are neither typed by hand nor invented.'

                        '✍️ **Row by row, or one paste:** add a row and fill its fields, or paste the prepared text in one go, a line per row with the fields separated by `|`. Whatever the paste will not accept is named with its reason and its line number, never swallowed in silence.'

                        '🎛 **Rows managed like the urgent board:** reordered with arrows, a row disabled without losing what was written in it (ten were prepared and today six are needed), deleted, or any field edited — then ▶️ to show it and ⏹ to hide it.'

                        '🛡 **Who fills a board is set per board:** everyone, the administrators, or the owner alone. And if the scene is recut in Titler and a field disappears, the prepared text stays saved and is not sent, and the screen says the field is no longer there rather than quietly ruining the work.'

                    ) }

                @{ Version = '8.57.0'; Items = @(

                        '⏳ **The gap between headlines is where it belongs:** the "gap between headlines" button moved to **⚙️ Board timings** inside the urgent management, beside the gap, the repeat and the total duration — it had been in the general settings screen alone, far from the board it governs. It is set by pressing rather than typing, and 0 now reads "the scene''s own motion" rather than "zero seconds".'

                    ) }
    )
}

function Get-WhatsNewSections {
    <#
        Operator-facing release notes, held here rather than parsed out of
        CHANGELOG.md on purpose: the changelog is written for whoever
        maintains the bridge and is full of function names, while an operator
        needs to know what changed on their screen and what to do
        differently. Keep the newest release first, keep it short, and only
        mention things an operator can see or act on.

        On an English bridge this hands over to Get-WhatsNewSectionsEn, which
        carries the ten newest releases. Same shape, same screen, one half of
        a pair - the manual is built this way too.
    #>
    if ((Get-BridgeLanguage) -eq 'en') { return @(Get-WhatsNewSectionsEn) }
    return @(
                @{ Version = '8.71.13'; Items = @(
                        '📋 **لصق عدة أخبار دفعة واحدة** — «📋 لصق» في جدول العواجل، أو عدة أسطر تكتبها في «إضافة»: خبر في كل سطر، تُعرض للمراجعة أولًا ثم تُضاف بترتيبها بضغطة واحدة. وإن كان تتابع حيًّا التحقت بنهايته.'
                    ) }
                @{ Version = '8.71.12'; Items = @(
                        '🔴 **العلامة الحمراء «على الهواء» تُصدَّق ما دامت صادقة فقط** — الخبر المعروض وحده يُعلَّم على الهواء ما دام مشهده هو ما تحمله الطبقة؛ وسجل بقي من قبل إعادة التشغيل أو من خبر خرج بأي طريق يُسقَط بدل أن يُعرض بزرّ إيقاف لا يفعل إلا الرفض.'
                    ) }
                @{ Version = '8.71.11'; Items = @(
                        '⏹ **لا زرّ إيقاف معلّقًا** — الخبر المعروض وحده الذي خرج بمؤقّته أو بيد مشغّل آخر أو من الخارج كان يبقى «على الهواء» بزرّ إيقاف لا يفعل إلا الرفض. صار يخرج لحظة تخرج الطبقة، والجداول المفتوحة تتذكّر رسالتها بعد إعادة التشغيل.'
                    ) }
                @{ Version = '8.71.10'; Items = @(
                        '🔄 **كل جدول مفتوح يتبع الهواء** — حين يُخفي العاجلَ مشغّلٌ آخر، أو يرفعه مشغّل آخر، أو يسقط من خارج البوت، تُعاد رسم رسالة الجدول في كل محادثة مع سطر يقول ما حدث ومن فعله. الجداول التي تعذّر تعديلها تُترك، والفتح التالي يرسل جديدًا.'
                    ) }
                @{ Version = '8.71.9'; Items = @(
                        '📍 **الجدول يظهر حيث أنت** — فتحه من القائمة الرئيسية يرسل جدولًا جديدًا في أسفل المحادثة؛ منذ 8.71.7 كان يعدّل رسالة القائمة القديمة حيثما صعدت. وداخل الجدول تبقى الأزرار تعيد الرسم في مكانها.'
                        '✍️ **إضافة خبر تحتفظ بطريق العودة** — طلب «أرسل نصّ العاجل» صار يحمل زرّ رجوع ويقول ما تكتب؛ والخبر المعروض وحده يجيب على الجدول بزرّ إخفائه.'
                        '✅ **العرض والإخفاء يقولان ذلك** — بدء التتابع يقول أيّ خبر على الهواء وكم يليه؛ والإخفاء من الجدول يقول إن العاجل خرج عن الهواء. كلاهما على رسالة الجدول.'
                    ) }
                @{ Version = '8.71.8'; Items = @(
                        '⚡ **لا ومضة للخبر السابق** — كان العاجل الجديد يظهر بنصّ الخبر السابق ثانية أو اثنتين ثم يتغيّر. صار النصّ يُكتب في postbox المشهد قبل تحميل المشهد، في كل عرض وكل سطر من التتابع.'
                    ) }
                @{ Version = '8.71.7'; Items = @(
                        '🖥 **شاشة العواجل شاشة واحدة** — كل زرّ فيها، وكل ردّ تكتبه (خبر جديد، نصّ بديل، رقم)، يعيد رسم رسالة الجدول التي تعمل عليها بدل رسالة جديدة. بدء التتابع ونهايته يُقالان على الشاشة نفسها. ولا تُرسل رسالة جديدة إلا إن تعذّر تعديل القديمة، فتصير هي الشاشة.'
                    ) }
                @{ Version = '8.71.6'; Items = @(
                        '➕ **خبر يُضاف والتتابع حيّ يلتحق به** — اكتب خبرًا جديدًا والجدول على الهواء فيُعرض بعد آخر خبر، ويقول لك الجدول رقمه في التتابع. التشغيل على المحدد فقط لا يكبر وحده، ويقول الجدول ذلك.'
                        '🔢 **التتابع يعرض بالترتيب الذي تراه** — في عرض «الأحدث» يُرقَّم الجدول من الأحدث، وصار التشغيل يتبع هذا الترتيب لا الترتيب المخزّن.'
                    ) }
                @{ Version = '8.71.5'; Items = @(
                        '📝 **كل خبر في التتابع يعرض نصّه هو** — من الخبر الثاني فصاعدًا كان المشهد يحتفظ بكلمات الخبر الأول. صار الجدول يكتب كل خبر عبر القناة نفسها التي يستعملها الخبر الأول.'
                        '⏹ **الإيقاف والإيقاف المؤقت والاستئناف والتخطي تجيب على الرسالة التي ضغطتها** — سطر فوق الجدول يقول ما حدث، والجدول يُعاد رسمه في مكانه بدل رسالة جديدة.'
                    ) }
                @{ Version = '8.71.4'; Items = @(
                        '⏱ **زرّ التشغيل المؤقت يختار مدته** — «⏱ تشغيل مؤقت» بجانب «تشغيل على الهواء» يفتح الآن المدد نفسها التي يعرضها التشغيل المؤقت للقالب، وفاصل الخبر نفسه عليه نجمة، و«مدة أخرى» لرقم تكتبه. الزرّ العادي كما هو، وأُزيل إعداد «إخفاء الخبر الواحد» من توقيتات الجدول: في التتابع الفاصل هو الذي يقرّر. وأُزيل من شاشة الجدول زرّ «يُخفى تلقائيًا بعد 1800 ث»: كان يفتح شاشة التوقيتات حيث لا شيء يعدّله.'
                        '🔁 **التتابع يعيد سطره** — إن فرغت الطبقة في منتصف التشغيل، يعيد الجدول الخبر الحالي مرة واحدة ويكمل؛ ولا يتوقف ويرفع إنذار التغيير الخارجي إلا إن فُرّغ الخبر نفسه مرة ثانية.'
                        '⏱ **زرّ الفاصل صار «الإخفاء التلقائي»** — الزرّ نفسه والرقم نفسه: في التتابع يبقى الخبر بقدر فاصله ثم يُخفى.'
                    ) }
                @{ Version = '8.71.3'; Items = @(
                        '⏱ **زرّان لرفع الخبر** — في شاشة الخبر، بجانب «تشغيل على الهواء»، زرّ «⏱ تشغيل مؤقت N ث». الأول يبقى حتى تخفيه كما كان، والثاني يخرج وحده بعد مدة «إخفاء الخبر الواحد» من توقيتات الجدول، أو مدة الإخفاء الافتراضية في الجسر إن لم يُضبط الجدول. شاشة المراجعة ورسالة «عُرض» تقولان أيّهما اخترت.'
                        '👤 **يدوي أو تتابع: اختيارك أنت لا اختيار المحادثة** — جدول العواجل يتذكّر اختيارك باسمك، ويبقيه بعد إعادة التشغيل، ويكتب سطرًا في السجلّ كلّما تغيّر.'
                    ) }
                @{ Version = '8.71.2'; Items = @(
                        '⏱ **الخبر المعروض وحده يخفي نفسه** — في إدارة العواجل، بين توقيتات الجدول: «إخفاء الخبر الواحد بعد». اضبطه مرة، وكل خبر يُعرض يدويًا وحده يخرج من الهواء بنفسه بعد هذه الثواني، وتذكر شاشة التأكيد ورسالة «عُرض» متى. الصفر يبقي ما كان: الإخفاء بالزر فقط.'
                    ) }
                @{ Version = '8.71.1'; Items = @(
                        '🔄 **التحديث يبقى على رسالة واحدة** — حين تعذّر تعديل شاشة جدول في مكانها وجاءت رسالةً جديدة، كانت الشاشة التالية في المحادثة نفسها تطارد الرسالة القديمة فتصل نسخةً مكرّرة. صارت تُعاد على الجديدة.'
                        '🔍 **من أزال القالب** — حين يخرج قالب من الهواء من خارج البوت، يقتبس السجلّ كلام Cinegy نفسه: العميل المتصل والعنصر الذي أخذ الطبقة.'
                        '💾 **رفّ لم يُحفظ يقول ذلك** — إيقاف خبر أو حفظ مجموعة شريط يترك الآن تحذيرًا في السجلّ إن تعذّرت كتابة الملف، بدل أن يختفي بعد إعادة التشغيل.'
                    ) }
                @{ Version = '8.71.0'; Items = @(
                        '🗂 **مجموعات الشريط المحفوظة** — «🗂» في شاشة الأخبار: احفظ مسودتك باسم (شريط عادي، شريط انتخابات) وحمّلها في مسودة لاحقًا. التحميل يغيّر مسودتك وحدها، ولا يصل شيء إلى الهواء حتى تنشر. حتى 20 مجموعة، ولا يحذف المجموعة — بعد تأكيد — إلا من حفظها أو مشرف.'
                    ) }
                @{ Version = '8.70.9'; Items = @(
                        '📅 **انشر الشريط في وقت محدّد** — «📅» في مسودتك: اكتب 18:00 أو تاريخًا كاملًا، أو اختر بعد 15 أو 30 أو 60 دقيقة. تبقى المسودة قابلة للتعديل حتى موعدها، ويُنشر ما فيها كما يفعل زرّ النشر تمامًا. وإن تغيّر الشريط على الهواء في الأثناء لا يُكتب فوقه شيء: تُبلَّغ وتبقى المسودة.'
                    ) }
                @{ Version = '8.70.8'; Items = @(
                        '📊 **شريط الأخبار وجداول البرامج تُعرض جدولًا** كما يُعرض الموجز — الرقم والخبر (ومعه 🆕 أو «على الهواء» في مسودتك)؛ والرقم وأول حقلين و✅/🚫 في جدول البرامج. وحيث لا تتاح الجداول تبقى الشاشة كما كانت.'
                    ) }
                @{ Version = '8.70.7'; Items = @(
                        '📋 **الصق عدّة صفوف في الموجز دفعة واحدة** — «📋 لصق صفوف» بجوار «➕ إضافة صفّ»: صفّ في كل سطر، العنوان | القصة، أو القصة وحدها. تأخذ الصورة التي على الشاشة، وتغيّرها لكل صفّ بعد ذلك.'
                        '🔍 **اللصق يُراجَع قبل الإضافة في البرامج والموجز كما في الشريط** — كم صفًّا، وأوّلها، وما تُخطّي. لا يُضاف شيء حتى تضغط «أضف»، واللصق الطويل الذي يقسمه تيليجرام إلى عدّة رسائل يُجمع في دفعة واحدة.'
                    ) }
                @{ Version = '8.70.6'; Items = @(
                        '⏸ **أوقف خبرًا مؤقتًا بدل حذفه** — من شاشة الخبر نفسه. يخرج من المسودة ويُحفظ في «⏸ الموقوفة» التي تبقى بعد النشر، ويعود إلى المسودة بضغطة.'
                        '⏸ **تخطَّ صفًّا في الموجز** — من شاشة الصفّ. يبقى في الجدول مُعلَّمًا بـ⏸ ولا يُعرض، و▶️ يعيده. والصورة التي على الصفّ المتخطّى تصل الصفّ التالي الذي يرثها.'
                    ) }
                @{ Version = '8.70.5'; Items = @(
                        '🧹 **صفوف الموجز وجداول البرامج تُنظَّف كما يُنظَّف الشريط** — تُحذف مما تكتبه أو تلصقه علامات الاتجاه الخفية التي تقلب ترتيب الكلمات على الهواء، والمحارف الصفرية، والواصلات الناعمة. وتبقى الأسطر داخل قصة الموجز، وتبقى الرموز التعبيرية سليمة.'
                    ) }
                @{ Version = '8.70.4'; Items = @(
                        '📑 **شاشة الموجز تُحدَّث في مكانها** — التحريك والحذف والتقليب والمزامنة ومطابقة الحلقة تعيد رسم الرسالة نفسها بدل إرسال نسخة جديدة كل مرّة.'
                        '📚 **إصلاح: الصفحة التالية في مكتبة الموجزات كانت تفتح الموجز المختار** بدل الصفحة الثانية من المكتبة.'
                    ) }
                @{ Version = '8.70.3'; Items = @(
                        '🔄 **كل زرّ «تحديث» صار يحدّث الرسالة التي هو فيها**، في كل الشاشات، بدل إرسال نسخة جديدة. والشاشة التي لم يتغيّر فيها شيء تبقى كما هي ولا تُرسل مرّة أخرى.'
                    ) }
                @{ Version = '8.70.2'; Items = @(
                        '🚨 **إصلاح: رسمٌ بقي على الهواء طوال الليل دون تنبيه.** عاجلٌ بقي إحدى عشرة ساعة والتنبيه مضبوط على ساعة. كل رسم من هذه المحطة يصل Cinegy «حتى الإيقاف»، والتنبيه كان يفهم ذلك «مقصودًا أن يبقى». لم يعد كذلك؛ والشريط والشعار، المعلَّمان «طويلا البقاء»، يبقيان بلا تنبيه كما كانا.'
                        '🗂 **«➕ إضافة صفّ» في جداول البرامج يقبل اللصق** — عدّة أسطر تضيف عدّة صفوف. كان يأخذ السطر الأول ويُسقط الباقي دون أن يقول.'
                    ) }
                @{ Version = '8.70.1'; Items = @(
                        '✏️ **شاشة الأخبار تعرض مسودتك وأنت تحرّرها** — ما ستنشره، مع 🆕 على الجديد مقارنةً بالهواء، وكم خبرًا من الهواء سيحذفه النشر. والآخرون يرون الشريط الحالي كما كان.'
                        '📤 **«مراجعة ونشر» صار أول الأزرار** في مسودتك، كما «▶️ تشغيل» أول أزرار الموجز. والأخبار الطويلة تُقصّ على الشاشة، و🔄 التحديث يعيد رسم الرسالة نفسها بدل إرسال أخرى.'
                    ) }
                @{ Version = '8.70.0'; Items = @(
                        '🗂 **الإعدادات مقسّمة إلى أقسام** — الباب الكبير يُفتح على أقسامه أولًا (الهواء: العرض والإخفاء، مدة الظهور، الاتصال، الصيانة)، ثم على إعدادات القسم الذي تختاره. والأبواب الصغيرة تُفتح على إعداداتها مباشرة كما كانت.'
                        '📑 **للموجز باب خاص** بعد أن كان داخل «التشغيل على الهواء»، و**🩺 صحة Cinegy والاتصال** باب خاص بعد أن كانت داخل «المراقبة» التي صارت 📡 البث ومراقبته.'
                        '🔇 **«هدوء ساعتين» انتقل** بجوار ساعات الهدوء التي يتجاوزها: ⚙️ الإعدادات ← الإشعارات ← الهدوء. ولم يتغيّر شيء في config.json.'
                    ) }
                @{ Version = '8.69.10'; Items = @(
                        '⏱ **إصلاح: لم يكن ممكنًا كتابة مدّة قصوى مخصّصة للقالب.** زرّ «⌨️ مقدار مخصص» كان يردّ بأن الأزرار انتهت صلاحيتها. صار يطلب المدّة، مثل 2:30 أو 90، ويقرأ الأرقام العربية أيضًا (٢:٣٠ أو ٩٠).'
                    ) }
                @{ Version = '8.69.9'; Items = @(
                        '🧾 **إصلاح: سجلّ تنفيذ الشريط كان يقول دائمًا إن شيئًا لم يُنفَّذ.** لم يكن يكتب فيه إلا المزامنة التلقائية مع الشيت، وهذه المحطة تنشر يدويًا. صار كل نشر للشريط فيه — من المسودة، أو سحبًا من الشيت، أو تلقائيًا — ومعه كيف نُشر.'
                    ) }
                @{ Version = '8.69.8'; Items = @(
                        '📋 **لصق عدّة أخبار دفعة واحدة** — «➕ إضافة خبر» يقبل الآن خبرًا أو عدّة أخبار، خبرًا في كل سطر. العدّة تُعرض للمراجعة أولًا: كم منها جديد، وما الموجود في المسودة، وما الأطول من الحد أو لا مكان له. لا يُضاف شيء حتى تضغط «أضف»، وتدخل بترتيب اللصق. واللصق الطويل الذي يقسمه تيليجرام إلى عدّة رسائل يُجمع في دفعة واحدة.'
                        '🧹 **النص الملصوق يُنظَّف قبل أن يصل الشريط** — أرقام القوائم ونقاطها، وعلامات الاتجاه الخفية التي تقلب ترتيب الكلمات على الهواء، والجدولة والأسطر المكسورة داخل الخبر الواحد. والرموز التعبيرية تبقى سليمة.'
                    ) }
                @{ Version = '8.69.7'; Items = @(
                        '🛡 **تأكيد الإزالة يخص المشهد الذي راجعته** — تغيّر المشهد أو انتهاء الطلب أو تكرار الضغط لا يزيل رسمًا آخر. اطلب تأكيدًا جديدًا عند التنبيه.'
                        '👤 **تعديل الحسابات يحافظ على ترتيب المديرين ويعرض المالك الفعلي** — حفظ الصلاحيات التي يديرها الجسر يتطلب تطبيقها بإعادة التشغيل بدل حفظ قد يضيع.'
                        '📡 **تعذّر قراءة سجل الهواء يظهر كحالة غير مؤكدة** — تبقى آخر قراءة سليمة مع وقتها وتنبيه إذا كانت نبضة الجسر قديمة.'
                        '📊 **تقارير المدير تُمرّر إلى جميع الأعمدة المعروضة وتحدّث عداد الأخطاء** — أسماء الرسم وقيمه متاحة لقارئ الشاشة، والأزرار أوضح، ونافذة الحفظ تبقى مستجيبة.'
                    ) }
                @{ Version = '8.69.6'; Items = @(
                        '📴 **حين يُنزل Cinegy رسمًا عن الهواء، تعلم المحادثات التي أُبلغت بظهوره أنه نزل** — ومعه كم بقي، وسطر يقول إنه انتهى من جهة Cinegy لا من الجسر. قبل هذا لم يُعلَن إلا الإنزال من الجسر.'
                    ) }
                @{ Version = '8.69.5'; Items = @(
                        '📰 **الأخبار والموجز والعاجل والبرامج عادت كلٌّ في صفّه**، بعرض كامل وأسهل وصولًا.'
                    ) }
                @{ Version = '8.69.4'; Items = @(
                        '📡 **زرّ مراقبة البثّ ينبّه من القائمة** — 🔴 والبثّ لا يصل، و🖤 والشاشة سوداء. ولا علامة حين يكون كل شيء سليمًا.'
                        '📰 **شاشات المحتوى اثنتان في كل صفّ** — الأخبار مع الموجز، والعاجل مع البرامج — فصارت القائمة أقصر. ووضع اليد الواحدة يُبقي لكلٍّ صفّه.'
                    ) }
                @{ Version = '8.69.3'; Items = @(
                        '🧹 **حين لا شيء على الهواء صار 🚨 «إخفاء الكل» 🧹 «تنظيف الطبقات»** ولم يعد أحمر. ما زال ينظّف الطبقات نفسها — ما بقي من قبل إعادة التشغيل أو ما عُرض من Cinegy — دون أن يبدو إنذارًا. وأثناء العرض يبقى 🚨 بالأحمر.'
                        '⏱ **زرّ المؤقّت لم يعد يعرض ثوانيَ سالبة** في قائمة قديمة؛ بعد موعده يقول «⏱ مؤقت».'
                    ) }
                @{ Version = '8.69.2'; Items = @(
                        '🏠 **طريق واحد إلى القائمة باسم واحد** — كل زرّ يعود إلى القائمة صار «🏠 القائمة»؛ بعضها كان «⬅️ الرئيسية» فبدا مكانًا آخر.'
                        '🧰 **العودة إلى القائمة من داخل أدوات الإدارة** — كل صفحة أدوات فيها 🏠 بجوار «رجوع»، فالقائمة على ضغطة لا ضغطتين.'
                    ) }
                @{ Version = '8.69.1'; Items = @(
                        '🔄 **«تحديث» في مراقبة البثّ يحدّث الرسالة نفسها** بدل إرسال نسخة جديدة مع كل ضغطة، فلا تمتلئ المحادثة بحالات قديمة.'
                        '📡 **سجلّ انقطاع تالف لم يعد يُخفي الشاشة** — يُتجاوَز ويظهر باقي السجلّ.'
                    ) }
                @{ Version = '8.69.0'; Items = @(
                        '🎬 **مقطع من الهواء** — بجوار 📸. 📸 تقول ما على الشاشة، و🎬 تقول ماذا تفعل: ثوانٍ من خرج القناة تصل فيديو. الطول إعداد (٨ ثوانٍ)، ويُنسَخ بلا إعادة ترميز فلا يُثقل جهاز البثّ.'
                        '📺 **شاهد البثّ داخل تيليجرام** — زرّ يفتح صفحة تشغّل خرج القناة دون مغادرة التطبيق، ويصلها الرابط الذي يراقبه المراقب نفسه. لا يظهر حتى تُستضاف الصفحة وتُضبط في ⚙️.'
                        '⚠️ **وخادم البثّ يرسل ترويسة CORS مرّتين**، فيعمل الآيفون ويُحجَب أندرويد وسطح المكتب. الصفحة تسمّي السبب. وأسهل حلّ: ضعها على خادم البثّ نفسه.'
                    ) }
                @{ Version = '8.68.0'; Items = @(
                        '📡 **زرّ جديد: مراقبة البثّ** — هل يصل ومنذ متى، والمصدر ودورة الفحص، وانقطاعات آخر يوم بمُددها، ومعها 📸 لقطة. و«تحديث» يلتقط إطارًا ليقيس عليه، ولا يُرسل شيء إلى Cinegy.'
                        '🔔 **إصلاح: لم تكن تُبلَّغ أن قالبك نزل عن الهواء.** كان التنبيه يذهب للمشرفين وحدهم. صار يصلك سطرُك: ما نزل، وعلى أي طبقة، وهل أخذها شيءٌ أم خلت.'
                        '📉 **والانقطاعات تُسجَّل الآن**، فيبقى جواب «كم غاب البثّ ليلة أمس» بعد إعادة التشغيل. وكان في عدّادٍ يصفّره أوّل نجاح.'
                    ) }
                @{ Version = '8.67.0'; Items = @(
                        '🌐 **انتهى التحويل: كل شاشة يرسمها البوت تتكلّم اللغتين.** ٣٠٢٣ نصًّا في جدول واحد، لكلٍّ لغتاه، واختبار يوجب ذلك على كل مفتاح. وما بقي عربيًّا بقي عن قصد: الكلمات التي تكتبها، وآلة العربية في المدقّق، وأرشيف الإصدارات.'
                        '🆕 **ولسجلّ «ما الجديد» نصفٌ إنجليزي** — أحدث عشرة إصدارات. واختبار يُسقط البوابة إن قُطع إصدارٌ بالعربية ونُسي بالإنجليزية.'
                        '⏱ **إصلاح: المدد كانت تبقى عربية على شاشة إنجليزية.** كان هنا آلتا عدّ، تعلّمت إحداهما الإنجليزية دون الأخرى. صارتا واحدة، والعربية لم تتغيّر.'
                    ) }
                @{ Version = '8.66.0'; Items = @(
                        '📖 **الدليل كلّه بالإنجليزية:** سبعة عشر فصلاً وبطاقة البداية السريعة. واختبار يوجب أن تكون الفصول **نفسها بالترتيب نفسه وللجمهور نفسه** في اللغتين، وألّا يبقى حرف عربي في فصل إنجليزي — وهذا هو الخطأ الذي يغري به ملفّان متوازيان.'
                        '⚙️ **أوصاف الإعدادات المائتان والثمانية باللغتين** أيضًا، فاكتملت منطقة الإعدادات: الأبواب وملخّصاتها والعناوين والأوصاف.'
                        '✅ **التأكيدات وشاشات القوالب وحالة ما على الهواء:** إخفاء وخروج وإرسال وموافقة ورفض وتراجع، وأزرار المؤقّت، وقائمة القوالب وبطاقتها وبحثها، وأيام الأسبوع.'
                        '📏 **ما زال عمل:** شاشات المشرف والتقارير والتنبيهات وشاشات الأنظمة الثلاثة تظهر بالعربية في الوضعين حتى تُحوّل. ولا تظهر فارغة ولا بأسماء مفاتيح.'
                    ) }
                @{ Version = '8.65.0'; Items = @(
                        '⚙️ **كل إعداد صار له اسم باللغتين:** مائتا إعداد وثمانٍ، فلم تعد شاشة إنجليزية تعرض عنوانًا عربيًا وحيدًا في منتصفها. ومعها أبوابها وملخّصاتها.'
                        '🔒 **واختبار يمنع انحراف العربية عن نفسها:** الجدول يحمل اللغتين معًا، فإن عُدّل العنوان العربي في مكانه القديم وحده **سقطت البوابة** وسمّت الإعداد المنحرف — بدل أن يقرأ المشغّل عنوانًا والاختبار يوافق على غيره.'
                    ) }
                @{ Version = '8.64.0'; Items = @(
                        '✅ **إصلاح: «تغيير خارجي في Cinegy» كان يتّهم أحدًا لم يكن هناك:** حين ينتهي مشهدك وحده، يبقى عنصر Cinegy المنتهي على الطبقة **بمعرّفه وبلا اسم**. وكان الجسر يقرأ وجود المعرّف وحده دليلًا على أنّ غريبًا أخذ الطبقة، فيقول «استُبدل خارجيًا · عنصر غير مسمّى · مصدر خارجي غير معرّف» — **في حين أنّ سطر السجلّ للقرار نفسه يقول إنّ Cinegy أكّد أنّ الطبقة مخفية**. حكايتان من قرار واحد، والمخيفة منهما هي الخطأ.'
                        '📝 **والرسالة صارت تقول ما جرى فعلاً:** «لم يعد على الهواء» بدل «استُبدل خارجيًا»، ومعها سطر واحد: **لا عنصر آخر على الطبقة — المشهد انتهى أو أُخفي من خارج البوت، ولم يأخذها أحد.** ولا يُذكر «مصدر» لطبقة فارغة، فذكره يُرسل المشغّل يبحث عن متسلّل لم يوجد.'
                        '🛡 **والبلاغ الحقيقي لم يضعف:** إن أخذ مشهدٌ **مسمّὰً** الطبقة فعلاً، يبقى التحذير كما كان باسمه ومصدره.'
                    ) }
                @{ Version = '8.63.0'; Items = @(
                        '🌐 **القائمة الرئيسية وأبواب الإعدادات صارت تتكلّم اللغتين:** كل زرّ في القائمة — من صفوف ما على الهواء إلى التراجع والمفضّلة والأبواب الأحد عشر وملخّصاتها — يُرسم من جدول النصوص نفسه. واختبار يوجب أن تُرسم القائمة باللغتين **بعدد الأزرار نفسه**: الترجمة تغيّر ما يقوله الزرّ، لا عدد الأزرار.'
                        '🧱 **الترجمة تُحلّ عند القراءة لا عند التحميل:** أسماء الإعدادات وأبوابها تُبنى مرّة واحدة حين يبدأ الجسر، واللغة تتغيّر وهو يعمل — فصارت تُترجم لحظة عرضها. **وما لم يُترجم بعد يبقى عربيًا كما كان** بدل أن يظهر فارغًا أو باسم مفتاحه، فالترجمة تمتلئ إعدادًا إعدادًا بلا كسر شيء.'
                        '📏 **التقدّم:** 134 مفتاحًا في الجدول، والمحوّل حتى الآن: القائمة الرئيسية، وشاشة الإعدادات وأبوابها، وإخفاء الكل، ورسائل رفض الصلاحية، و«محتوى البرامج» كاملاً. وما زال نحو 4200 سطر عربي في الملفات الأخرى — والعمل مستمرّ.'
                    ) }
                @{ Version = '8.62.0'; Items = @(
                        '🛠 **إصلاح: «محتوى البرامج» كان يفشل عند أول ضغطة:** بلاغك. كان القالب يُقرأ عبر ذاكرة مؤقّتة تُنشأ داخل الدالة نفسها بسطرٍ **لا يمكن أن يُنفَّذ**: يقرأ المتغيّر قبل أن يُسند إليه شيء، وهذا وحده يرمي الخطأ. فكانت الدالة معطّلة أصلًا على محطةٍ لم تُفتح فيها شاشات الموجز قطّ — وجداول البرامج أول من ناداها فأول من سقط. صارت تُعلَن عند التحميل.'
                        '🌐 **الإنجليزية — الأساس:** إعداد واحد للجسر كلّه (**⚙️ الإعدادات ← 🌐 English**) يبدّل اللغة فورًا للجميع. جدول نصوص يحمل اللغتين جنبًا إلى جنب، واختبار يوجب أن يحمل كل مفتاح لغتيه كاملتين بالمواضع نفسها. الشاشات المحوَّلة حتى الآن: القائمة الرئيسية للإعدادات، وإخفاء الكل، ورسائل رفض الصلاحية، و«محتوى البرامج» كاملًا. **وما لم يُحوَّل بعد يظهر بالعربية في الوضعين** — والتحويل مستمرّ.'
                        '📖 **دليل شامل بالإنجليزية في المستودع** (`docs/GUIDE.md`): التركيب والإعداد والصلاحيات والأنظمة الأربعة والجدولة والتشخيص.'
                    ) }
                @{ Version = '8.61.0'; Items = @(
                        '📐 **«محتوى البرامج» صار يقول على أي قالب هو مبنيّ:** كل جدول **مبنيّ على قالب تختاره أنت**، والقالب هو الذي يقرّر حقول كل صفّ والطبقة التي يخرج عليها. الشاشات كانت تقول «الحقول: 2» ولا تقول ما هما. الآن: منتقي القوالب يشرح ما يعنيه الاختيار ويُرقّم الخطوتين (اختر القالب ← سمِّ الجدول)، ورأس شاشة الجدول يقول القالب والطبقة و**أسماء الحقول**، ويقول صراحةً إن القالب لا يتغيّر بعد الإنشاء — لبرنامجٍ آخر جدولٌ آخر.'
                        '🛡 **زرّ «من يملأ الجدول» صار موجودًا فعلًا:** الدليل كان يصفه والصلاحية محفوظة ومحترمة في الكود، لكن **لم تكن هناك شاشة تضبطها** — فجدولٌ أُنشئ مفتوحًا يبقى مفتوحًا للأبد. صار زرًّا يدور بين الجميع والمشرفين والمالك ويعرض الحالي عليه، ويُسجَّل تغييره في 📜 السجل.'
                        '📖 **فصل «🗂 محتوى البرامج» في الدليل** يشرح الخطوتين وأين إعداداته.'
                    ) }
                @{ Version = '8.60.0'; Items = @(
                        '🚨🗂 **جدول العواجل ومحتوى البرامج صار لكلٍّ بابه في الإعدادات:** كانا داخل «📰 شريط الأخبار» لأنهما وُلدا منه لا لأنهما منه، حتى حمل الباب ثلاثة أنظمة وأربعة وثلاثين إعدادًا. **ومن يبحث عن توقيت جدول العواجل لا يخطر له أن يفتح بابًا اسمه شريط الأخبار** — وهكذا ضاع «الفاصل بين الأخبار» حتى الإصدار 8.57.0. الأبواب الآن أحد عشر، وشريط الأخبار عاد لشريط الأخبار وحده. لم يتغيّر إعدادٌ ولا قيمته، تغيّر مكان البحث عنه.'
                    ) }
                @{ Version = '8.59.0'; Items = @(
                        '🚨 **«إخفاء الكل» صار يحترم حماية الطبقة أمام المشغّل:** كان زرّ الطوارئ هو الوحيد الذي يتخطّى سؤال «هذه الطبقة لمن؟»، فطبقةٌ يرفض زرّ الإخفاء العادي أن يلمسها المشغّل كانت تُنزَل من هنا. الآن يُخفى ما يملك صلاحيته، وما لا يملكه **يُذكر له باسمه وسببه** — لا يُدرَج تحت «فشلت» بجوار عطلٍ في Cinegy، فهما خبران مختلفان. **والمشرف — ومعه المالك — يُخفي كل شيء كما كان، بما فيه الشعار والشريط وكل قالب حسّاس أو طويل التشغيل**: هذا بالضبط ما وُجد الزرّ من أجله، وطوارئُ تستطيع قاعدةٌ أن تنقضها ليست طوارئ.'
                    ) }
                @{ Version = '8.58.0'; Items = @(
                        '🗂 **محتوى البرامج — جدول نصوص جاهز لكل برنامج:** بابٌ جديد في القائمة الرئيسية يتيح لمعدّ البرنامج أن يكتب نصوص الحلقة كلها مسبقًا في جدول، فلا يبقى على المنفّذ وقت البثّ إلا الضغط على السطر الذي يريد عرضه. المشرف يُنشئ الجدول ويختار له قالبًا، والحقول تأتي من المشهد نفسه — لا تُكتب باليد ولا تُخترع.'
                        '✍️ **الإدخال سطرًا سطرًا أو لصقةً واحدة:** أضف صفًا واملأ حقوله، أو الصق النصوص المجهّزة دفعةً واحدة سطرًا لكل صف والحقول مفصولة بـ `|`. وما لا يُقبل من اللصقة يُذكر بسببه ورقم سطره، لا يُبتلع صامتًا.'
                        '🎛 **إدارة الصفوف كجدول العواجل:** ترتيب بالأسهم، وتعطيل صفٍّ دون حذف ما كُتب فيه (المعدّ جهّز عشرة واليوم يحتاج ستة)، وحذف، وتعديل أي حقل — ثم ▶️ للعرض و⏹ للإخفاء.'
                        '🛡 **من يملأ الجدول يُحدَّد لكل جدول:** الجميع أو المشرفون أو المالك وحده. وإن أُعيد قصّ المشهد في Titler وسقط حقل، يبقى نصّ المعدّ محفوظًا ولا يُرسَل، والشاشة تقول إن الحقل لم يعد موجودًا بدل أن تتلف عمله بصمت.'
                    ) }
                @{ Version = '8.57.0'; Items = @(
                        '⏳ **الفاصل بين الأخبار صار في مكانه:** زرّ «الفاصل بين الأخبار» انتقل إلى **⚙️ توقيتات الجدول** داخل إدارة العواجل، بجوار الفاصل والتكرار والمدة الكلية — كان في شاشة الإعدادات العامة وحدها، بعيدًا عن الجدول الذي يحكمه. ويُضبط بالضغط لا بالكتابة، و0 يظهر «حركة المشهد وحدها» لا «صفر ثانية».'
                    ) }
                @{ Version = '8.56.0'; Items = @(
                        '🏷 **زرّ «العنوان» في العواجل صار يقول الحقيقة:** مشهد العاجل عندنا يحمل حقلًا واحدًا، فالعنوان كان يُحفظ ويظهر في بطاقة الخبر ثم **لا يصل الهواء إطلاقًا** بلا أن يقول أحد. صار الزرّ لا يُعرض على مشهدٍ لا يتّسع له، وإن كان لخبرٍ عنوانٌ مكتوب من قبل فالبطاقة تقول صراحةً إنه لن يظهر — والزرّ يبقى ليمكن مسحه.'
                    ) }
                @{ Version = '8.55.0'; Items = @(
                        '▶ **تشغيل الجسر عند فتح البرنامج:** خيار جديد في قائمة خيارات المدير يبدأ الجسر كلما فتحت البرنامج، لا عند بدء ويندوز وحده. معطّل افتراضيًا، وإن كان الجسر يعمل أصلًا يُتبنّى كما هو.'
                        '🚨 **«الأخطاء والتحذيرات فقط» لم يعد يُخفي إنذارات المدير:** كانت أسطر مثل «فشل بدء التشغيل» و«توقف ٥ مرات متتالية» و«توقف عن النبض» تختفي مع التصفية، فتقرأ اللوحة «لا أخطاء — وهذا هو المطلوب» والجسر متوقف وإعادة التشغيل مطفأة.'
                        '💾 **نافذة الإعدادات لا توقف الجسر حين لا تستطيع الحفظ:** إن تعذّرت قراءة الإعدادات عند الفتح، ترفض النافذة الحفظ وتطلب إعادة فتحها، بدل أن توقف الجسر ثم تفشل.'
                        '⏹ **فشل الإيقاف يظهر بدل أن يُبتلع:** كانت الأزرار الثلاثة تبقى معطّلة بلا رسالة.'
                        '🧹 **لا أسطر مكرّرة في لوحة السجل**، ولا شاشة سوداء فارغة بعد المسح.'
                        '✅ **بوّابة الفحص على GitHub صارت خضراء:** كانت حمراء في كل دفعة منذ أسابيع لأن أربعة اختبارات كانت تقرأ سجلّ قوالب المحطة المحلي بدل الذي يشحنه المستودع.'
                    ) }
                @{ Version = '8.54.0'; Items = @(
                        '📋 **زر النسخ لم يعد يُسقط الرسالة:** نصٌّ أطول من 256 حرفًا كان يجعل Telegram يرفض شاشة التعديل كلها، فلا تظهر — بينما حالة الإدخال مسلّحة، فتُؤخذ رسالتك التالية قيمةً لحقل لم تر سؤاله. صار الزر يُحذف وحده والنص يبقى قابلًا للنسخ باللمس.'
                        '📊 **الشاشات الثرية لا تختفي عند الازدحام:** حين يرفض Telegram شاشة لكثرة الطلبات صارت تصلك نسختها النصية فورًا بدل ألا يصلك شيء.'
                        '👁 **معاينة مسودة الأخبار مصفَّحة:** كانت المسودة الطويلة تصل في رسائل متتابعة وأزرارها في آخرها.'
                        '📖 **الدليل محدَّث:** فاصل العواجل، وحماية الطبقة من الأمر المكتوب، وإخفاء الأسرار في قوائم الإعدادات.'
                    ) }
                @{ Version = '8.53.0'; Items = @(
                        '🔒 **الأسرار لا تُعرض في قوائم الإعدادات:** أي إعداد اسمه يشبه رمزًا أو توكن صار يظهر بطوله لا بنصّه في قوائم الإعدادات وفي مراجعة الاستيراد، فلا يبقى في سجل المحادثة ولا في لقطة شاشة. وشاشة تعديل الإعداد الواحد تُبقي القيمة ظاهرة عمدًا، لأن رمز الانضمام قيمة يحتاج المشرف أن يقرأها ليسلّمها.'
                        '🧹 **سجل طلبات الوصول لم يعد ينمو بلا حدّ:** كانت محاولات الغرباء تُحفظ إلى الأبد ولا يُنظَّف منها إلا ما حُظر فعلًا.'
                        '⚡ **الغريب لم يعد يُبطئ الجسر:** كان اسم كل من يراسل البوت يُحفظ قبل أي فحص صلاحية، ومعه إعادة كتابة كاملة لملف الأسماء. صار يُحفظ لمن له صلاحية فقط.'
                    ) }
                @{ Version = '8.52.0'; Items = @(
                        '🚨 **إصلاح تكرار الخبر الأول في جدول العواجل:** مع «حركة الخروج» كان المشهد يخرج ويعود حاملًا **نصّ الخبر الأول** في كل مرة، فيبدو الجدول عالقًا رغم أن المحرّك يتقدّم. السبب أن الطبقة لم تكن تُنزَل قبل العرض التالي، فيحتفظ المشهد بالقيم التي حُمِّل بها. صار كل خبر يظهر بنصّه.'
                        '⏳ **فاصل بين الأخبار في وضع حركة الخروج:** إعداد جديد «الفاصل بين الأخبار» يترك الشاشة فارغة بين خبر وآخر بالمدة التي تختارها (حتى خمس دقائق، و0 = حركة المشهد وحدها). ويرفع تلقائيًا أقصر فاصل مسموح بالقدر نفسه، فلا يقع موعد الخبر التالي داخل فاصله.'
                    ) }
                @{ Version = '8.51.0'; Items = @(
                        '📡 **تنبيه تذبذب مصدر البث:** المراقبة كانت تنبّه فقط حين يسقط المصدر عدة مرات متتالية، فمصدرٌ يفشل مرة ويعود مرة لم يكن ينبّه أبدًا رغم أن المراقبة لا ترى المخرج نصف الوقت. صار الجسر يبلّغ حين يفشل الالتقاط عددًا من المرات خلال ست ساعات، ولو عاد بينها. يضبطه «حد تنبيه تذبذب المصدر».'
                        '⏹ **الموجز لا يُعلن خروجه قبل أن يخرج:** إن تعذّر تأكيد الخروج من Cinegy، يُجمَّد التشغيل ويُطلب منك إعادة المحاولة، بدل رسالة «خرج عن الهواء» عن مشهد ما زال يعمل.'
                        '📰 **شريط الأخبار يعود بعد إعادة التشغيل:** كان وعد إرجاع الشريط يضيع إن أُعيد تشغيل الجسر أثناء موجز، فيبقى الشريط خارج الهواء بلا عودة.'
                        '⏱ **مواعيد الموجز وعودة الشريط في وقتها:** كانا يتأخران حتى نصف دقيقة عن موعدهما.'
                        '🔕 **كتم الإشعارات يبقى بعد إعادة التشغيل:** كان يُفقد صامتًا فتعود المقاطعة دون أن تعرف.'
                    ) }
                @{ Version = '8.50.0'; Items = @(
                        '🔒 **حماية الطبقات صارت تشمل الأوامر المكتوبة:** كان زرّ الإخفاء يرفض طبقة محمية بينما يكتب أحدهم `/اخفاء 9` فتخرج الطبقة من الهواء. صار المكتوب يمرّ بالفحص نفسه الذي يمرّ به الزرّ، ويظهر السبب نفسه عند الرفض. مؤقّت الإخفاء التلقائي وإخفاء الكل يعملان كما كانا.'
                        '📺 **عرض جديد على طبقة الموجز يوقف الموجز:** كان الموجز يواصل العمل خلف رسم آخر حلّ مكانه، ثم يخرج من الطبقة في موعده فيسحب الرسم الجديد عن الهواء بعد دقائق. صار العرض الجديد يُنهي الموجز أو لوحة العواجل التي كانت تشغّل الطبقة.'
                    ) }
                @{ Version = '8.49.11'; Items = @(
                        '🔔 **تنبيه نشر شريط الأخبار:** أصبح بالإمكان تنبيه المشرفين تلقائيًا عند النشر اليدوي، والإعداد الافتراضي يرسل التنبيه للمشرفين إلى جانب نتيجة النشر التي يراها الناشر.'
                    ) }
                @{ Version = '8.49.10'; Items = @(
                        '🔔 **استئناف شريط الأخبار:** إصلاح تأكيد زر استئناف المسودة المنتهية حتى لا يظهر خطأ Telegram بسبب إرسال التأكيد مرتين.'
                    ) }
                @{ Version = '8.49.9'; Items = @(
                        '🛠️ **تثبيت إدارة العواجل:** الضغط على الفاصل لا يرسل تأكيدًا مكررًا، واختيار خبر من قائمة مفلترة يعيد الشاشة إلى الصفحة الصحيحة بدل الانتقال إلى صفحة أخرى.'
                    ) }
                @{ Version = '8.49.8'; Items = @(
                        '🧭 **فواصل أوضح في إدارة العواجل:** أضيف فاصل مرئي بين أدوات التصفية وباقي أوامر الجدول، وفاصل آخر قبل صفوف الأخبار، من دون إضافة أزرار تشغيل حقيقية.'
                    ) }
                @{ Version = '8.49.7'; Items = @(
                        '🩺 **حالة أوضح:** صار ملخص الاستخدام يقسم الإعدادات المعدّلة إلى قائمة مقروءة، وأصلحنا لوحة ما بعد العرض حتى لا تظهر أزرارها في صفوف غير صالحة.'
                    ) }
                @{ Version = '8.49.6'; Items = @(
                        '🚨 **تشغيل الخبر المحدد:** أزرار «قراءة» و«إجراءات» عادت إلى الشكل الافتراضي، ويظهر للخبر المحدد زر تشغيل مباشر على الهواء.'
                    ) }
                @{ Version = '8.49.5'; Items = @(
                        '🔎 **تصفية أوضح:** أضيف عنوان مستقل فوق أزرار تصفية العواجل لفصلها بصريًا عن ملخص الحالة وأوامر التشغيل.'
                    ) }
                @{ Version = '8.49.4'; Items = @(
                        '🛡️ **إيقاف العاجل:** زر الإيقاف من إدارة العواجل يعمل الآن أيضًا مع الخبر الذي عُرض يدويًا، وفرز «الأحدث» يتعامل بأمان مع تاريخ تعديل غير صالح.'
                    ) }
                @{ Version = '8.49.3'; Items = @(
                        '🚨 **إدارة العواجل:** ملخص حالة وفلاتر للكل والجاهز وعلى الهواء والمحدد والمعطّل والأحدث، مع وقت آخر تعديل وأزرار تشغيل التالي وإيقاف الحالي.'
                    ) }
                @{ Version = '8.49.2'; Items = @(
                        '🎨 **تمييز أخبار العواجل** — لكل خبر علامة حالة واضحة، وتظهر القراءة والإجراءات بلون موحّد، بينما يظل التشغيل والحذف مميّزين بصريًا.'
                    ) }
                @{ Version = '8.49.1'; Items = @(
                        '📡 **حالة الاتصال عند التشغيل** — تظهر الحالة كـ ⏳ حتى يكتمل أول فحص، بدل عرض ❌ قبل معرفة النتيجة.'
                        '↩️ **مكان إعادة العرض** — زر إعادة عرض آخر قالب مخفي أصبح في صف أدوات «على الهواء» بدل تكراره بجانب كل طبقة.'
                        '🚨 **تشغيل خبر العاجل** — شاشة الخبر في إدارة العواجل تعرض زر «تشغيل على الهواء» وتمرره عبر التأكيد وفحوص الصلاحية قبل البث.'
                    ) }
                @{ Version = '8.49.0'; Items = @(
                        '⌨️ **مقدار مخصص للمدة** — زر «مقدار مخصص» في شاشة الحد الأقصى لكل قالب يسمح بإدخال مدة حرة بصيغة «دقائق:ثوانٍ» (مثل 2:30) أو ثوانٍ فقط (مثل 90).'
                        '⏱ **أزرار تمديد/تقصير سريعة** — أزرار +30ث، +1د، -30ث، -1د تظهر في شاشة «بعد العرض» لتعديل المؤقت دون العودة للقوائم.'
                        '📊 **وقت متبقٍ في التنبيه** — رسالة التنبيه الشخصي تُظهر الآن الوقت المتبقي قبل الإخفاء التلقائي.'
                        '↩️ **تحديث إعادة العرض** — زر إعادة عرض آخر قالب أُخفِي أصبح يظهر فقط عندما يوجد قالب سابق فعلي.'
                    ) }
                @{ Version = '8.48.0'; Items = @(
                        '📡 **حالة الاتصال عند التشغيل** — إشعار البدء يُظهر حالة Telegram و Cinegy فورًا مع كل قالب على الهواء ونصه المعروض.'
                        '↩️ **زر إعادة عرض** — إعادة عرض آخر قالب أُخفِي بضغطة واحدة بدل البحث في القوائم.'
                    ) }
                @{ Version = '8.47.2'; Items = @(
                        '🔢 **مؤشر حالة الطبقات مع النص المعروض** — زر إخفاء كل طبقة يُظهر النص الفعلي على الهواء (AirCopy) لتعرف ماذا تُخفي بالضبط.'
                    ) }
                @{ Version = '8.47.0'; Items = @(
                        '📋 **عمود النص في شاشة "على الهواء" للمدير** — يمكنك الآن رؤية النص الفعلي لكل قالب على الهواء من داخل برنامج التحكم.'
                        '⚠️ **تحذير عند عدم تغيّر قيمة الإعداد** — إن أدخلت القيمة نفسها، يُخبرك الجسر أنها مطابقة ولا يُسجّل تغييرًا زائفًا.'
                        '📡 **إشعار التشغيل يسرد المشاهد على الهواء** — عند إعادة التشغيل، يُعلمك الجسر بالقوالب التي لا تزال ظاهرة على الهواء مع نص كل منها، فلا تفاجأ بما يعرض الشاشة.'
                    ) }
                @{ Version = '8.46.0'; Items = @(
                        '⏰ **تنبيه القالب يُظهر النص المعروض على الهواء** — رسالة التنبيه تُعرض الآن النص الفعلي للقالب إضافة إلى اسمه، لتعرف ماذا يُعرض بالضبط على الشاشة.'
                        '🙈 **زر «إخفاء القالب» في رسالة التنبيه** — يمكنك الآن رفع القالب عن الهواء مباشرة من رسالة التنبيه دون العودة إلى القائمة.'
                        '⏰ **زر «ذكّرني لاحقًا» بدل «تمت المعالجة»** — الضغط عليه يضبط تذكيرًا جديدًا بعد 5 دقائق إن بقي القالب ظاهرًا، فلا تنسَ متابعته.'
                    ) }
                @{ Version = '8.45.0'; Items = @(
                        '📋 **تقرير أسبوعي جديد** — زر «📋 تقرير أسبوعي» في قائمة التقارير يعرض: شاشات قريبة من حدّها، قوالب بلا استخدام منذ شهر، أسباب الفشل المتكررة (أعلى 5)، إعدادات معدّلة، ملخص شريط الأخبار، نشاط العواجل.'
                        '📰 **توسيع عرض الشريط** — شاشة إدارة شريط الأخبار تعرض الآن أول 8 أخبار مباشرة بدل عددها فقط، مع ذيل عربي للأخبار المتبقية.'
                    ) }
        @{ Version = '8.44.0'; Items = @(
                        '🔄 استمرار حالة العرض اليدوي بعد إعادة التشغيل — يُحفظ زر الإخفاء ووضع اليدوي/التلقائي على القرص فلا يضيعان.'
                        '🔘 كل تحذير إرشادي يحمل زر حلّه: المشهد بلا حلقة ← اضبط الآن، الإخفاء التلقائي ← تغيير.'
                        '📐 القائمة الرئيسية: كل زر إدارة في صف مستقل (شريط الأخبار ← الموجز ← العواجل).'
                        '📋 جدول العواجل: نص الخبر في صف كامل العرض، وأزرار القراءة والإجراءات تحته — بنمط الموجز.'
                    ) }
                @{ Version = '8.43.0'; Items = @(
                    '👁 زر «👁 قراءة» في كل صف يفتح نص الخبر كاملًا مع تنقّل صفحات وقوائم انتقال (الخبر السابق/التالي، جزء سابق/باقي النص) — لا يغيّر الهواء.'
                    '🚨 نمط «يدوي — خبر واحد» في شريط الوضع: تختار خبرًا واحدًا، تؤكّده، فيُعرض وحده مع زر إخفاء مخصص؛ الجدول التلقائي لا يتقدم.'
                    '🔐 زر الإخفاء يتحقّق من صلاحية القالب/الطبقة لحظة الضغط، ويرفض إذا سُحبت الصلاحية أثناء العرض.'
                    '⏱ صلاحية العرض وسياسة الإظهار تُفحص *قبل* إيقاف أي تشغيل تلقائي، فلا يسقط المحتوى الجاري عند الرفض.'
                    '🔑 هوية الإخفاء الحي مخزّنة منفصلة عن حالة التأكيد المؤقتة، فلا تضيع عند انتهاء مهلة أو فتح شاشة أخرى.'
                ) }
            @{ Version = '8.42.0'; Items = @(
                '⏱ للمشرف: الإعدادات ← القوالب ← أقصى مدة لكل قالب. اختر قالبًا وحدّد 1–3600 ثانية بالأزرار؛ يبدأ الإخفاء مع عرضه ولا يستطيع المشغّل تمديده فوق الحد. إزالة القاعدة تحتاج تأكيدًا، و«طبّق الآن» يقصّر العرض الحالي فورًا.'
                '🔁 عند بلوغ حدّ قالب غير حسّاس يُعرض طلب تمديد واحد للمشغّل: ٥ دقائق أو مدة مخصّصة بالأزرار أو إخفاء الآن. دون ردّ خلال مهلة قصيرة يُخفى تلقائيًا، والقوالب الحسّاسة تُخفى عند حدّها دون تمديد. وفشل الإخفاء يُعاد وبتنبيه.'
                '🗑 أزرار الجدول صارت مرتبطة بالخبر نفسه لا بموضعه: زرّ قديم بعد نقل أو حذف لن يحذف أو يعدّل خبرًا آخر، وتأكيد الحذف يُثبَّت على ما عرضته لحظته.'
                '🔢 فشل حفظ الإعداد يُقال صراحةً وتعود القيمة السابقة؛ إذا تعذّر الحفظ فلن تظهر القيمة الجديدة كأنها حُفظت.'
                '⏭ تخطي أو استئناف بعد إخفاء لم يتأكّد يُرفض مع زرّ إعادة الإيقاف، والإيقاف لا يعلن النجاح قبل خروج المشهد فعلًا، حتى بعد إعادة التشغيل.'
                '🔁 كل خبر يتكرّر بعدده الخاص في ترتيبي العرض، وتقليم السقف يحافظ على ظهور كل خبر مرة على الأقل، والزمن المتوقّع يُقرّب 59.6 إلى 1:00.'
                '🚨 الجدول يستعيد نسخته الاحتياطية إن فقد الملف الأصلي، ويرفض ملفًا صحيح البنية لا يشبه الجدول. والشاشة النصية تعرض المعطَّل ⛔ وتحذير القالب الحسّاس.'
            ) }
        @{ Version = '8.41.0'; Items = @(
                '⏭ تخطي الحالي ينهي العاجل وينتقل فورًا للتالي؛ تخطي الأخير ينهي الجدول.'
                '⏸ مؤقت يجمّد الانتقال ويبقي العاجل ظاهرًا؛ ▶️ استئناف يكمل الوقت المتبقي. مؤقّت أمان القالب لا يتوقف.'
                '🙈 إخفاء بعد المدة نمط ثالث: يُخرج هذا العاجل عند انتهاء فاصله قبل عرض التالي، حتى لو كان التالي بنمط تحديث النص. النمطان السابقان باقيان.'
                '🔢 فاصل العاجل وتكراره وتوقيتات الجدول تُعدّل بأزرار الزيادة والنقصان، مع حفظ فوري وقيمة واضحة؛ الأزرار القديمة لا تعدّل عنصرًا آخر بعد نقله.'
            ) }
        @{ Version = '8.40.1'; Items = @(
                '📑 في موجز طويل، كل نقل أو حذف أو إضافة صفّ كان يعيدك إلى الصفحة الأولى. صارت الشاشة تبقى عند الصفّ الذي لمسته: النقل يتبعه ولو عبر صفحة، والحذف يبقيك عند مكانه، والإضافة تفتح على الصفّ الجديد.'
            ) }
        @{ Version = '8.40.0'; Items = @(
                '🚨 زرّ «العواجل» الجديد يفتح جدولًا: أضف عواجل، رتّبها، حدّد ما تريد عرضه، وشغّلها واحدًا بعد الآخر. معطّل افتراضيًا — فعّله من الإعدادات (فئة الأخبار).'
                '🚨 كل عاجل يُعرض بأحد نمطين: «تحديث نص» يبدّل الكلمات في المشهد القائم دون قطعه، أو «مع حركة خروج» يخرج المشهد ويعود بالعاجل التالي.'
                '🚨 التوقيت للجدول كلّه أو لكل عاجل وحده: الفاصل، وعدد التكرارات، والمدة الكلية. والترتيب خياران: الجدول كاملًا ثم يعيد (١ ٢ ٣ · ١ ٢ ٣) وهو الافتراضي، أو كل عاجل مرّات ثم التالي (١ ١ · ٢ ٢).'
                '🚨 شاشة مراجعة قبل التشغيل تقول الزمن المتوقّع، وتقول صراحةً إن قصّت المدة الكلية تكراراتك أو إن كان القالب حسّاسًا فيُخفى تلقائيًا قبل أن يكتمل الجدول.'
                '🚨 وزرّ العاجل المفرد لم يتغيّر: يعمل كما كان تمامًا، وإن ضغطته أثناء تشغيل الجدول توقّف الجدول وأخبرك — العاجل المفرد أسبق.'
            ) }
        @{ Version = '8.39.0'; Items = @(
                '📋 شاشة القوالب صارت مصفّحة: عشرون قالبًا في الصفحة وأزرار «السابق/التالي». محطة بمئة قالب كانت تبني لوحة من مئة صفّ، وتيليجرام لا يرسلها أصلًا.'
                '📋 ومعها التصنيفات والمفضلة والنصوص الجاهزة وصفوف الموجز. وما دون حدّ الصفحة يظهر كما كان تمامًا — لا يظهر شريط الصفحات إلا حين توجد صفحة ثانية.'
                '🔎 ونتائج البحث تُقصّ بحدّ الصفحة وتقول كم نتيجة بقيت، مع زرّ لتضييق البحث.'
            ) }
        @{ Version = '8.38.2'; Items = @(
                '🔎 إصلاحان في تصفية سجل العمليات شُحنا معطوبين أمس: زرّ «يوم أمس» كان يظهر مع مرشّح مفعّل ولا يفعل شيئًا عند الضغط — أُزيل من الشاشة المصفّاة، والمرشّح يُرفع بزرّه.'
                '📤 وبعد تصدير CSV من «عملياتي» كانت الشاشة تعود بزرّ «أزل التصفية» ويختفي زرّ «كل المشغّلين» — «عملياتي» نطاق لا مرشّح، وقد عادا كما ينبغي.'
            ) }
        @{ Version = '8.38.1'; Items = @(
                '🕘 شاشة «نسخ شريط الأخبار» كانت تعرض عشر نسخ مهما ضبطت — والافتراضي عشرون. فنصف ما يحفظه الجسر لم يكن يظهر لك أصلًا. صارت تعرض كل ما يُحتفظ به.'
                '🛡 وإصلاح في مسار الاستعادة: كان يبني قائمته بنفسه بدل قراءة القائمة المعروضة، فرقم الزرّ والملف المستعاد قد يفترقان. صارا قائمة واحدة.'
                '⚙️ ولإعداد «نسخ الأخبار المحفوظة» مدى معلن الآن (١–٣٠)، لأنه صار يحدّد طول الشاشة.'
            ) }
        @{ Version = '8.38.0'; Items = @(
                '📤 زرّ «تصدير CSV» في 🧾 سجل العمليات — للمشرفين — يرسل المدة المعروضة ملفًّا يُفتح في إكسل: التاريخ والوقت والعملية والقالب والطبقة والنتيجة والمشغّل وسبب الفشل.'
                '📤 ويحترم التصفية: صفِّ بمشغّل أو بقالب ثم صدّر، فيخرج ما تراه لا كل شيء. ولا يحتوي الملف نصوص ما عُرض على الشاشة.'
                '⚠️ وإن بلغ السجل حدّ القراءة يقولها مع الملف، فلا يصير أرشيفًا فيه ثغرة لا يعلم بها أحد.'
            ) }
        @{ Version = '8.37.0'; Items = @(
                '🔎 صار في 🧾 سجل العمليات زرّ «تصفية»: اختر مشغّلًا أو قالبًا من قائمة بما جرى في المدة نفسها — لا كتابة ولا بحث — فتُعرض عملياته وحدها.'
                '🔎 والتصفية تبقى معك إن غيّرت المدة، ويزيلها زرّ «أزل التصفية». وعنوان الشاشة يقول ما هو مصفّى، فلا تُقرأ شاشة مضيّقة على أنها الصورة كاملة.'
                '👥 واختيار مشغّل آخر للمشرفين وحدهم، كما هو زرّ «كل المشغّلين» تمامًا.'
            ) }
        @{ Version = '8.36.0'; Items = @(
                '🔍 حين يفشل عرض قالب صار تحت الرسالة زرّ «لماذا لم يظهر؟» يجيب في شاشة واحدة: هل Cinegy يستجيب، وهل ملف المشهد في مكانه، ومن يحجز الطبقة، وهل القالب مسموح لك، وهل الصيانة مفعّلة.'
                '🔍 وأكثر سبب لا تراه شاشة الحالة صار يُقال صراحةً: ملف مشهد نُقل أو أُعيدت تسميته. كان الفشل يقول رسالة الإرسال فقط، وهي العَرَض لا السبب.'
                '🛡 الفحص قراءة فقط ولا يرسل شيئًا إلى Cinegy — فيمكن الضغط عليه وقت العطل بلا قلق.'
            ) }
        @{ Version = '8.35.1'; Items = @(
                '⚡ حارس داخلي على «النصوص الجاهزة»: كان فحص رقم النص يتحقّق من حدّه الأعلى وحده، ورقمٌ سالب في PowerShell يقرأ من آخر القائمة — أي أن رقمًا خارج المدى كان يختار النصّ الخطأ بصمت بدل أن يُرفض. لا شيء في البوت يرسل رقمًا كهذا اليوم؛ الحدّ الناقص أُغلق قبل أن يفتحه تغيير قادم.'
            ) }
        @{ Version = '8.35.0'; Items = @(
                '🗄 صار لتعديلات القوالب تراجع: زرّ «نسخ القوالب» في 🗂 إدارة القوالب يعرض النسخ المحفوظة، ويقول قبل الاستعادة أي القوالب ستُحذف وأيها ستتغيّر وأيها ستُضاف بأسمائها.'
                '🛡 والاستعادة تُرفض إن مسّت قالبًا على الهواء الآن أو مرتبطًا بجدولة قادمة. وتُحفظ نسخة من القوالب الحالية قبل الكتابة، فالاستعادة نفسها قابلة للتراجع.'
                '🧹 ومجلد نسخ القوالب كان ينمو بلا حدّ مع كل تعديل تعريف أو تذكير أو استيراد — صار يُقلَّم إلى العدد نفسه المضبوط لنسخ الإعدادات.'
            ) }
        @{ Version = '8.34.0'; Items = @(
                '🛡 شاشة «جاهزية المناوبة» صارت تقول أي الحمايات مطفأة الآن وبأي نتيجة — مثل «لا تراجع بعد عرض خاطئ» و«لا طبقة تجربة». ثلاث منها تُشحن مطفأة افتراضيًا ولم يكن شيء يقول ذلك لأحد.'
                '🛡 والسطر يذكر اسم الإعداد لتجده في ⚙️ الإعدادات وتبدّله. وحالة الحمايات لا تغيّر حكم «جاهز ✅»: هي اختيار إعداد، لا أثرًا تركته المناوبة السابقة.'
            ) }
        @{ Version = '8.33.0'; Items = @(
                '📰 رسالة النشر صارت تقول أين وصل الخبر فعلًا: «نُشر على الهواء» و«حُدِّث الشيت». وإن نجح الهواء وفشل الشيت تقولها صراحةً — كان النجاح يُعلن كاملًا والشيت متأخّر بصمت.'
                '⚠️ ومزامنة الشيت التلقائية صارت تنبّهك إن توقّفت: بعد ٣ محاولات فاشلة متتالية يصلك السبب ومتى كان آخر نشر ناجح، ورسالة أخرى حين تعود. كان توقّفها لا يظهر إلا في السجل.'
            ) }
        @{ Version = '8.32.0'; Items = @(
                '🔇 صار للتنبيهات سقف: أكثر من ١٠ تنبيهات من السبب الواحد في الساعة تُكتم، ويصلك بعدها سطر واحد يقول كم كُتم — فلا يملأ عطلٌ واحد محادثتك مهما تكرّر.'
                '⚙️ السقف في ⚙️ الإعدادات ← التنبيهات باسم «سقف تنبيهات السبب الواحد»، وصفرٌ فيه يرفعه. والكتم لكل سبب على حدة، فلا يبتلع عطلٌ ثرثار تنبيهًا مهمًّا من سبب آخر.'
            ) }
        @{ Version = '8.31.1'; Items = @(
                '⏳ تحذير «مسودة الشريط على وشك الانتهاء» كان يصل في كل دورة بدل مرة واحدة — فيض رسائل على محادثة التنبيهات. صار مرّة واحدة لكل مسودة.'
                '⏳ وزرّ «مدّد» كان لا يفعل شيئًا: المهلة لا تُمدَّد والتحذير يواصل الوصول مهما ضغطت. صار يمدّدها فعلًا ويُسكت التحذير.'
            ) }
        @{ Version = '8.31.0'; Items = @(
                '📖 باب «📰 شريط الأخبار» في المساعدة صار يشرح نهايات المسودة الثلاث — نشر، أو تسليم لمن بعدك، أو إلغاء يعيد لك النصّ — وانتهاء صلاحية المسودة، وسجل التنفيذ.'
                '📖 وباب «📑 الموجز» صار يذكر سجل التنفيذ في شاشة المواعيد: هل بدأ موجز أمس فعلًا، وكم تأخّر، وسبب فشله إن فشل.'
                '📚 والدليل الكامل صار يعرض أبوابًا أكثر في الشاشة الواحدة، منها «🆘 حين يحدث خطأ» الذي كان يُسقط رغم وجود متّسع له.'
            ) }
        @{ Version = '8.30.0'; Items = @(
                '🤝 من يحرّر شريط الأخبار صار يستطيع تسليمه لمن بعده بزرّ «سلّم المسودة للتالي»: تبقى القائمة بكل أخبارها ويتابعها من يضغط ✏️. كان المخرج الوحيد النشر أو إتلاف المسودة.'
                '🗑 وإلغاء المسودة صار يعيد لك نصّ أخبارها رسالةً قبل أن يحذفها — كان يمسح كل ما كُتب بلا أثر.'
                '🧾 زرّ «سجل التنفيذ» في الموجز وفي شريط الأخبار كان يرسل شاشة يرفضها تيليجرام بأكملها بسبب صفّ أزرار معطوب. صار يعمل.'
            ) }
        @{ Version = '8.29.1'; Items = @(
                '✅ زرّ «جاهزية المناوبة» في 🗂 أدوات الإدارة كان لا يفتح شيئًا: الشاشة تُبنى كاملة ثم يرفضها تيليجرام كلها بسبب صفّ أزرار مكتوب بفاصلة زائدة، فلا يصل المشغّل شيء ولا يظهر للعطل أثر على الشاشة. صار يعمل.'
                '🛡 والحارس الذي كان يُفترض أن يمسك هذا العطل قبل الإرسال كان معطَّلًا من حيث لا يُرى، فيمرّر الصفّ المعطوب صامتًا. صار يُصلح الصفّ ويُبقي أزراره، ويُسجّل ما أصلحه — ويمنع الاختبارُ كتابةَ هذا الصفّ أصلًا.'
            ) }
        @{ Version = '8.29.0'; Items = @(
                '📦 ثلاثة ملفات كانت تكبر بلا حدّ صار لكلٍّ منها إعداد في ⚙️ الإعدادات ← الصيانة: سجل التنفيذ، والمواعيد المنتهية في ملف الجدولة، والمحادثات المحظورة. وصفرٌ في أيّها يعني «احتفظ بالكل».'
            ) }
        @{ Version = '8.28.0'; Items = @(
                '📑 مواعيد الموجز صار لها سجل تنفيذ: زرّ «🧾 سجل التنفيذ» في شاشة المواعيد يقول هل بدأ موجز الأمس فعلًا وكم تأخّر — وكانت النتيجة تعيش على سجلّ الموعد وتضيع معه.'
                '📰 مزامنة الشيت التلقائية صار لها سجل أيضًا، من زرّ «🧾 سجل التنفيذ» في إدارة شريط الأخبار: كانت تنشر على الهواء بساعتها الخاصة ولا تقول شيئًا إلا في ملف سجلّ لا يفتحه أحد أثناء المناوبة.'
            ) }
        @{ Version = '8.27.0'; Items = @(
                '🧾 شاشة جديدة في 📅 الجدولة: «سجل التنفيذ» — كل حدث مجدول نُفِّذ فعلًا، ومتى كان مقرَّرًا ومتى جرى، وكم تأخّر، وسبب الفشل إن فشل. البيانات كانت تُسجَّل منذ البداية بلا شاشة تقرؤها.'
                '🔘 زرّ لا يستجيب صار نادرًا: صفٌّ مشوَّه في لوحة المفاتيح كان يُسقط الرسالة كلها عند تيليجرام بصمت، فيضغط المشغّل ولا يحدث شيء. صار يُصلَح قبل الإرسال ويُسجَّل ليُعرف مصدره.'
            ) }
        @{ Version = '8.26.7'; Items = @(
                '🆕 شاشة «ما الجديد» كانت تكسر السطر الطويل إلى عدة نقاط، فيظهر نصف الجملة كبندٍ مستقل — صار كل بند نقطة واحدة كاملة.'
                '🗂 أدوات الإدارة: الفئات الأربع صارت زرّين في الصف بدل صفّ لكل واحدة، وكذلك أزرار المستخدمين والمحتوى — شاشة أقصر لليد الواحدة.'
            ) }
        @{ Version = '8.26.6'; Items = @(
                '🔓 الطبقة تُحرَّر لحظة انتقالك إلى شيء آخر: كانت تبقى محجوزة باسمك إن تركت تجهيز قالب وضغطت زرًّا أقدم في المحادثة، فيُرفض كل عرض لاحق عليها لكل المشغّلين حتى إعادة تشغيل الجسر.'
            ) }
        @{ Version = '8.26.5'; Items = @(
                '🗓 مدخلة واحدة تالفة في الجدولة كانت تمحو كل المواعيد القادمة نهائيًا عند الإقلاع — صارت تُتخطّى وحدها ويبقى الباقي.'
                '🚫 المستخدم المعطَّل يبقى معطَّلًا: تلف ملف الصلاحيات كان يعيده نشطًا بصمت.'
                '⏱ بعد إعادة التشغيل، لم يعد مؤقّت إخفاء قديم يُخفي غرافيكًا لا علاقة له به.'
            ) }
        @{ Version = '8.26.4'; Items = @(
                '🗂 أدوات الإدارة صارت أربع فئات (المستخدمون، المحتوى، الصحة، النظام) بدل قائمة واحدة من خمسة عشر زرًّا — الأدوات نفسها بترتيب أوضح.'
            ) }
        @{ Version = '8.26.3'; Items = @(
                '🔗 رابط بثّ RTMP صار يُرفض إن لم يبدأ بـ rtmp:// أو rtmps://، بدل قبول أي نصّ.'
                '🩺 مركز الصحة صار يعرض عدد المحادثات المحجورة في صفّ مستقل، لا داخل شاشة 👥 المستخدمون وحدها.'
            ) }
        @{ Version = '8.26.2'; Items = @(
                '🔤 الجمع العربي صار صحيحًا في كل رسائل البوت تقريبًا — التذكيرات ومواعيد الجدولة وتنبيهات شريط الأخبار وقوائم المستخدمين والتقارير: «ساعتان» لا «2 ساعة»، و«5 دقائق» لا «5 دقيقة».'
                '📖 الدليل صار يذكر 🎞 جدول المواد و🤝 تسليم و✅ جاهزية المناوبة و🔇 هدوء ساعتين — أزرارٌ موجودة وتعمل ولم يكن الدليل يذكرها.'
            ) }
        @{ Version = '8.26.1'; Items = @(
                '📸 زرّ «صورة» صار يرفض طلبًا جديدًا أثناء التقاط سابق لا يزال جاريًا («لقطة أخرى قيد الالتقاط الآن») بدل تشغيل عدة التقاطات معًا على جهاز البثّ عند الضغط المتكرر.'
            ) }
        @{ Version = '8.26.0'; Items = @(
                '🖥 المدير: شاشة «استقرار التشغيل» صارت بطاقات ملوّنة بدل خمسة أسطر متساوية الوزن، وتسرد حالة تيليجرام وCinegy ومراقبة المخرج والبث المرحّل والجدولة الحية من الجسر نفسه — لا فقط إقلاعات العملية من سجلّ محلي.'
                '🖥 المدير: تصادم اسم القالب الطويل مع رقم استخدامه في مخطط الاستخدام انتهى، وصار يقول «يعرض أول 8 من N» حين تُخفى قوالب خلف حدّ الرسم.'
                '🖥 المدير: كل عدد في نافذتَي المدير يوافق الآن جمعه العربي الصحيح — «5 دقائق» لا «5 دقيقة» دائمًا، و«خطآن» لا «2 خطأ».'
            ) }
        @{ Version = '8.25.2'; Items = @(
                'طلب فكّ قفل شريط الأخبار صار ينجو من إعادة التشغيل: إن صمت صاحب القفل حتى بعد توقف الجسر وعودته، يُمنح القفل لك في أول دورة بعد الإقلاع بدل ضياع الطلب بصمت.'
            ) }
        @{ Version = '8.25.1'; Items = @(
                '«📊 ملخص الاستخدام» صار يقول إن الترتيب تراكمي، وتفصيل النتائج عاد ملاصقًا لسطر «منذ آخر تشغيل» بدل سطر الأسبوع — والأعداد بالعربية الصحيحة: «8 مرات» و«8 عمليات» بدل «8 مرة» و«8 عملية».'
            ) }
        @{ Version = '8.25.0'; Items = @(
                'زرّ «↩️ استئناف» صار يُبقي مسودتك محفوظة إن كانت الطبقة مشغولة — حاول بعد تحرّرها بدل ضياع العمل.'
                'شاشة المحادثات الميتة صار فيها زرّ «🔍 اختبار» يفحص الوصول برسالة واحدة — النجاح يعيد التفعيل والفشل يبقي الحجر بصمت.'
                'الزرّ الذي كان يموت بصمت صار يردّ عليك برسالة خطأ — وستصلك ملاحظة واحدة إن أُعيد تشغيل الجسر 4 مرات في يوم واحد.'
            ) }
        @{ Version = '8.24.0'; Items = @(
                'تشخيص تعذّر المخرج صار معه زرّ «📋 نسخة جاهزة للنسخ» يرسل النص عاديًا لتلصقه في مجموعة الصيانة بدل إعادة كتابته.'
                'تنبيه «ثالث مرة لنفس السبب» صار يُثبَّت أعلى المحادثة ويتحدّث مع كل تكرار، ويُفكّ عندما يصمت العطل.'
                'كتالوج القوالب صار يقول متى بُثّ كل قالب آخر مرة — وزرّ «🔇 هدوء ساعتين» في المراقبة يجمع غير العاجل أثناء البث.'
                'شاشة «✅ جاهزية المناوبة» في أدوات الإدارة تقول للمستلِم: جاهز، أم صفِّ هذه القائمة أولًا.'
            ) }
        @{ Version = '8.23.0'; Items = @(
                'المحادثة التي تحظر البوت تُحجر بعد ثلاث محاولات فاشلة بدل أن تُقصف كل دورة — وتظهر في شاشة المستخدمين مع زرّ إعادة تفعيل.'
                'كتالوج القوالب صار يعرض القوالب غير الصالحة مع سبب كل واحد وزرّ حذف — بدل تحذير «تم تخطيه» الذي لا يفعَل به شيء.'
                'رسالة انتهاء المهلة صار فيها زرّ «↩️ استئناف» يعيد مسودتك من حيث توقفت — للمراجعة لا للهواء مباشرة.'
            ) }
        @{ Version = '8.22.0'; Items = @(
                'تنبيه جديد قبل نهاية المادة الجارية (معطّل افتراضيًا — فعّله من المراقبة بالدقائق التي تناسبك) لتجهيز غرافيك الختام.'
                'شاشة التسليم صارت تُرفق أهم الأحداث تلقائيًا: آخر الأعطال وما يتكرر منها.'
                'زرّ 🚨 إخفاء الكل صار أحمر في كل مواضعه — والشاشة الجديدة «صحة المحرك» (معطلة افتراضيًا) تجمع الإطارات والترخيص وما يُبثّ.'
            ) }
        @{ Version = '8.21.0'; Items = @(
                'تنبيه تعذّر التقاط المخرج صار يسمّي سيرفر البث نفسه ويقترح خطوتك التالية — القناة أم الترحيل أم السيرفر أم المصدر.'
                'الجدولة صارت تُربط بمادة: «اعرض العاجل بعد 30 ثانية من بدء الفقرة» من زرّ 🎞 في شاشة المراجعة، فإن تأخرت المادة تبعها الغرافيك.'
                'مراجعة التراجع صارت تعرض صورتين: قبل النشر والآن — فإن أخطأت ترى الخطأ بدل أن تتذكره.'
                'الملخص الأسبوعي صار يحمل «ما لاحظه الجسر»: شاشات قريبة من حدّها، وقوالب مهملة، وفشل متكرر، وإعدادات معدّلة — وأبطأ القوالب وصولًا للهواء والمسودات المهجورة.'
            ) }
        @{ Version = '8.20.0'; Items = @(
                'تحذير مدة الموجز الذي لا يوافق طول اللوب صار معه زرّ ⚡ يضبط المدة بنفسه، بدل أن تحسب الإطارات وتكتبها يدويًا.'
                'والحالة الكاملة تنبّه إن كان إصدار Cinegy المثبَّت هنا يختلف عن التوثيق المرجعي الذي بُنيت عليه ميزات الجسر.'
            ) }
        @{ Version = '8.19.0'; Items = @(
                'شاشتا الحالة لم تعودا تُطوى: كل شيء ظاهر، مقسّمًا بعناوين وفواصل، ومعرّفك والساعة وما يبثّه الجهاز الآن في الأعلى.'
                'واسمك يظهر في السجلّ والتقارير بدل رقمك — يتعلّمه البوت من تيليغرام وحده، والاسم الذي يضعه المشرف يبقى الأقوى.'
                'وإن تكرّر العطل نفسه ثلاث مرات، صار التنبيه يقول إنه تكرار ومتى بدأ، بدل أن يصل كأنه أول مرة.'
                'وتنبيه للمشرف إن كان عنوان Cinegy خارج شبكة البثّ.'
            ) }
        @{ Version = '8.18.1'; Items = @(
                'زرّ «✏️ تعديل» صار يظهر في شاشة المراجعة بعد كتابة الحقول بيدك أيضًا — كان يظهر فقط حين تصل القيم جاهزة، فمن أخطأ في كلمة لم يكن أمامه إلا الإلغاء والبدء من جديد.'
            ) }
        @{ Version = '8.18.0'; Items = @(
                'قالبٌ بقي على الهواء لم يعد يُنبَّه عنه مرة واحدة: التنبيه يتكرّر، ويصل من نشره لا المشرفين وحدهم، ومعه زرّ إخفاء مباشر.'
                'شاشة الحالة صارت تقول ما يُبثّ الآن وما بعده — البرنامج نفسه لا الغرافيك.'
                'وزرّ «جدول المواد» يعرض ما يبثّه الجهاز اليوم بمواعيده.'
                'وزرّ «تسليم» يجمع في شاشة واحدة ما يحتاجه تبديل المناوبة، ويسجّل التسليم.'
                'وتنبيهات إملائية إرشادية في شاشة المراجعة — لا تمنع الإرسال أبدًا.'
                'وإن تعذّر التقاط المخرج، صار التنبيه يقول أين الخلل: القناة أم الترحيل أم المصدر.'
                'وخيار للمشرف: تنبيه إن قاربت مادة موعدها بلا نسخة محلية على السيرفر.'
            ) }
        @{ Version = '8.17.0'; Items = @(
                '📜 جدول «سجل القالب» صار يقصّ أقدم صفوفه ويقول كم أخفى، بدل أن يفقد جدوله كاملًا في شهرٍ مزدحم.'
            ) }
        @{ Version = '8.16.0'; Items = @(
                '📖 «الدليل الكامل» يصل الآن بفصوله القابلة للطيّ — كان يتجاوز حدّ الرسالة دائمًا فيسقط إلى نصّ طويل، ولم يظهر مطويًّا ولا مرة.'
            ) }
        @{ Version = '8.15.0'; Items = @(
                '📅 التقويم ومنتقيات الساعة والدقيقة عادت شبكاتٍ في وضع اليد الواحدة — كانت قد صارت أعمدة طويلة بخطأ مني في 8.9.'
                '📝 نصّ قالبٍ خرج للتوّ لم يعد يُكتب داخل القالب الذي حلّ محلّه إن استُبدل بسرعة.'
                '⏱ فحص سواد الشاشة لم يعد يوقف كل شيء خمس ثوانٍ: الإخفاء التلقائي والجدولة تمضي أثناءه.'
                '📢 والتنويهات المنتهية لم تعد تتراكم بلا حدّ.'
            ) }
        @{ Version = '8.14.0'; Items = @(
                '🗄️ سبعة ملفات حالة صار لكلٍّ منها نسخة احتياطية: المفضّلة والأسماء والإعلانات والمسودات وغيرها تُستعاد إن تلف ملفها.'
                '🖥 المدير: لا يبدو معلّقًا وهو يوقف الجسر قبل حفظ الإعدادات، ولا يترك مؤقّتاته ومقابضه خلفه عند الإغلاق.'
            ) }
        @{ Version = '8.13.0'; Items = @(
                '🔒 طلبٌ يُرفض لم يعد يغيّر الهواء: العاجل الممنوع لم يعد يسحب الموجز قبل أن يُرفض، والإخفاء المحجوب بالصيانة لم يعد يوقف الموجز.'
                '📡 وإن تعذّر حفظ رقم عملية البث، يُقال لك إنه يعمل بدل أن يُبلَّغ كأنه فشل ثم يبقى بلا تتبّع.'
                '⚙️ وتعديلٌ يدوي على config.json لم يعد يُفقد بصمت — يُكتب في السجل حين يحدث.'
                '🌙 ولتنبيهات فترة الهدوء سقف، فلا ينمو موجز الصباح حتى يعجز عن الوصول.'
            ) }
        @{ Version = '8.12.0'; Items = @(
                '📘 الدليل كان يقول «الأبواب الثمانية» وهي تسعة — والغائب باب 🔔 الإشعارات نفسه.'
                '📘 وقائمة الإعدادات المحمية كانت تذكر خمسة من سبعة؛ اكتملت.'
            ) }
        @{ Version = '8.11.0'; Items = @(
                '📘 المساعدة صارت تشرح فترة الهدوء ووضع اليد الواحدة وعودة مسودتك بعد إعادة التشغيل — وكانت الثلاثة غائبة عنها.'
                '📘 وصُحّح سطرٌ يقول إن الأرقام تُكتب: تُضبط بـ ➖ و➕ منذ إصدارات، والدليل وحده لم يعلم.'
            ) }
        @{ Version = '8.10.0'; Items = @(
                '🙈 الإخفاء صار يقول الحقيقة: إن لم يؤكّد Cinegy رفع الطبقة، تُخبرك الرسالة بذلك بدل «تم الإخفاء» فوق زرّ يقول إنها ما تزال حيّة.'
                '⬅️ رسالة الرفض أو انتهاء المهلة تأتي بزرّ رجوع واحد بدل القائمة كاملة، فلا يختفي سطر السبب تحت سبعة عشر صفًّا.'
                '🖥 المدير: أزراره صارت تُنطق باسمها لقارئ الشاشة بدل اسم الأيقونة التي تسبقها.'
            ) }
        @{ Version = '8.9.0'; Items = @(
                '🤏 وضع اليد الواحدة صار يشمل كل الشاشات لا القائمة الرئيسية وحدها: الحقول والقوالب والإعدادات والموجز كلها عمود واحد.'
                '↩️ إن أُعيد تشغيل الجسر وأنت في منتصف تجهيز قالب، تصلك رسالة تقول إن مسودتك ما تزال مفتوحة - قبل أن تبتلع رسالتك التالية.'
                '🔔 التنبيهات المؤجّلة في فترة الهدوء لم تعد تضيع لو أُعيد تشغيل الجسر ليلًا.'
                '⚙️ حدود الأرقام في الإعدادات عادت تعمل: عدد الأخبار وحجم سجل التدقيق ومدة الإخفاء الافتراضية لم تعد تقبل أي رقم.'
                '🗑 حُذف مفتاح «المدة تتبع المقطع» من إعدادات الموجز: لم يكن له أثر، والمدة تُكتب كما كانت دائمًا.'
            ) }
        @{ Version = '8.8.0'; Items = @(
                '📡 مهلة التقاط واحدة لم تعد تحوّل البث للاحتياطي: محاولة ثانية أولًا، وفحصٌ للأساسي خلال دقائق لا بعد ساعة.'
                '🖥 وأزرار المدير بعرضٍ واحد، وقائمة الخيارات عمودٌ مستقيم.'
            ) }
        @{ Version = '8.7.0'; Items = @(
                '🖥 المدير: أيقونة على كل زرّ ومفتاح، وقائمة خيارات تتبع المظهر، وتصفية السجل بالوقت.'
            ) }
        @{ Version = '8.6.0'; Items = @(
                '🖥 المدير: سطرٌ يقول آخر عملية وصلت الهواء وأخطاء الساعة، والمفاتيح خلف زرّ «خيارات»، وزرٌّ رئيسي واحد.'
            ) }
        @{ Version = '8.5.0'; Items = @(
                '📘 الدليل صار يغطّي الجديد: 🔔 التنبيهات فصلٌ كامل، وسجل العمليات، والطلبات السابقة، والإدخال بالضغط.'
            ) }
        @{ Version = '8.4.0'; Items = @(
                '⏸ الإشعار ينتظر إن كنت في منتصف الكتابة، ويصلك مجموعًا حين تنتهي.'
                '⚠️ ومن يجهّز قالبًا عُرض أو رُفع أثناء تجهيزه يُنبَّه فورًا — حتى لو أوقف تنبيهاته.'
            ) }
        @{ Version = '8.3.0'; Items = @(
                '⚫️ ورفعُ القالب عن الهواء صار يُعلَن أيضًا، ومعه كم بقي.'
                '🔕 ولكل شخص زرّ «أوقف تنبيهاتي» على كل إشعار، و/تنبيهاتي للعودة.'
            ) }
        @{ Version = '8.2.0'; Items = @(
                '🔢 الأرقام تُضبط بزرّي ➖ و➕ بدل كتابتها — تسعون إعدادًا.'
                '🕑 والساعات وأيام الأسبوع ونافذة الصيانة تُختار من شبكة، والقوائم من منتقٍ.'
                '🛡 ولكل رقم حسّاس مدًى لا يقبل ما خارجه.'
            ) }
        @{ Version = '8.1.0'; Items = @(
                '🔔 إشعار العرض صار يُضبط بالضغط على القالب — لا بكتابة نصّ.'
            ) }
        @{ Version = '8.0.0'; Items = @(
                '🔴 القالب يستطيع أن يُعلن عن نفسه عند العرض: نصّه ومدّته ومن نشره — لمن تختار.'
                '⏳ ومسودة الشريط تُنبّهك قبل انتهائها بزرّ «تمديد»، فلا تضيع أخبارها فجأة.'
            ) }
        @{ Version = '7.99.0'; Items = @(
                '📆 سجل العمليات صار يُقرأ يومًا بيوم — أمس وما قبله، بسهمين.'
                '📜 و«السجل» صار يقول الفترة التي يغطّيها، ويؤرّخ أسطر الأيام السابقة.'
                '👤 وفي طلبات الوصول زرّ «الطلبات السابقة»: من طلب، ومن قرّر، ومتى، والحالة.'
            ) }
        @{ Version = '7.98.0'; Items = @(
                '🔼 ترقية مستخدم إلى مشرف صارت تضيفه إلى الإشعارات أيضًا، لا إلى الصلاحية وحدها.'
            ) }
        @{ Version = '7.97.0'; Items = @(
                '🔑 منح الوصول صار يسأل مرة ثانية، ويُبلَّغ به كل المشرفين.'
                '📢 وكل مشرف يصله الإشعار الآن، لا من كان في AdminChatIds وحده.'
                '⏳ والكتابة لم تعد تُلغى فجأة: تنبيه قبل دقيقة وزرّ «تمديد».'
            ) }
        @{ Version = '7.96.0'; Items = @(
                '🗓 وسجل العمليات صار يصل إلى 7 أيام، لا 72 ساعة فقط.'
            ) }
        @{ Version = '7.95.0'; Items = @(
                '📅 سجل عمليات بنافذة 24 أو 48 أو 72 ساعة — من زرّ «سجل 48 ساعة» في شاشة عملياتك.'
                '👥 وللمشرف: عمليات كل المشغّلين في المدة نفسها.'
            ) }
        @{ Version = '7.94.0'; Items = @(
                '📏 ثلاث شاشات كانت ستفقد جداولها مع امتلاء الأرشيف: تقرير الموجزات ومكتبتها ومراجعة النشر.'
                '🛠 وتقرير الموجزات كان ينهار على تشغيلٍ سجّلته نسخة أقدم.'
            ) }
        @{ Version = '7.93.1'; Items = @(
                '🔧 تحذير حجم الشاشة صار يُقال مرة واحدة فعلًا، لا مرة لكل رقم في عنوانها.'
            ) }
        @{ Version = '7.93.0'; Items = @(
                '📐 «أرقام التشغيل» تقول الآن أي شاشة أقرب إلى فقدان جدولها — قبل أن تفقده.'
            ) }
        @{ Version = '7.92.1'; Items = @(
                '🔵 زرّ النسخ صار أزرق كبقية أزرار الفعل — الأثر الوحيد الذي يقبله زرٌّ لا يُبلَّغ بضغطه.'
            ) }
        @{ Version = '7.92.0'; Items = @(
                '📋 الشاشات التي فيها زر نسخ صارت تقول ما سيفعله الزرّ وأين تضع ما نسخته.'
            ) }
        @{ Version = '7.91.0'; Items = @(
                '📋 تعديل خبر أو صف موجز يبدأ من نصّه: اضغط عليه أو على زر النسخ، ثم الصق وعدّل.'
                '📺 وما سيظهر على الشاشة صار مميّزًا في شاشة المراجعة — لا يختلط بأسماء الحقول.'
            ) }
        @{ Version = '7.90.0'; Items = @(
                '⏳ المدد صارت تُقرأ بالأشهر والأسابيع والأيام — لا «4320 د».'
            ) }
        @{ Version = '7.89.0'; Items = @(
                '📅 الجدولة القادمة وطلبات الوصول ومكتبة الموجزات و«من استخدم» صارت جداول.'
            ) }
        @{ Version = '7.88.1'; Items = @(
                '📊 ملخص الاستخدام صار جدولين: ترتيب القوالب، وكيف انتهت العمليات.'
            ) }
        @{ Version = '7.88.0'; Items = @(
                '📋 شاشة القائمة صار ما على الهواء فيها جدولاً: الطبقة والقالب ومنذ متى ومن عرضه.'
                '📈 وأرقام التشغيل وصحة ملفات التشغيل صار لهما جدولان أيضًا — ولم تبقَ شاشة بلا جدول.'
            ) }
        @{ Version = '7.87.1'; Items = @(
                '🔧 تقارير الموجز والأخبار والبنرات عادت للعمل — صفّ أزرار واحد كان يُسقط الرسالة كلها.'
            ) }
        @{ Version = '7.87.0'; Items = @(
                '📊 عادت الجداول إلى كل الشاشات: تقرير واحد ضخم كان يُعطّلها للجلسة كلها.'
            ) }
        @{ Version = '7.86.2'; Items = @(
                '🔎 رفض تيليجرام لرسالة صار يُسجّل بسببه الذي ذكره تيليجرام نفسه، لا برقم الحالة وحده.'
            ) }
        @{ Version = '7.86.1'; Items = @(
                '🔧 إصلاح عاجل: قسم التقارير توقّف في 7.86.0 — التقرير الطويل كان يُقصّ داخل إطار فيُرفَض.'
            ) }
        @{ Version = '7.86.0'; Items = @(
                '📈 ملخص الاستخدام والتقارير الأربعة أخذت تصميم مركز الصحة: الإجمالي أولًا ثم التفصيل.'
                '📑 ولم تعد أي شاشة ترسم خطوط فصل — الإطار يفصل فعلًا ويُطوى إن طال.'
            ) }
        @{ Version = '7.85.1'; Items = @(
                '🔤 عاد نص شاشات الصحة والأرقام إلى حجمه الكامل — الجدول الثابت كان يصغّره مقاسين.'
            ) }
        @{ Version = '7.85.0'; Items = @(
                '📊 شاشات الصحة والأرقام والاستخدام صارت جداول حقيقية تصطفّ أعمدتها.'
                '💚 وتعافي Cinegy صار يُعلَن دائمًا — مع مدة الخلل وسببه والقياسات بعده.'
                '🔎 وتغيّر حالة Cinegy في السجل صار يقول أيّ مقياس تجاوز الحدّ، لا الكلمة وحدها.'
            ) }
        @{ Version = '7.84.0'; Items = @(
                '⌨️ شاشة إدخال النص صارت تقول صراحة: اكتب في صندوق الرسالة بالأسفل وأرسل.'
                '▰▰▱ ومعها شريط تقدّم يُقرأ بلا حساب، واسم الحقل بارز فوق اسم المتغيّر.'
                '🩺 ومركز الصحة يرفع ما يحتاج انتباهك فوق، ولكل مكوّن رمزه الخاص لا لونًا فقط.'
            ) }
        @{ Version = '7.83.0'; Items = @(
                '🩺 مركز الصحة وأرقام التشغيل صارا يبدآن بحكم واضح بدل أن تقرأ الصفوف لتعرف.'
                '🗂 وصحة الملفات تضع ما يحتاج انتباهك فوق، وتطوي السليمة خلف عدد.'
                '🕒 وكل شاشة تقرير صارت تحمل ساعتها، فلقطة الشاشة تقول متى أُخذت.'
            ) }
        @{ Version = '7.82.0'; Items = @(
                '🔒 رسائل الأخطاء صارت تُنقّى من أي سرّ قبل أن تصل المحادثة أو السجل.'
            ) }
        @{ Version = '7.81.0'; Items = @(
                '✏️ شاشة إدخال النص صارت تبرز اسم الحقل المطلوب، وتضع اسم المتغيّر بخط ثابت تحته.'
                '⚙️ وشاشة تغيير الإعداد تصطفّ فيها القيمة الحالية تحت الافتراضية فتُقارَن بنظرة.'
            ) }
        @{ Version = '7.80.1'; Items = @(
                '📝 برنامج التحكم صار يسجّل خروجه الإرادي، فغياب السطر يقول إن أحدًا أنهاه من الخارج.'
            ) }
        @{ Version = '7.80.0'; Items = @(
                '🖥 برنامج التحكم لم يعد يعرض تنبيه «لا يزال يعمل» في كل إغلاق — مرة واحدة ثم يصمت.'
                '🛡 وإن تكرّر خطأ في واجهته، يُبلّغ عنه مرة ويُسجّل البقية — بلا نوافذ متتالية.'
            ) }
        @{ Version = '7.79.0'; Items = @(
                '📐 شريط الاقتباس صار له معنًى واحد: تفصيل يمكن تخطّيه — وما كان جواب الشاشة لا يُقتبس.'
                '📂 والقوائم الطويلة تُطوى تلقائيًا، فيبقى الحكم العام في أول شاشة الهاتف بلا تمرير.'
            ) }
        @{ Version = '7.78.0'; Items = @(
                '🕒 شاشة القائمة صارت تقول تحت كل طبقة منذ متى هي على الهواء ومن عرضها.'
                '📐 وأُزيل شريط الاقتباس منها — الفصل بمسافات ووزن، فهذا جواب الشاشة لا نقل عن غيرها.'
            ) }
        @{ Version = '7.77.0'; Items = @(
                '🖥 برنامج التحكم صار يحمل رقم الإصدار الرئيسي وحده (v7)، لأنه لا يُنشر مع كل إصدار جسر.'
                '🔎 وشريط الحالة فيه إصدار الجسر العامل وإصدار المدير معًا، كلّ باسمه.'
                '⌨️ والاختصارات F5 وCtrl+L صارت مكتوبة على تلميح الأزرار بدل أن تبقى سرًّا.'
            ) }
        @{ Version = '7.76.0'; Items = @(
                '📊 وأخيرًا: «أرقام التشغيل» و«ملخص الاستخدام» و«معاينة القالب» و«المفضلة» صارت منسّقة.'
                '📋 ومعاينة القالب تقول أولًا اسمه وهل هو على الهواء — وهما ما يُقرأ قبل العرض.'
            ) }
        @{ Version = '7.75.1'; Items = @(
                '🔧 إصلاح: سطران في «ماذا فاتني» و«صحة الملفات» كانا سيمنعان الشاشة من الوصول أصلًا.'
            ) }
        @{ Version = '7.75.0'; Items = @(
                '🎨 شاشة القائمة صار ما على الهواء فيها داخل إطار حقيقي بدل خطوط مرسومة، ويُطوى إن كثرت الطبقات.'
                '🕘 و«ماذا فاتني» و«مركز الصحة» و«صحة الملفات» و«نشاط المستخدمين» و«من استخدم» صارت منسّقة مثلها.'
                '🔎 العناوين تفصل الأقسام، والأوقات والأعداد بخط ثابت تُنسخ بلمسة ولا تنقلب بجانب العربية.'
            ) }
        @{ Version = '7.74.0'; Items = @(
                '📱 القائمة صارت أقصر: الحالة والحالة الكاملة في صف، والجدولة والتقارير في صف، وشريط الأخبار والموجز في صف.'
                '🖥 وبرنامج التحكم لم يعد يترك شاشة السجل فارغة عند التصفية — يقول لماذا لا يظهر شيء وكيف تعود.'
                '⌨️ وفيه اختصاران: F5 لإعادة التشغيل، وCtrl+L لمسح الشاشة.'
            ) }
        @{ Version = '7.73.0'; Items = @(
                '🎨 شاشتا ℹ️ الحالة و📊 الحالة الكاملة وشاشة القائمة صارت منسّقة: الحكم بخط عريض، والعناوين تفصل الأقسام.'
                '📋 والعنوان والقناة والأرقام صارت بخط ثابت يُنسخ بلمسة، ولا تنقلب أرقامه بجانب العربية.'
                '👋 و«/بدء» و«إلغاء» صارا يعرضان الحالة تحت التحية بدل أن يقولا «اختر من القائمة» وحدها.'
                '⚠️ والموجز صار ينبّه إن كانت مدة الصف لا توافق طول لوب القالب — فتُعرض الأخبار مرتين.'
            ) }
        @{ Version = '7.72.0'; Items = @(
                '👤 وشاشة القائمة صارت تقول باسم من فُتحت، بالصياغة نفسها التي تعرضها ℹ️ الحالة.'
            ) }
        @{ Version = '7.71.0'; Items = @(
                '📋 شاشة القائمة صارت مفصولة بثلاث كتل: الحكم العام، ثم ما على الهواء، ثم المحرّك والقناة.'
                '↳ وكل طبقة على الهواء في سطر خاص بها بدل صفٍّ واحد طويل يُقرأ كلمةً كلمة.'
                '🟠 ولا يُقال «كل شيء سليم» إلا بعد تحقّق ناجح من Cinegy — قبل ذلك يقول إنه لم يتأكّد.'
            ) }
        @{ Version = '7.70.0'; Items = @(
                '🏠 ضغطة القائمة لم تعد تبدأ برسالة تقول إن القائمة موجودة — تُثبَّت لوحة الأزرار مرة واحدة لكل محادثة.'
                '📋 وشاشة القائمة صارت تجيب بنفسها: ما على الهواء، وعمر آخر تحقّق، ومحرّك Air والقناة.'
            ) }
        @{ Version = '7.69.0'; Items = @(
                '🔌 رأس برنامج التحكم صار يقول حالة تيليجرام وCinegy، لا «يعمل» وحدها — فالجسر قد يعمل وهو مقطوع.'
                '📜 وإن استلم جسرًا يعمل بالفعل، صار يتابع سجله من الملف بدل أن تبقى شاشته فارغة.'
            ) }
        @{ Version = '7.68.0'; Items = @(
                '👥 تقرير العمل صار يفصل «مرفوضة» عن «فاشلة» — الأولى صلاحية والثانية عطل، وكانتا رقمًا واحدًا.'
                '↳ ويقول كم عملية وصلت الهواء فعلًا، وأكثر قالب اشتغل عليه كل مشغّل، وآخر نشاط له، ومجموع الوردية.'
                '🖥 وبرنامج التحكم يستلم جسرًا يعمل بالفعل عند فتحه، بدل أن يقول «متوقف» بينما الجسر على الهواء.'
                '🖼 وقياس صورة الموجز لم يعد يسقط إلى حجم افتراضي بسبب لوحة في القالب بلا اسم ملف.'
            ) }
        @{ Version = '7.67.0'; Items = @(
                '🛡 بعد إعادة التشغيل، لا يستأنف الموجز ولا يُخرجه إلا بعد التأكد أنه المشهد نفسه على الهواء.'
                '📨 إعادة إرسال رسائل Telegram المؤجلة لا توقف توقيت الموجز والإخفاء، وتبقى ملفات التقارير محفوظة حتى انتهاء المحاولة.'
                '⚙️ «حفظ وإعادة التشغيل» يوقف الجسر قبل حفظ الصلاحيات؛ إن فشل الحفظ يبقى متوقفًا ويعرض الخطأ.'
                '📋 السجل يحتفظ بترتيب وصول الأحداث مع إعطاء التحذيرات والأخطاء أولوية الاحتفاظ عند الازدحام.'
            ) }
        @{ Version = '7.66.0'; Items = @('👥 في «التقارير» تقرير عمل يبيّن حصيلة كل مشغّل، وملخص الاستخدام الأسبوعي يقرأ آخر 7 أيام فعلًا.') }
        @{ Version = '7.65.2'; Items = @('🧩 حفظ الإعدادات من المدير لا يعيد قيمة اتصال قديمة فوق تعديل أحدث في الجسر.') }
        @{ Version = '7.65.1'; Items = @(
                '📨 عند ازدحام Telegram، الصور والملفات والرسائل الغنية وتحديث الشاشة تنتظر دورها بدل أن تضيع.'
            ) }
        @{ Version = '7.65.0'; Items = @(
                '🖥 شاشة المدير تلوّن الوقت والمستوى ورقم العملية والطبقة ونتيجة التنفيذ؛ يظل رمز البوت مخفيًا.'
                '📋 سجل المدير وطابور رسائل Telegram لهما حدّ ثابت: التحذيرات والأخطاء تتقدم، ولا تعطل دفقةٌ المراقبة أو الأوامر.'
                '🪟 أزرار التشغيل منفصلة عن أدوات السجل عند تصغير النافذة، وشاشة الإعدادات تتسع للشاشات القصيرة.'
            ) }
        @{ Version = '7.64.0'; Items = @(
                '🛡 تُلغى الخطوة المفتوحة فور سحب صلاحية صاحبها، ولا يمكن سحب صلاحية مالك الجسر.'
                '♻️ إعادة التشغيل تنتظر توقف النسخة القديمة، وحفظ الإعدادات لم يعد يتسابق بين المدير والبوت.'
                '📰 استيراد شيت غير صالح لا يمسح مسودة محرر آخر، وتقرير «أمس» لا يضم اليوم.'
                '📡 انتظار Telegram عند الازدحام صار في الخلفية كي تبقى المراقبة مستجيبة.'
                '🎬 استعادة الموجز تتحقق من المشهد الفعلي وتكتب الصف الصحيح.'
            ) }
        @{ Version = '7.63.0'; Items = @(
                '🖥 برنامج التحكم صار يعود مع ويندوز ومعه الجسر — كان يعود وحده والجسر متوقف حتى ينتبه أحد.'
                '🩺 وصار يكشف الجسر المعلّق (يعمل ولا يستجيب) ويعيد تشغيله، لا الجسر المتوقف وحده.'
                '🔒 ورمز البوت لم يعد ظاهرًا على شاشة إعداداته، وتعديل قوائم الصلاحيات صار يحذّرك إن كان لن يثبت.'
                '🔎 وفي شاشة السجل: تلوين للأخطاء، وتصفية بالبحث أو بـ«الأخطاء والتحذيرات فقط».'
                '🎨 وواجهته أُعيد تصميمها: الحالة تُقرأ من بعيد، والمظهر فاتح افتراضيًا وداكن باختيارك.'
                '👥 والصلاحيات صارت قائمة حسابات تُضاف وتُحذف بصفوف، بدل أرقام مفصولة بفواصل.'
                '✋ ويسألك قبل إعادة التشغيل، وقبل إطفاء إعادة التشغيل التلقائي أو كشف التعليق أو حذف حساب.'
            ) }
        @{ Version = '7.62.0'; Items = @(
                '⚠️ تنبيه للمشرفين حين لا يكون اللوغو أو الشريط على الهواء — يُسأل Cinegy، فيُكشف الغياب سواء جاء من البوت أو من خارجه.'
                '↳ لا يُنبَّه إلا بعد فحصين متتاليين حتى لا يزعجك استبدالٌ يستغرق ثوانٍ، ويُخبرك مرة أخرى حين يعود.'
                '📋 وسجل التشغيل صار يقول من أين أخذ الموجز زمنه: من ساعة Cinegy أم من ساعة الجسر.'
            ) }
        @{ Version = '7.61.0'; Items = @(
                '🧹 الاحتفاظ بصور الموجز صار ٤٨ ساعة بدل ٢٤ (⚙️ الإعدادات ← 🔴 التشغيل على الهواء ← «الاحتفاظ بصور الموجز»).'
                '⏱ وزمن الموجز صار مضبوطًا على لحظة البدء التي يقولها Cinegy لا على ساعة الجسر، فتصيب المزامنة الفيضة أدقّ.'
                '↳ وبعد إعادة تشغيل الجسر يستعيد الموجز طور اللوب الحقيقي بدل تقريبه.'
            ) }
        @{ Version = '7.60.0'; Items = @(
                '🎬 «مزامنة الظهور» صار الزر يقول ماذا تفعل، والشاشة تقول ثمنها، وباب المساعدة يشرحها.'
                '↳ مفعّلة: الخبر يُكتب داخل فيضة اللوب فلا يُرى وهو يتبدّل — والإيقاع يصير طول اللوب لا مدتك.'
                '🎬 وأساس تعدد التصاميم: اختيار التصميم عند إنشاء موجز جديد، خلف خيار «موجز متعدد التصاميم» المطفأ.'
            ) }
        @{ Version = '7.59.0'; Items = @(
                '♻️ موجز على الهواء صار ينجو من إعادة تشغيل الجسر: يُستأنف عند صفه، أو يُخرَج إن تجاوز وقته.'
                '⏹ ومدة بقاء يضعها المشغّل بنفسه — للتقرير الذي هو خبر واحد لا قائمة أخبار.'
                '🎬 وإن رُفع مقطع ولم تُحدَّد مدة، صار طوله هو المدة. وما تكتبه يعلو عليه دائمًا.'
            ) }
        @{ Version = '7.58.0'; Items = @(
                '📢 «التنويهات» في أدوات الإدارة: تكتب تنويهًا فيصل لمن تختار — الجميع أو المشغّلين أو المشرفين.'
                '⚙️ ولك مدّته وتكراره، وزر «تم الاطلاع» يوقف التكرار عمّن قرأه، وتثبيتٌ يُبقي سطرًا فوق القائمة.'
            ) }
        @{ Version = '7.57.0'; Items = @(
                '🔔 قسم «الإشعارات والتنبيهات» في الإعدادات يجمع ٢٣ إعدادًا كانت موزّعة على خمسة أقسام.'
                '🔕 وإشعار طلبات الوصول صار له مفتاح، وحظر الحارس لمحادثة صار يُخبر المشرفين بدل أن يبقى في السجل وحده.'
            ) }
        @{ Version = '7.56.0'; Items = @(
                '📑 قسم «الموجزات» في 📊 التقارير: أي نشرة شُغّلت، بكم صفًّا، ومن شغّلها، وكم بقيت على الهواء.'
                '📅 والفترة التي تقرؤها صارت مُعلَّمة بنقطة في أزرار التقارير الأربعة.'
                '🧹 صور الموجز غير المستخدمة تُنظَّف كل ساعة لا كل دورة، وبإعداد «الاحتفاظ بصور الموجز» (0 يوقفه).'
            ) }
        @{ Version = '7.55.0'; Items = @(
                '📑 مكتبة الموجزات ومواعيدها و📋 الأحداث القادمة صارت مُصفّحة — كانت تتوقف عن الفتح متى كثرت.'
                '🧪 وفحص آلي يمنع تكرار العلة: أي شاشة جديدة تُبنى من قائمة تنمو ولا تُصفّح تُسقط الاختبارات.'
            ) }
        @{ Version = '7.54.0'; Items = @(
                '✅ البوت لم يعد يقول «موجز على الهواء» ولا موجز هناك — سُحب الادعاء من أصله، والسجل القديم يُمسح تلقائيًا.'
                '🎚 وللتحكم بما شُغِّل من Cinegy مباشرة: زر «الطبقات» يقرأ المحرّك حيًّا ويعطيك زر الإخفاء لكل طبقة يقول إنها تعمل.'
            ) }
        @{ Version = '7.53.0'; Items = @(
                '🟡 طبقة اكتُشفت من Cinegy بعنصر بلا اسم تظهر بعلامة صفراء ومعها «قد لا يكون ظاهرًا» — لا كأنها على الهواء.'
                '↳ السبب: الخروج من المشهد ينهي الحركة ويترك العنصر نشطًا، فلا يفرّق المحرّك بين موجز انتهى وموجز يُعرض.'
                '⏹ زر «إخفاء الموجز» لم يعد يظهر إلا والموجز فعلًا على الهواء.'
            ) }
        @{ Version = '7.52.0'; Items = @(
                '📡 الشريط الإخباري وأي مشهد يُشغَّل من Cinegy صار يظهر في القائمة ويمكن إخفاؤه — لم يكن يظهر أبدًا.'
                '🔌 انقطاعات Telegram المتكررة في السجل كانت استطلاعًا تأخّر جوابه لا اتصالًا مفقودًا؛ صار الجسر يحتملها ويواصل.'
            ) }
        @{ Version = '7.51.0'; Items = @(
                '📡 ما يُشغَّل من Cinegy مباشرة صار يظهر في القائمة خلال ثوانٍ — الشريط الإخباري لم يكن يظهر إلا بعد فتح ℹ️ الحالة.'
                '👥 شاشة المستخدمين: سطر واحد لكل شخص، واضغط اسمه لتفتح بطاقته وفيها التعطيل والاسم والنشاط والسحب.'
                '🔐 شاشة صلاحيات القوالب صارت مُصفّحة وعمودين، فتفتح مهما كبر سجل القوالب.'
                '🖥 برنامج التحكم BridgeManager يشغّل الجسر ويوقفه ويتابع السجل ويحرّر الإعدادات من نافذة واحدة.'
            ) }
        @{ Version = '7.50.0'; Items = @(
                '🚫 رفض طلب الوصول صار يحظر المحادثة فلا تعود تطلب، وشاشة «المحظورون» ترفع الحظر عمّن تريد.'
                '🔑 «رمز الانضمام»: من لا يعرفه لا يصل طلبه إليك أصلًا، وثلاث محاولات خاطئة تحظره.'
                '⏳ حدّ يومي لطلبات الوصول من المحادثة الواحدة، فلا يملأ غريبٌ الطابور بضغطة متكررة.'
                '😴 بلاغ يومي بمن لم يستخدم البوت منذ شهرين، مع خيار تعطيله تلقائيًا.'
                '🚪 البوت يغادر أي مجموعة يُضاف إليها ولم تُدرج، ويخبرك أين كان.'
            ) }
        @{ Version = '7.49.0'; Items = @(
                '👁 زر «معاينة النص كاملًا» في شاشة الموجز: كل صف بعنوانه ونصه بلا اقتصاص، وصورته التي ستظهر فعلًا.'
            ) }
        @{ Version = '7.48.0'; Items = @(
                '🎞 مدة صف الموجز صارت بالإطارات كأختيها، وإعداد «إطارات صف الموجز» يحمل الافتراضي.'
                '📝 طالب الوصول يُسأل عن اسمه، ويصير اسمه في السجل عند الموافقة دون أن يكتبه المشرف.'
            ) }
        @{ Version = '7.47.0'; Items = @(
                '⏹ إشعار حين ينتهي الموجز وحده ويخرج عن الهواء — الطريقة الوحيدة لإنهائه التي لم تكن تقول شيئًا.'
                '🔔 وتنبيه قبل بدء موجز مجدول بدقيقة، يُرسل مرة واحدة.'
                '⚙️ لكل إشعار مفتاحه: «إشعار انتهاء الموجز» و«تنبيه قبل الموعد» (صفر يوقفه).'
            ) }
        @{ Version = '7.46.0'; Items = @(
                '🎞 توقيت الموجز صار بالإطارات: زرّا «الأول» و«الأخير» يقبلان عدد إطارات ويعرضان ما يعادلها بالثواني.'
                '⚙️ إعدادان للمدد الافتراضية: «إطارات الصف الأول» و«إطارات الصف الأخير» — صفر يعني أخذها من المشهد.'
                '📺 «معدل إطارات القناة»: 25 أو 50 أو 60، يُستخدم حين لا يذكر المشهد معدله.'
                '🎯 زال التقريب إلى ثانية كاملة: دخول 30 إطارًا صار 1.2 ث لا 2 ث.'
            ) }
        @{ Version = '7.45.0'; Items = @(
                '📋 قائمة القوالب صارت تعرض ما يملك المستخدم صلاحيته فقط، بدل عرض قالب يُرفض عند الضغط.'
                '🎚 «من يرى زر الطبقات»: الجميع أو المشرفون أو المالك — شاشة الطبقات أدوات خام يمكن قصرها على من يملك الرندَون.'
            ) }
        @{ Version = '7.44.0'; Items = @(
                '👁 تأكيد الإخفاء والخروج صار يعرض نص القالب المعروض: ترى ما ستسحبه قبل أن تسحبه.'
                '🔒 الحقول الحسّاسة تُذكر بأسمائها دون قيمها، والخيار يُطفأ من ⚙️ الإعدادات.'
            ) }
        @{ Version = '7.43.0'; Items = @(
                '☑️ «طبقات للمشرفين» و«طبقات للمالك» تُختار كذلك بالضغط: كل طبقة يعرفها الجسر باسمها لا برقمها وحده.'
                '⚙️ الإعدادات وأدوات الإدارة تظهران للمشرفين فقط — إن غابتا عن قائمتك فحسابك ليس مشرفًا.'
            ) }
        @{ Version = '7.42.0'; Items = @(
                '☑️ «قوالب للمشرفين» و«قوالب للمالك» تُختار من قائمة القوالب بالضغط، لا بكتابة الاسم.'
                '↳ ✅ محدد · ⬜ متاح للجميع، وزر لإفراغ القائمة دفعة واحدة.'
            ) }
        @{ Version = '7.41.0'; Items = @(
                '🕒 «تشغيل لاحقًا» في الموجز صار بأزرار كجدولة القوالب: ⏱ +15 · +30 · +60 و📅 تقويم يوم ← ساعة ← دقيقة.'
                '⌨️ والكتابة باقية كما هي لمن يفضّلها: +30 · بعد 90 · 21:45 · غدًا 07:00.'
            ) }
        @{ Version = '7.40.0'; Items = @(
                '📖 دليل المساعدة صار فيه باب «📑 الموجز»: المكتبة، الصفوف، أوضاع الصورة الثلاثة، التوقيت والمزامنة، المواعيد، وأولوية العاجل.'
                '🔐 وباب الإعدادات يشرح صلاحيات العرض والإخفاء لكل قالب وطبقة.'
            ) }
        @{ Version = '7.39.1'; Items = @(
                '🔧 إعدادات الصلاحيات الأربعة لم تكن مسجّلة، فلم تظهر في الشاشة ولم تعمل. سُجّلت الآن.'
            ) }
        @{ Version = '7.39.0'; Items = @(
                '🔐 صلاحية العرض والإخفاء صارت لكل قالب على حدة: للجميع افتراضيًا، أو للمشرفين، أو للمالك وحده.'
                '🎚 والطبقة كذلك: طبقة محمية لا يُعرض عليها ولا يُخفى منها إلا بالصلاحية، أيًّا كان القالب.'
                '⚙️ تُضبط من الإعدادات: «قوالب للمشرفين» · «قوالب للمالك» · «طبقات للمشرفين» · «طبقات للمالك».'
            ) }
        @{ Version = '7.38.0'; Items = @(
                '🖼 مقاس صورة الصف صار إعدادًا: 538×303 كما يُصدّرها Titler فعلًا، لا كما تُحسب من لوحة القالب.'
            ) }
        @{ Version = '7.37.1'; Items = @(
                '📰 الشريط الإخباري يبقى على الهواء أثناء الموجز افتراضيًا. لجعله يقف ويعود: ⚙️ الإعدادات ← «إخفاء الشريط أثناء الموجز».'
            ) }
        @{ Version = '7.37.0'; Items = @(
                '📰 شريط الأخبار يخرج تلقائيًا عند بدء الموجز ويعود بعد انتهائه — يتقاسمان أسفل الشاشة، ويبقى اللوغو طوال الوقت.'
                '↩️ العودة بعد انتهاء حركة خروج الموجز لا في أثنائها، فلا يظهر الاثنان معًا.'
                '🛡 شريط لم يكن على الهواء قبل الموجز لا يُعاد إدخاله.'
            ) }
        @{ Version = '7.36.0'; Items = @(
                '🚨 الأولوية للعاجل: خروجه على الهواء يسحب الموجز تلقائيًا، أيًّا كان ما أرسله.'
                '❓ قبل إرسال العاجل والموجز يعمل: يُسألك «الآن ويخرج الموجز» أم «بعد انتهائه»، ويخرج وحده في الحالتين.'
                '❓ وقبل تشغيل الموجز والعاجل على الهواء: «بعد خروج العاجل» أم «ابدأ الآن رغمه».'
                '⏳ الموعد المجدول ينتظر العاجل ولا يُلغى، ويبدأ فور خلوّ الهواء.'
            ) }
        @{ Version = '7.35.0'; Items = @(
                '🖼 صورة الصف تُفحص عند الرفع وتُقاس على لوحة القالب نفسها وتُحفظ PNG — سبب أن الصورة لم تكن تظهر على الهواء.'
                '🚫 ملفٌّ ليس صورة يُرفض برسالة واضحة بدل أن يمرّ ويُخرج صفًّا فارغًا.'
                '⏹ زر «إخفاء الموجز» صار ثابتًا في القائمة الرئيسية، ويحمر لونه حين يكون الموجز على الهواء فعلًا.'
            ) }
        @{ Version = '7.34.0'; Items = @(
                '⏹ زر «إخفاء الموجز» في القائمة الرئيسية: يظهر ما دام الموجز على الهواء، ويوقف النشرة ويخرج بحركة الخروج.'
                '🔒 أي إخفاء أو خروج للطبقة يُنهي النشرة معه، فلا تبقى تكتب صفوفًا في مشهد مخفيّ.'
            ) }
        @{ Version = '7.33.0'; Items = @(
                '🎬 زر «مزامنة الظهور»: يتبدّل الصف داخل حركة ظهور المشهد فلا يُرى وهو يتغيّر.'
                '⏱ عند تشغيلها يصير طول اللوب هو مدّة الصف — تقصير LoopEndFrame في Titler يسرّع النشرة.'
                '🎯 التوقيت صار مواعيد مطلقة بساعة لا تتراجع: صفٌّ تأخّر لا يزيح من بعده، والدقّة ±عُشر ثانية بدل ±ثانية.'
            ) }
        @{ Version = '7.32.1'; Items = @(
                '🔧 زر ✏️ لتعديل صف كان يردّ بلا شيء ويسجّل خطأ؛ يعمل الآن.'
            ) }
        @{ Version = '7.32.0'; Items = @(
                '✏️ صف الموجز صار يُعدَّل: اضغط رقمه لتغيير صورته أو عنوانه أو نصه، بدل حذفه وكتابته من جديد.'
                '🖼 لكل صف ثلاثة اختيارات للصورة: صورة خاصة به · ↑ يتبع الصف السابق (فتخدم صورة واحدة عدة صفوف) · ▫️ صورة القالب.'
                '♻️ صورة سبق رفعها في هذا الموجز تُعاد بضغطة بدل رفعها مرة أخرى.'
                '👁 عمود الصورة في الجدول يقول لكل صف أيّ الثلاثة هو، فترى أين تتكرر الصورة وأين تتغيّر.'
            ) }
        @{ Version = '7.31.0'; Items = @(
                '📚 الموجزات صارت مكتبة: احفظ «الصباحي» و«المسائي» وغيرهما، لكلٍّ صفوفه وتوقيته، وافتح ما تريد تشغيله.'
                '✏️ من داخل الموجز: إعادة تسمية، نسخة منه، حذفه، وترتيب الصفوف بسهمي ⬆️ و⬇️.'
                '🕒 «تشغيل لاحقًا» صار موعدًا محفوظًا يبقى بعد إعادة التشغيل، وشاشة «المواعيد» تعرضها كلها وتلغي أيًّا منها.'
                '⏳ موعدان في وقت واحد لا يتصادمان: الثاني ينتظر انتهاء الأول ويصلك إشعار واحد بذلك.'
            ) }
        @{ Version = '7.30.0'; Items = @(
                '🎬 توقيت الموجز صار يُقرأ من القالب نفسه: مؤشرا اللوب يعطيان زمن الدخول والخروج تلقائيًا.'
            ) }
        @{ Version = '7.29.0'; Items = @(
                '⏩ زرّان جديدان في الموجز: «الأول» لزيادة الصف الأول، و«الأخير» لمدة الصف الأخير قبل الخروج.'
                '🕒 «تشغيل لاحقًا»: أرسل +30 أو بعد 90 أو 21:45 أو غدًا 07:00، ويبدأ الموجز وحده في موعده.'
            ) }
        @{ Version = '7.28.1'; Items = @(
                '🔧 إصلاح عاجل: كل رسالة نصية كانت تُقابل بـ«لا يُنتظر منك صورة الآن» — حتى /بدء و/menu.'
            ) }
        @{ Version = '7.28.0'; Items = @(
                '📑 شاشة «الموجز»: اكتب جدولًا من صفوف — صورة وعنوان وخبر — واضغط تشغيل، فيعرض الجسر كل صف بدوره ثم يخرج وحده.'
                '🖼 صورة الصف تُرفع من الجوال مباشرة (صورة أو ملف)، أو تُكتب كمسار، أو تُتخطّى لإبقاء صورة القالب.'
                '⏱ مدة كل صف تحددها أنت؛ الصف الأول يأخذ زيادة بقدر حركة الدخول، والأخير يخرج بعد نصف المدة.'
            ) }
        @{ Version = '7.27.0'; Items = @(
                '🏠 زر «القائمة» كان يردّ «خيار غير معروف» في سبع شاشات، ولا يلغي ما بدأت كتابته. صار يفتح القائمة ويلغيه كما يَعِد.'
            ) }
        @{ Version = '7.26.0'; Items = @(
                '🕘 قائمة نسخ الأخبار تقول كم خبرًا في كل نسخة ومتى حُفظت، لا وقتًا مجرّدًا على زر.'
                '🗄 قائمة نسخ الإعدادات كذلك، ومعها سبب الاستعادة وما تتطلبه.'
            ) }
        @{ Version = '7.25.0'; Items = @(
                '👥 شاشة المستخدمين صارت قائمة تُقرأ: الاسم والدور والحالة ومعرّف كل شخص ونشاطه — كانت أزرارًا فقط بلا معرّفات.'
            ) }
        @{ Version = '7.24.0'; Items = @(
                '👤 شاشة طلبات الوصول تعرض معرّف المستخدم ووقت الطلب ومتى ينتهي — كان الاسم وحده كل ما يظهر قبل منح التحكم بالهواء.'
            ) }
        @{ Version = '7.23.0'; Items = @(
                '♻️ «استعادة الافتراضي» صار يسأل أولًا ويعرض ما سيعود إلى قيمته الأصلية — كان يكتب فوق كل الإعدادات بضغطة واحدة.'
                '🔴 الأزرار التي تمسح أو تسحب صلاحية أو تستعيد أو تعيد التشغيل صارت حمراء مثل بقية أزرار الخطر.'
            ) }
        @{ Version = '7.22.0'; Items = @(
                '✅ تأكيد تغيير الإعداد صار يقول اسمه بالعربية وقيمته قبل وبعد، بدل «EnableSnapshot = False».'
                '↩️ زر إعادة إعداد إلى الافتراضي يقول ما هو الآن وما سيصير قبل أن تؤكّد.'
            ) }
        @{ Version = '7.21.0'; Items = @(
                '⚙️ زر الإعداد صار اسمًا قصيرًا مع قيمته، والشرح فوقه — كان الزر جملة كاملة في ٧٧ إعدادًا.'
                '🔎 البحث في الإعدادات يقول كم إعدادًا طابق وما يفعله كلٌّ منها، ويقول صراحةً حين لا يطابق شيء.'
            ) }
        @{ Version = '7.20.0'; Items = @(
                '⚙️ كل باب في الإعدادات صار يبدأ بسطر يقول ما فيه، وتحت كل زر شرح لما يفعله الإعداد.'
                '📄 «ما الجديد» صار فيها زر يرسل ملف السجل التقني الكامل.'
                '🧾 «نسخ مرجع» في عملياتي صار ينسخ مرجع العملية الفاشلة — وهو المرجع الظاهر على الشاشة.'
            ) }
        @{ Version = '7.19.0'; Items = @(
                '⚙️ باب جديد في 📖 المساعدة يشرح شاشة الإعدادات: الأبواب، البحث، التعديل، الحماية، النسخ والنقل.'
                '📖 صفحات المساعدة صارت بنص منسّق: عنوان القسم عريضًا واسم الإعداد بخط موحّد العرض ليُنسخ كما هو.'
            ) }
        @{ Version = '7.18.1'; Items = @(
                '🆕 صفحة «ما الجديد» صارت بنص منسّق: رقم الإصدار عريضًا فوق تغييراته، فترى أين ينتهي إصدار ويبدأ الذي قبله.'
            ) }
        @{ Version = '7.18.0'; Items = @(
                '⚙️ تأكيد استعادة الإعدادات صار جدولًا يقابل القيمة الحالية بما في النسخة، بدل أسماء الإعدادات وحدها.'
                '🔒 أي إعداد يشبه مفتاحًا أو رمزًا يُعرَض بطوله لا بمحتواه، والقوائم بعدد عناصرها.'
            ) }
        @{ Version = '7.17.2'; Items = @(
                '🔎 نتيجة «ابحث بمرجع عملية» صارت بخط موحّد العرض، فتبقى أعمدة سطر السجل متحاذية.'
            ) }
        @{ Version = '7.17.1'; Items = @(
                '📊 جداول الشاشات لم تعد تختفي جميعًا لأن تيليجرام رفض واحدة منها.'
            ) }
        @{ Version = '7.17.0'; Items = @(
                '⭐ المفضلة صارت تحفظ أكثر من قالب: كان الثاني يمحو الأول بصمت، وشاشة الإدارة تعرض الآن ما اخترته فعلًا.'
                'ℹ️ «الحالة» تعرض معرّفك في أعلاها، فلا تحتاج البحث عنه عند طلب وصول أو الإبلاغ عن عطل.'
                '🔒 طلب فكّ قفل الأخبار: الضغط المتكرر لم يعد يؤجّل المنح، والقفل يُحجز لك دقيقتين بعد تسليمه.'
                '⬇️ سحب الشيت (نشرًا أو إلى المسودة) صار يحتاج القفل: اضغط «✏️ بدء التحرير» أولًا.'
            ) }
        @{ Version = '7.16.0'; Items = @(
                '📝 شاشة الترتيب صارت جدولًا فيه عدد أحرف كل خبر، و⚠️ على ما يقترب من الحدّ.'
                '🔴 «على الهواء الآن» صار مطويًّا تحت المسودة: ترى الفرق دون الخروج إلى المعاينة.'
                '✅ تأكيد النشر صار يعرض ما سيُضاف وما سيُحذف بالنصّ لا بالعدد.'
            ) }
        @{ Version = '7.15.0'; Items = @(
                '↩️ سُحب تغيير اتجاه الجداول: الجداول تعود كما كانت، فالفحص أظهر أنها لم تكن معكوسة.'
            ) }
        @{ Version = '7.13.0'; Items = @(
                'ℹ️ «الحالة» و«الحالة الكاملة»: الحكم في الأعلى، والطبقات على الهواء في جدول، والتفاصيل تُفتح بالضغط بدل أن تُقرأ كلها.'
            ) }
        @{ Version = '7.12.0'; Items = @(
                '🩺 مركز الصحة صار جدولًا: عمود الحالة يُقرأ بنظرة، وأي عطل يظهر في أول الجدول لا في وسطه.'
            ) }
        @{ Version = '7.11.0'; Items = @(
                '🙈 الإخفاء والخروج صارا يذكران اسم البنر الذي خرج ونصّه في «عملياتي» — كانا يذكران رقم الطبقة وحده.'
                '📝 والعرض الفاشل صار يسجّل النص الذي كان سيُعرض، فتعرف ماذا كنت تحاول رفعه.'
            ) }
        @{ Version = '7.10.1'; Items = @(
                '🧾 «عملياتي» صارت أقصر وأوضح: حصيلة في الأعلى (كم نجح وكم فشل)، والعملية الناجحة سطر واحد، والمرجع يظهر عند الفشل وحده.'
            ) }
        @{ Version = '7.10.0'; Items = @(
                '🕘 «ماذا فاتني» تبدأ الآن بما على الهواء — كان آخر سطر فيها، وهو أول ما تحتاجه عند تسلّم الوردية.'
                '📝 نصوص البنرات عادت إلى تقرير البنرات تحت «نصوص البنرات».'
                '🧾 «عملياتي» تعرض الثلاث الأحدث وتطوي ما قبلها.'
            ) }
        @{ Version = '7.9.0'; Items = @(
                '📐 التقارير صارت تتسع لشاشة الهاتف: أربعة أعمدة قصيرة، والتفصيل تحت «تفاصيل كل يوم» يُفتح بالضغط.'
                '📊 عمود «المدى» (12–18) يقول أين تراوح الشريط طوال اليوم مهما بلغ عدد التعديلات.'
            ) }
        @{ Version = '7.8.0'; Items = @(
                '📊 تقرير الأخبار صُحّح: الشريط واحد يُعدَّل، فعدد الأخبار صار «ما على الهواء» لا مجموع القراءات — كان يضخّم الرقم.'
                '📈 وصار يعرض حجم كل تعديل (12 ← 15 ← 14)، ووقت أول وآخر تعديل، والأيام التي مرّت بلا تعديل.'
                '📖 «الدليل كاملًا» صار رسالة واحدة بأبواب تُفتح بالضغط.'
                '🧾 «عملياتي» صار قائمة مرتّبة بدل أسطر مُزاحة.'
            ) }
        @{ Version = '7.7.0'; Items = @(
                '📰 تقرير الأخبار صار جدولًا أيضًا: اليوم · النشرات · الأخبار · المشغّلون في صف واحد.'
            ) }
        @{ Version = '7.6.0'; Items = @(
                '📅 الجدولة صار فيها تقويم: اضغط «اختر من التقويم» ثم اليوم ثم الساعة ثم الدقيقة — بلا كتابة.'
                '⏱ وأزرار +15 و+30 و+60 دقيقة لأكثر ما يُجدوَل.'
                '⌨️ ومَن يفضّل الكتابة: «21:45» وحدها تكفي، وكذلك «غدًا 21:45» و«+30» — والأرقام العربية ٢١:٤٥ صارت مقبولة.'
            ) }
        @{ Version = '7.5.0'; Items = @(
                '🕒 «الأحداث القادمة» صارت تعرض الوقت بمنطقتك الزمنية ويوم الأسبوع، ومنطقة المحطة تبقى مكتوبة بجانبه.'
            ) }
        @{ Version = '7.4.0'; Items = @(
                '📊 تقرير البنرات صار جدولًا بأعمدة: البنر · الطبقة · المشغّل · الوقت · المدة. إن لم يظهر جدولًا فتطبيقك أقدم من الميزة، والتقرير يصل نصًّا كما كان.'
            ) }
        @{ Version = '7.3.0'; Items = @(
                '🔎 للمشرف: «ابحث بمرجع عملية» في شاشة التشخيص — الصق المرجع الذي نسخه المشغّل لترى سطر العملية فورًا.'
            ) }
        @{ Version = '7.2.0'; Items = @(
                '🔔 «سحب الشيت غير مسموح لك» و«الاستعادة للمشرف» صارا نافذة على الزر. والاستعادة كانت ترفض بصمت تام قبل ذلك.'
                '📋 «نسخ مرجع» في 🧾 عملياتي: انسخ المرجع بنقرة بدل كتابته حرفًا حرفًا للمشرف.'
            ) }
        @{ Version = '7.1.1'; Items = @(
                '🔴 تأكيد الإخفاء والخروج صار أحمر أيضًا: تفعيل التأكيد كان يعطي شاشة أضعف إشارة من تركه مطفأً.'
            ) }
        @{ Version = '7.1.0'; Items = @(
                '🔔 الرفض صار نافذة تظهر على الزر نفسه وتنتظر إغلاقك، بدل رسالة جديدة تدفع اللوحة خارج الشاشة.'
            ) }
        @{ Version = '7.0.1'; Items = @(
                '🎨 اللون وصل بقية الشاشات: الإخفاء والخروج من المشهد وحذف القالب وسحب الصلاحية بالأحمر، و«تأكيد الإرسال» و«تأكيد الجدولة» و«حفظ التغيير» بالأخضر.'
                '🧭 زر القائمة الذي يفتح شاشة يبقى بلا لون — الأحمر على الضغطة التي تُنفّذ فعلًا، لا على الطريق إليها.'
            ) }
        @{ Version = '7.0.0'; Items = @(
                '🎨 الأزرار صار لها لون: الحذف وإلغاء المسودة ومسح الكل بالأحمر، و«مراجعة ونشر» بالأخضر. أطفئه من ⚙️ الإعدادات ← «تلوين الأزرار».'
                '🚫 السهم الخامل في طرفي القائمة (▫️) صار معطّلًا فعلًا: لم يعد يُضغط ويبتلع الضغطة بلا نتيجة.'
                '📜 سرد الترتيب صار داخل اقتباس قابل للطيّ، فالصفحة الطويلة لم تعد تدفع الأزرار خارج الشاشة — اضغط «إظهار المزيد» لقراءته كاملًا.'
            ) }
        @{ Version = '6.9.5'; Items = @(
                '🔢 في الشكل المكدّس: رقم الخبر صار على كل زر إجراء، والعلامة تتناوب ▪️/▫️، فلا يختلط خبر بأزرار جاره.'
                '🗜 شكل خامس… رابع: compact — أرقام فقط خمسة في الصف، حتى 40 خبرًا في شاشة واحدة، والإجراءات في شاشة الخبر.'
            ) }
        @{ Version = '6.9.4'; Items = @(
                '🧩 «شكل قائمة الأخبار» في ⚙️ الإعدادات: ثلاثة أشكال للترتيب — text نص كامل فوق الأزرار · stacked الخبر بزر مستقل · inline الخبر داخل الصف. جرّب واختر.'
            ) }
        @{ Version = '6.9.3'; Items = @(
                '📝 شاشة الترتيب: نص الخبر صار يظهر كاملًا فوق الأزرار بدل أن يُقصّ داخل زر ضيق، وصفوف الأخبار صارت بحجم واحد.'
            ) }
        @{ Version = '6.9.2'; Items = @(
                '📊 باب جديد في المساعدة: «الربط مع Google Sheets» — شكل الشيت، والسحب في الاتجاهين، ومن يملك المسودة.'
            ) }
        @{ Version = '6.9.1'; Items = @(
                '📖 «مساعدة» و/help صارا يفتحان فهرس الأبواب نفسه الذي يفتحه زر المساعدة، لا الدليل القديم.'
                '📰 «الدليل كاملًا» صار يشمل شريط الأخبار وسحب الشيت — كانا ناقصين منه.'
                '📜 في السجل: اسم مَن نفّذ مع رقمه في كل سطر، ورقمه بأقواس سليمة لا معكوسة.'
            ) }
        @{ Version = '6.9.0'; Items = @(
                '↔️ صار ما تنشره من تيليجرام يُحفظ في الشيت أيضًا، فيبقى الشيت السجل المقروء مهما كان مكان التحرير.'
                '🛟 إن رفض الشيت الحفظ لا يتأثر ما على الهواء: الشريط منشور، ويصلك أن الحفظ في الشيت وحده فشل.'
            ) }
        @{ Version = '6.8.0'; Items = @(
                '🚀 «بداية سريعة»: بطاقة واحدة تأخذ من لم يستخدم البوت قط إلى أول قالب على الهواء في ست خطوات.'
                '📖 المساعدة صارت فهرس أبواب: اضغط الباب الذي يخصّك بدل قراءة دليل كامل بحثًا عن سطر.'
                '⬅️➡️ داخل كل باب أزرار السابق والتالي والفهرس، ومن يريد الدليل كاملًا يجده كما كان.'
                '🔒 سحب الشيت صار يحترم قفل المسودة: لا يستطيع مشغّل محو مسودة زميله، بل يطلب فكّ القفل كبقية الشاشات.'
            ) }
        @{ Version = '6.7.0'; Items = @(
                '⚠️ زرّا سحب الشيت صارا يطلبان تأكيدًا دائمًا قبل التنفيذ، فلا تعيد نقرة عابرة كتابة الشريط.'
                '🔎 رسالة التأكيد تقول ماذا سيحدث بالضبط: كم خبرًا سيُستبدل، ومَن يحرّر المسودة الآن إن وُجد.'
            ) }
        @{ Version = '6.6.0'; Items = @(
                '👥 زرّا سحب الشيت («سحب ونشر» و«سحب إلى المسودة») صارا متاحين لكل المشغّلين، لا للمشرفين وحدهم.'
                '🔔 صار تنبيه المزامنة يصل الجميع افتراضيًا، فيعرف الفريق كله بما تغيّر على الشريط.'
                '🔐 يستطيع المشرف إعادة السحب للمشرفين فقط من إعداد «سماح المشغّلين بسحب الشيت».'
            ) }
        @{ Version = '6.5.0'; Items = @(
                '📝 زر «سحب إلى المسودة» يجلب الشيت للمراجعة بدل النشر الفوري — راجع ورتّب وصحّح، ثم انشر.'
                '⬇️ زر «سحب ونشر» يبقى كما هو لمن يريد الشيت على الهواء مباشرة.'
                '🔔 صار بإمكانك اختيار من يُنبَّه بعد كل مزامنة: لا أحد، أو المشرفون، أو كل المستخدمين المصرّح لهم.'
            ) }
        @{ Version = '6.4.0'; Items = @(
                '📊 صار الشريط يُحدَّث من Google Sheets مباشرة. اكتب الخبر في الشيت وهو يصل الهواء دون أي برنامج وسيط.'
                '⬇️ زر «سحب من الشيت» في شاشة الأخبار يجلب الآن فورًا؛ أو اضبط المزامنة تلقائية كل عدة دقائق.'
                '🔒 المزامنة التلقائية لا تدهس مسودة يحرّرها أحد: تتخطّى الدورة وتعيد المحاولة، ولا يضيع ما كتبته.'
                '🛟 الشيت الفارغ لا يمسح الشريط — يُرفض التحديث بدل أن يترك الشاشة بلا أخبار.'
            ) }
        @{ Version = '6.3.0'; Items = @(
                '🔖 كل عملية في «عملياتي» صار لها مرجع قصير. اذكره للمشرف وهو يجد سطرها في السجل مباشرة.'
                '🗂 «ملفات التشغيل» شاشة جديدة في مركز الصحة: تقول أي ملف حالة سليم، وأيّهما تالف، وأيّهما له نسخة احتياطية تُستعاد وحدها.'
                '📈 مركز الصحة صار يعرض سطر استخدام: عمليات اليوم، عدد المشغّلين، كم على الهواء، ومنذ متى يعمل الجسر.'
            ) }
        @{ Version = '6.2.0'; Items = @(
                '🧹 إصدار صيانة: لا شيء تغيّر في أي شاشة أو زر أو أمر. العمل كله داخلي.'
                '🕒 «ماذا فاتني» صارت تقرأ أوقات سجل التدقيق بنفس الطريقة التي تقرأ بها بقية الشاشات، فلا تختلف الساعة بين شاشة وأخرى.'
                '✅ الاختبارات أعيد تنظيمها ووُسّعت لتغطي «استعادة الافتراضي» و«البحث» في الإعدادات، وهما مساران لم يكن يحرسهما اختبار.'
            ) }
        @{ Version = '6.1.0'; Items = @(
                '📊 زر «تقارير» جديد: البنرات (ماذا ظهر، بأي نص، ومتى اختفى) والأخبار (النشر اليومي وعدد الأخبار).'
                '⬇️ أي تقرير يُحمَّل ملفًا يُفتح في المتصفح، ومنه تطبعه PDF بعربية سليمة.'
                '🧾 «عملياتي» صارت تُكتب بالعربية وتعرض النص الذي ظهر على الهواء، بدل رموز تقنية وأرقام مللي ثانية.'
                '🕘 «ماذا فاتني» توضّح مَن نفّذ ماذا: مجموع العمليات، وتوزيع القالب المشترك على مشغّليه.'
                '📜 «السجل» و«عملياتي» لم تعودا تفرغان بعد إعادة تشغيل الجسر؛ تُستعادان من سجل التدقيق الدائم.'
            ) }
        # One entry per shipped release. The -preview.N milestones were internal
        # steps toward 6.0.0 and never reached an operator, so they are folded
        # in here rather than listed as four near-identical versions.
        @{ Version = '6.0.0'; Items = @(
                '⚙️ الإعدادات أصبحت أقسامًا عربية قصيرة موزعة على صفحات، وكل بند يعرض حالته أو قيمته الحالية في صف كامل.'
                '🩺 مركز صحة جديد يجمع Telegram وCinegy والمخرج والبث والتخزين والجدولة في شاشة واحدة للمشرف.'
                '🚨 أوامر الإخفاء والخروج تتقدم داخل دفعة Telegram، والتحديث المكرر لا يُنفذ مرتين.'
                '⏱ مؤقت الإخفاء يتابع معرّف Cinegy الصحيح لنفس القالب ولا يلغي نفسه بعد العرض.'
                '🔔 تنبيه القالب يتيح تأكيد المعالجة، ويرسل متابعة واحدة إذا لم يؤكده المستخدم.'
                '📄 إدارة القوالب والمستخدمين وطلبات الوصول تعمل بصفحات آمنة حتى مع الأعداد الكبيرة.'
                '👥 المشرف يرى نشاط المستخدمين التقريبي حسب آخر تفاعل، دون ادعاء حالة اتصال لحظية.'
                '📜 «السجل» و«عملياتي» تبقيان ممتلئتين بعد إعادة التشغيل، ويظهر Alias المشغّل مع معرّفه الثابت.'
            ) }
        @{ Version = '5.7.9'; Items = @(
                '👤 طلبات الوصول ما زالت متاحة للمستخدمين، لكن زر قبول أو رفض الطلبات يظهر للمشرف والمالك فقط.'
                '🛡️ فحص التشغيل الأحادي متسامح افتراضيًا عند تعذّر إنشاء القفل؛ استخدم -RequireSingleInstance للتشدد.'
                '📦 ملفات إعدادات الجسر وتعريفات القوالب تقبل الآن حتى 10 ميغابايت.'
            ) }
        @{ Version = '5.7.7'; Items = @(
                '📸 كل لقطة من البث توضح الآن مصدرها: الأساسي أو Cinegy الاحتياطي.'
            ) }
        @{ Version = '5.7.6'; Items = @(
                '🔔 من تفاصيل كل قالب، يضبط المشرف أو المالك تنبيه الظهور بالدقائق (0 لإيقافه).'
                '⏰ التنبيه يصل للشخص الذي أظهر القالب فقط، ويُحفظ ليستمر بعد إعادة التشغيل.'
                '🟣 القالب Long run مثل الشعار أو الشريط 24/7 لا يأخذ تنبيه ظهور.'
            ) }
        @{ Version = '5.7.5'; Items = @(
                '⏱ مؤقت العرض يُحفظ ويُستعاد بعد إعادة تشغيل الجسر، ثم يُكمل المدة المتبقية.'
                '🛡️ إذا تغيّر المشهد على الطبقة، يُلغى المؤقت القديم حتى لا يخفي المشهد الجديد.'
            ) }
        @{ Version = '5.7.4'; Items = @(
                '⚠️ مراقب المخرج ينبه الآن إذا تعذّر التقاط المصدر، لا للشاشة السوداء فقط.'
                '🔁 عند تعذّر المصدر الأساسي يتحول فورًا إلى مصدر Cinegy الاحتياطي، واللقطة تعيد المحاولة منه تلقائيًا.'
                'مصدر الاحتياط لقناة Cinegy 0 هو معاينة SRT المحلية: srt://127.0.0.1:5421.'
                '📡 الحالة الكاملة تفحص المصدر يدوياً وتوضح حالة سيرفر المتابعة؛ الزر متاح للمشرف والمالك.'
                '📅 الأحداث المجدولة تبقى بعد إعادة تشغيل الجسر؛ وعند حلول المؤقت يُفحص القالب الحالي ثم طبقة Cinegy قبل SHOW.'
            ) }
        @{ Version = '5.7.3'; Items = @(
                'إصلاح: أعمار المشاهد كانت ما تزال بالثواني — «107775 ثانية» بدل «يوم و5 ساعات و56 دقيقة».'
                'وسطر آخر فحص ناجح يقول «الآن» بدل «منذ 0 ثانية».'
            ) }
        @{ Version = '5.7.2'; Items = @(
                '⏱ الأوقات في شاشات الحالة صارت مقروءة: «يوم وساعتان» بدل «1560 دقيقة».'
                '«آخر فحص ناجح» يبدأ بالمدّة لا بالتاريخ، ووقت الساعة بين قوسين.'
                '🗄 سجل التدقيق يُؤرشف تلقائيًا عند 110 ميغابايت في ملف مستقل — بلا حذف.'
                'و«ماذا فاتني» تقرأ من الأرشيف أيضًا، فلا يضيع تاريخ بعد الأرشفة.'
            ) }
        @{ Version = '5.7.1'; Items = @(
                '❤️ تنبيهات صحة Cinegy صارت أهدأ: الإطارات الساقطة تُقاس كنسبة من الخرج لا كعدد مجرّد.'
                '34 إطارًا من 1467 هي 2٪ ولم تعد تستحق تحذيرًا، والحالة لا تتغيّر إلا بعد ثلاثة فحوص متّفقة.'
                '🖤 شرح مراقبة المخرج وأرقام الصحة صار في ❓ المساعدة للمشرفين.'
                '📝 مهلة مسودة الأخبار صارت ساعتين بدل نصف ساعة، وقابلة للضبط من الإعدادات.'
                'وعند انتهاء المهلة تُعاد إليك الأخبار نصًّا بدل إبلاغك بعددها فقط.'
                '⏱ المدد تُكتب بالساعات: «20 ساعة» بدل «1200 دقيقة».'
            ) }
        @{ Version = '5.7.0'; Items = @(
                '📰 الخبر الجديد يُضاف الآن في أول الشريط لا آخره (يمكن عكسه من الإعدادات).'
                '➕ إضافة قالب صارت تقبل مسار المشهد الحقيقي: قرص، أو شبكة، أو %PROGRAMDATA%.'
                'ويمكن إعطاء اسم جهاز مثل logo بدل رقم الطبقة، مع تنبيه إن كانت الطبقة مستخدَمة.'
                'وخطوة أخيرة اختيارية للوصف والتصنيف، تُتخطّى بكلمة واحدة.'
                '⚙️ أوامر المشرفين لم تعد تظهر في قائمة الأوامر لغير المشرفين.'
                '👑 صلاحية المالك: هو وحده من يعيّن المشرفين أو يخفضهم، من شاشة 👥 المستخدمون.'
                'المالك افتراضيًا أول مشرف في config، ويمكن تحديده صراحةً بـ OwnerUserIds.'
                'الترقية والخفض بتأكيد، ويصل إشعار للمستخدم بتغيّر صلاحيته.'
                'لا يمكن خفض المالك ولا آخر مشرف، ولا ترقية مستخدم غير مصرّح له.'
            ) }
        @{ Version = '5.6.1'; Items = @(
                'إصلاح: لم يعد الشريط الإخباري والشعار يُبلَّغ عنهما كـ«قالب قديم على الهواء» وهما يعملان سليمَين.'
                'الجسر صار يقرأ المدّة التي حدّدها Cinegy للقالب — ٢٤ ساعة للشريط — ويحترمها.'
                'ويمكن تعليم أي قالب بـ longRunning في ملف القوالب ليُعفى دائمًا.'
                'صحة Cinegy لم تعد تتقلّب بسبب إطار واحد مفقود؛ صار لها هامش تسامح قابل للضبط.'
            ) }
        @{ Version = '5.6.0'; Items = @(
                'إصلاح: زر ♻️ إعادة التشغيل يعمل الآن حين يكون البوت مشغَّلًا يدويًا — يعيد نفسه في نفس النافذة.'
                'أسماء أزرار القوالب صارت الاسم وحده، بلا أرقام ولا تواريخ مقطوعة.'
                'التفاصيل (الطبقة، التصنيف، الحقول، آخر استخدام) في شاشة ℹ️ بجانب كل قالب.'
                '🕘 ماذا فاتني صارت تقول ماذا عُرض ومَن عرضه ومتى، وما الذي فشل ولماذا.'
                'تأكيد قبل إخفاء قالب على الهواء، فلا تُخفيه بضغطة واحدة.'
                'دعم طبقة الشعار الخاصة في Cinegy عبر خيار device في القالب.'
                'قائمة ترتيب الأخبار صارت مقسّمة صفحات — كل الأخبار قابلة للوصول، بما فيها الأخير.'
                'خيار جديد: قائمة أخبار واحدة طويلة بدل الصفحات — أطفئ «قائمة الأخبار على صفحات».'
                'القائمة الطويلة تعرض ٢١ خبرًا في الشاشة بدل ١٠، وما زاد يبقى على صفحات لأن تيليجرام لا يقبل أكثر.'
                'حذف خبر مباشرة من قائمة الترتيب مع تأكيد.'
            ) }
        @{ Version = '5.5.0'; Items = @(
                'شريط الأخبار: عند تعارض الملف يمكنك الإضافة إلى النص الحالي أو استبداله.'
                'طلب فكّ قفل المسودة من زميل، مع مهلة للرد ومنح تلقائي بعدها.'
                'تُعاد إليك أخبار مسودتك نصًّا قبل تسليم القفل.'
                'إصلاح: مسودة قديمة كانت تمنع النشر إلى الأبد — صار لها مهلة.'
            ) }
        @{ Version = '5.4.0'; Items = @(
                'إصلاح: لم يعد يظهر قالب وهمي على الهواء عند الإقلاع.'
                'التراجع صار يشمل العرض على طبقة فارغة — يزيله بضغطة.'
                'عند التعارض يظهر اسم من يجهّز الطبقة ومنذ متى.'
                'بعد التراجع يسألك عن السبب — لتحسين التدريب لاحقًا.'
                '🕘 ماذا فاتني و/who لمعرفة من استخدم قالبًا ومتى.'
                'تنبيه عند تكرار القالب ثلاث مرات في ساعة.'
                'وضع ليلي يؤجّل التنبيهات غير العاجلة، ونافذة صيانة تلقائية.'
                'وضع اليد الواحدة، واختصار بكتابة اسم القالب مباشرة.'
            ) }
        @{ Version = '5.3.0'; Items = @(
                '📷 لقطة الآن بجانب صفّ الهواء — تتحقق من الشاشة دون مغادرة المحادثة.'
                '📋 نسخ الحالة: ملخص نصّي جاهز للإرسال إلى المخرج.'
                '📈 أرقام التشغيل و/stats للمشرف: مدة التشغيل وحصيلة العمليات.'
                'تنبيه قبل الحدث المجدول بثلاث دقائق، مع حالة Cinegy.'
            ) }
        @{ Version = '5.2.0'; Items = @(
                'زر ↩️ تراجع صار يظهر في القائمة الرئيسية طوال مهلته، لا في رسالة العملية فقط.'
                'المشرف يستطيع العرض على طبقة محجوزة مع تنبيه؛ المشغّل ما زال ممنوعًا.'
                'تنبيه عندما يستبدل حدث مجدول مشهدًا موجودًا على الهواء.'
                '📊 ملخص الاستخدام: أكثر القوالب استخدامًا وحصيلة العمليات، عند الطلب وأسبوعيًا.'
                '📤 تصدير و📥 استيراد الإعدادات لنقلها بين الأجهزة بلا توكن ولا قائمة مستخدمين.'
            ) }
        @{ Version = '5.1.0'; Items = @(
                'القائمة تبدأ بما هو على الهواء، وتحته زر إخفاء الكل مباشرة.'
                'سطر أعلى القائمة يقول ما هو على الهواء ومتى تم آخر تحقّق منه.'
                'أدوات الإدارة صارت في شاشة مستقلة لتقصير القائمة الرئيسية.'
                'يمكن تفعيل تأكيد قبل الإخفاء والخروج يعرض اسم القالب ومدّته ومَن أرسله.'
                'مراقبة تلقائية لصورة المخرج: عند تأكيد شاشة سوداء بلقطتين يصل تنبيه.'
                'تنبيه للمشرفين عن أي قالب بقي مسجّلًا على الهواء مدة طويلة.'
                'الملفات التي ترفعها تُحذف تلقائيًا بعد مدة قابلة للضبط.'
                'زر «فحص المسار الحي» يختبر دورة عرض وإخفاء كاملة على طبقة التجربة.'
            ) }
        @{ Version = '5.0.1'; Items = @(
                'إصلاح: الخروج من مشهد كان يترك سجلًا دائمًا يوهم بأن القالب ما زال على الهواء.'
            ) }
        @{ Version = '5.0.0'; Items = @(
                'استقرار أعلى عند انقطاع Cinegy: لم يعد البوت يتجمّد في انتظاره.'
                'الرسائل لم تعد تُفقد عند ازدحام Telegram.'
                'رفض ضبط طبقة التجربة على طبقة يستخدمها قالب إنتاج.'
            ) }
        @{ Version = '4.x — ملخص'; Items = @(
                'الأساس: عرض القوالب بحقول نصية، وإخفاء وخروج، وتحديث النص أثناء العرض.'
                '⭐ المفضّلة و🔁 التكرار و⏱ العرض المؤقّت و📅 الجدولة بتكرار يومي وأسبوعي.'
                '📰 إدارة شريط الأخبار بمسودة ومعاينة ونسخ احتياطية.'
                '📸 لقطات من البث و▶️ البث المباشر إلى Telegram.'
                '🎚 لوحة الطبقات تقارن Cinegy بسجل الجسر وتكتشف المشاهد الخارجية.'
                '👥 إدارة المستخدمين والأسماء وطلبات الوصول، مع سجل تدقيق دائم.'
                '🛡️ وضع الصيانة وحماية الأسرار وتقييد صلاحيات الملفات.'
            ) }
    )
}

function Get-WhatsNewText {
    <#
        The whole history as one string. Get-WhatsNewParts is what the screen
        actually sends; this stays for anything that wants the lot.

        HTML, because this screen is a list of releases inside a list of
        changes and plain text gave both the same weight: the version a line
        belongs to read exactly like the change itself. The tags stay inside
        one line each - the splitter cuts on line boundaries, and a tag cut in
        half is a message Telegram refuses outright.
    #>
    param([int]$Skip = 0, [int]$Take = 0, [switch]$NoHeading)
    $sections = @(Get-WhatsNewSections)
    if ($Skip -gt 0) { $sections = @($sections | Select-Object -Skip $Skip) }
    if ($Take -gt 0) { $sections = @($sections | Select-Object -First $Take) }

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $NoHeading) { $lines.Add((T 'whatsnew.title' $($script:BridgeVersion))) }
    else { $lines.Add((T 'whatsnew.olderReleases')) }
    foreach ($section in $sections) {
        $lines.Add('')
        $lines.Add("<b>▪️ $(ConvertTo-TelegramHtmlText -Text ([string]$section.Version))</b>")
        foreach ($item in $section.Items) { $lines.Add("• $(ConvertTo-TelegramHtmlText -Text ([string]$item))") }
    }
    $lines.Add('')
    $lines.Add((T 'whatsnew.fullLog'))
    return ($lines -join "`n")
}

function Get-WhatsNewParts {
    <# The newest few releases, then everything older behind 📄 المزيد. Split
       at a version boundary rather than at a character count, so the first
       screen ends where a release ends instead of mid-sentence. #>
    param([int]$LeadVersions = 3)
    $total = @(Get-WhatsNewSections).Count
    $parts = @((Get-WhatsNewText -Take $LeadVersions))
    if ($total -gt $LeadVersions) { $parts += (Get-WhatsNewText -Skip $LeadVersions -NoHeading) }
    return $parts
}

function Get-WhatsNewKeyboard {
    <# The release notes with the technical log behind a button. The screen
       says what changed on an operator's screen; CHANGELOG.md says why, in
       the maintainer's words, and it ships beside the bridge - so the answer
       to "where is the full history" is a file, not a paragraph asking
       somebody to open the server. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $rows = @(, @((New-Button (T 'whatsnew.technicalLog') 'menu:changelog')))
    return @{ inline_keyboard = $rows + @($menu.inline_keyboard) }
}
