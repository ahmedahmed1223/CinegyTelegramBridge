# Web and Bot Feature Parity

**Goal** — Let newsroom operators complete their existing bot workflows from the browser using the same bridge and authorization rules.

**Architecture** — React and Mantine provide the Arabic RTL interface. The ASP.NET Core server authenticates sessions and carries typed requests to the local pipe. The bridge executes commands on its own thread and owns concurrency, authorization, scheduling, and Cinegy state.

| Workflow | In the web interface | Remaining work |
|---|---|---|
| Air and templates | Live layers, searchable library, Show, Hide, Exit | Live text editing, presets, rehearsals, reruns, rollback, emergency and maintenance actions, template registration and editing |
| Breaking news | Default editable table, row selection, shared timing defaults and per-story overrides, automatic run preview and playback, pause, resume, advance, stop retry, reviewed single-story and timed playback, isolated rehearsal | Cross-client acceptance checks |
| Bulletins | Shared library and paginated design-field table, create and copy, design switching, revision-checked row editing and batch paste, built-in timing, on-air indicator | Attachments, preview, run control and schedules. Playback must use the selected design's scene and variables before enabling alternate designs on air. |
| Ticker | Paged published list, shared draft lock and handover, lock requests and administrative release, editing and reordering, reviewed publication and conflict resolution, paused headlines, scheduled publication, saved sets, reviewed backup restore and Google Sheets import/publication, reviewed batch paste and TXT import, clearing and cancelling drafts | Cross-client acceptance checks |
| Program content | | Board, fields and media, draft control, publish and live editing |
| Shift and monitoring | Air status, connectivity, live output player with picture-in-picture while editing, feed outage history, Telegram relay controls, snapshots and clips | Template and material schedule, incident and operation history, notifications, reports and exports |
| Administration | Web accounts and sessions | Bot access requests and roles, settings, health tools, audit and announcements |

## Newsroom implementation order

- [x] Map ticker draft, lock, reorder, handover and publish commands to `Parts/Bridge.News.ps1`. Test competing editors, stale edits, publication conflicts and a successful publish into temporary storage.
- [x] Add controls for ticker scheduling and the shared paused headline list.
- [x] Add controls for shared saved sets.
- [x] Add reviewed backup restore.
- [x] Add reviewed Google Sheets import into the draft and direct publication.
- [x] Add reviewed bulk text entry, clearing and explicit discard.
- [x] Add ticker lock requests and administrative release. Reuse the bridge's request window and reservation, bind responses to the individual request, and preserve the reviewed draft on web handover. Verify a stale response, competing editors, deadline settlement and administrator access through the local pipe.
- [x] Add reviewed ticker TXT import using the shared UTF-8 parser and configured upload and headline limits.
- [x] Use the template fields as urgent table columns. Save inline edits with the board revision and stable item IDs, and keep extra fields in playback.
- [x] Use the existing urgent planner and playback engine for review, start and sequence controls. Test revoked access, a changed board between review and confirm, and a failed stop on a simulated scene.
- [x] Expose shared urgent board timing defaults with the bot's bounds and revision-checked edits.
- [x] Expose per-story timing overrides and inheritance through the existing board writer and planner.
- [x] Expose reviewed individual show, timed show and identity-checked hide via the existing bridge policies.
- [x] Expose rehearsal on the configured test layer using the existing bridge policies.
- [x] Connect the bulletin library and editor to `Parts/Bridge.Mojaz.ps1` and the shared library module. Test stale revisions, preserving existing media, and rejecting file paths in text edits.
- [x] Review bulletin paste against the selected design's columns and save the approved rows atomically. Expose the built-in design's shared frame timing.
- [x] Switch an existing bulletin to another usable design while preserving its rows and attachments. Reject a stale edit or a bulletin on air.
- [ ] Complete bulletin attachments and scheduling using the existing bot rules. Route a run through its selected scene and test recovery and the existing urgent conflict rules before adding web playback.
- [ ] Extend the news views with program boards from `Parts/Bridge.Boards.ps1`. Test upload validation, shared ownership and role restrictions before exposing actions.

## Acceptance for each workflow

- [ ] Exercise the browser flow with both operator and administrator accounts wherever their actions differ.
- [ ] Test the real pipe against simulated station state and verify the public API contract and generated client types.
- [ ] Check Arabic layout and keyboard interactions at desktop and phone widths, including empty, loading and error states.
- [ ] Verify that changes from Telegram are visible in the browser and changes from the browser are visible to the bot.
- [ ] Run the full release gate and update the operator-facing release notes.
