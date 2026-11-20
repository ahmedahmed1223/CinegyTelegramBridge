# Web and Bot Feature Parity

**Goal** — Let newsroom operators complete their existing bot workflows from the browser using the same bridge and authorization rules.

**Architecture** — React and Mantine provide the Arabic RTL interface. The ASP.NET Core server authenticates sessions and carries typed requests to the local pipe. The bridge executes commands on its own thread and owns concurrency, authorization, scheduling, and Cinegy state.

| Workflow | In the web interface | Remaining work |
|---|---|---|
| Air and templates | Live layers, searchable library, Show, Hide, Exit | Live text editing, presets, rehearsals, reruns, rollback, emergency and maintenance actions, template registration and editing |
| Breaking news | Default editable table, row selection, automatic run preview and playback, pause, resume, advance and stop retry | Timing settings, rehearsal, single-story and timed manual playback |
| Bulletins | Saved library, row counts and on-air indicators | Row editor, images and paste, design and timing, revisions, preview, run control and schedules |
| Ticker | Paged published list, shared draft lock and handover, editing and reordering, reviewed publication and conflict resolution | Pause and resume headlines, scheduled publish controls, sets, backups and Google Sheets sync controls |
| Program content | | Board, fields and media, draft control, publish and live editing |
| Shift and monitoring | Air status and connectivity | Template and material schedule, watch page, incident and operation history, notifications, reports and exports |
| Administration | Web accounts and sessions | Bot access requests and roles, settings, health tools, audit and announcements |

## Newsroom implementation order

- [x] Map ticker draft, lock, reorder, handover and publish commands to `Parts/Bridge.News.ps1`. Test competing editors, stale edits, publication conflicts and a successful publish into temporary storage.
- [ ] Add controls for ticker scheduling, paused headlines, saved sets, backup restore and sheet sync.
- [x] Use the template fields as urgent table columns. Save inline edits with the board revision and stable item IDs, and keep extra fields in playback.
- [x] Use the existing urgent planner and playback engine for review, start and sequence controls. Test revoked access, a changed board between review and confirm, and a failed stop on a simulated scene.
- [ ] Expose urgent timing settings, rehearsal and individual show actions through their existing bridge policies.
- [ ] Use `Parts/Bridge.Mojaz.ps1`, `Parts/Bridge.Mojaz.Screens.ps1` and `Parts/Bridge.Mojaz.Playback.ps1` for bulletin rows, designs, timing and scheduling. Test stale revisions, unsupported media, and the existing urgent and bulletin conflict rules.
- [ ] Extend the news views with program boards from `Parts/Bridge.Boards.ps1`. Test upload validation, shared ownership and role restrictions before exposing actions.

## Acceptance for each workflow

- [ ] Exercise the browser flow with both operator and administrator accounts wherever their actions differ.
- [ ] Test the real pipe against simulated station state and verify the public API contract and generated client types.
- [ ] Check Arabic layout and keyboard interactions at desktop and phone widths, including empty, loading and error states.
- [ ] Verify that changes from Telegram are visible in the browser and changes from the browser are visible to the bot.
- [ ] Run the full release gate and update the operator-facing release notes.
