# Web and Bot Feature Parity

**Goal** — Let newsroom operators complete their existing bot workflows from the browser using the same bridge and authorization rules.

**Architecture** — React and Mantine provide the Arabic RTL interface. The ASP.NET Core server authenticates sessions and carries typed requests to the local pipe. The bridge executes commands on its own thread and owns concurrency, authorization, scheduling, and Cinegy state.

| Workflow | In the web interface | Remaining work |
|---|---|---|
| Air and templates | Live layers, searchable library, Show, Hide, Exit | Live text editing, presets, rehearsals, reruns, rollback, emergency and maintenance actions, template registration and editing |
| Breaking news | Default editable table, row selection, automatic run preview and playback, pause, resume, advance and stop retry | Timing settings, rehearsal, single-story and timed manual playback |
| Bulletins | Shared library and paginated design-field table, create and copy, revision-checked row editing and batch paste, built-in timing, on-air indicator | Attachments, design switching, preview, run control and schedules. Playback must use the selected design's scene and variables before enabling alternate designs on air. |
| Ticker | Paged published list, shared draft lock and handover, editing and reordering, reviewed publication and conflict resolution, paused headlines and scheduled publication controls | Sets, backups and Google Sheets sync controls |
| Program content | | Board, fields and media, draft control, publish and live editing |
| Shift and monitoring | Air status, connectivity, live output player with picture-in-picture while editing, feed outage history, Telegram relay controls, snapshots and clips | Template and material schedule, incident and operation history, notifications, reports and exports |
| Administration | Web accounts and sessions | Bot access requests and roles, settings, health tools, audit and announcements |

## Newsroom implementation order

- [x] Map ticker draft, lock, reorder, handover and publish commands to `Parts/Bridge.News.ps1`. Test competing editors, stale edits, publication conflicts and a successful publish into temporary storage.
- [x] Add controls for ticker scheduling and the shared paused headline list.
- [ ] Add controls for saved sets, backup restore and sheet sync.
- [x] Use the template fields as urgent table columns. Save inline edits with the board revision and stable item IDs, and keep extra fields in playback.
- [x] Use the existing urgent planner and playback engine for review, start and sequence controls. Test revoked access, a changed board between review and confirm, and a failed stop on a simulated scene.
- [ ] Expose urgent timing settings, rehearsal and individual show actions through their existing bridge policies.
- [x] Connect the bulletin library and editor to `Parts/Bridge.Mojaz.ps1` and the shared library module. Test stale revisions, preserving existing media, and rejecting file paths in text edits.
- [x] Review bulletin paste against the selected design's columns and save the approved rows atomically. Expose the built-in design's shared frame timing.
- [ ] Complete bulletin attachments and scheduling using the existing bot rules. Route a run through its selected scene and test recovery and the existing urgent conflict rules before adding web playback.
- [ ] Extend the news views with program boards from `Parts/Bridge.Boards.ps1`. Test upload validation, shared ownership and role restrictions before exposing actions.

## Acceptance for each workflow

- [ ] Exercise the browser flow with both operator and administrator accounts wherever their actions differ.
- [ ] Test the real pipe against simulated station state and verify the public API contract and generated client types.
- [ ] Check Arabic layout and keyboard interactions at desktop and phone widths, including empty, loading and error states.
- [ ] Verify that changes from Telegram are visible in the browser and changes from the browser are visible to the bot.
- [ ] Run the full release gate and update the operator-facing release notes.
