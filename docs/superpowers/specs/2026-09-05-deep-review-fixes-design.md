# Deep Review Fixes Design

The bridge must revalidate authorization and live-scene identity at execution time, because a pending prompt, confirmation button, or restored timer can outlive the state that originally authorized it. Revoking a user clears their pending flow, explicit owners cannot be revoked through administrator controls, and confirmed removal callbacks repeat the template-access check.

Mojaz restoration persists the template image and confirmed active identity, sends the row that should currently be visible before declaring the run restored, and refuses an automatic exit when Cinegy cannot prove that the same scene is still active. Runtime JSON writes prepare and install the backup before committing the new primary, using unique temporary files.

The manager waits for process exit before restart, cancels queued automatic restarts when disabled, and merges unchanged permission arrays from the latest configuration under a cross-process configuration lock. Telegram startup draining remains closed until successful, and flood-control delays are represented without sleeping the bridge tick thread. Report periods use exclusive upper bounds, sheet imports validate before replacing drafts, and relay verification failures return to the configured retry policy.

All behavior changes require regression tests, bridge and manager version synchronization, operator-facing release notes, and the full release gate.
