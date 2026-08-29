# Release, upgrade, and rollback

## First install

Copy `config.example.json` to `config.json`, fill in the bot token and at
least one `AdminChatIds` entry, then check the machine before registering
anything around the bridge:

```powershell
.\scripts\Test-BridgeReadiness.ps1
```

It is read-only and contacts nothing. Exit code 0 means the bridge will run;
1 means it would not, and prints why. Both installers run it first and refuse
to register a service over a configuration that cannot start - a supervisor
wrapped around a broken config produces a bridge that crashes and is
restarted for ever while `services.msc` shows it Running.

Then install one of:

```powershell
.\scripts\Install-BridgeTask.ps1              # built-in Task Scheduler
.\scripts\Install-BridgeService-NSSM.ps1      # real Windows service, needs nssm.exe
```

Both default to running as `SYSTEM`. Pass `-RunAsAccount` to use another
account, and note the trap it exists to catch: **DPAPI secrets are protected
for one account only.** If you run `Protect-BridgeSecrets.ps1` as yourself and
then install the service as `SYSTEM`, the bridge cannot decrypt its own token.
The readiness check refuses that combination by name.

After starting, both installers wait and then confirm the bridge actually came
up, by reading `logs\bridge.log` rather than trusting the service state: a
crash loop reports Running most times you look at it.
## Build and verify

Run on Windows with PowerShell 7:

```powershell
.\Build-Release.ps1
Get-FileHash .\dist\CinegyTelegramBridge-<version>.zip -Algorithm SHA256
```

Compare the result with the adjacent `.zip.sha256` file. To Authenticode-sign
the copied PowerShell files before packaging, provide a code-signing
certificate installed in `Cert:\CurrentUser\My`:

```powershell
.\Build-Release.ps1 -CodeSigningThumbprint '<thumbprint>'
```

The package is allow-listed and never contains `config.json`, `templates.json`,
`logs/`, backups, snapshots, audit history, or on-air state.

## Version 6 merge handoff

The `codex/v6-current-experience` branch is the release handoff branch for
Version 6. Merge it into `main` only after the following checks are recorded:

1. Confirm the branch version in `TelegramBridge.ps1` matches the ZIP and its
   `release-manifest.json`.
2. Verify the checksum and run `.\Run-Checks.ps1` from a clean checkout.
3. Keep the existing `config.json`, `templates.json`, and `logs` outside Git;
   Version 6 keeps their formats compatible and does not require copying a
   generated runtime directory from the branch.
4. Deploy the extracted ZIP beside the current installation, run the readiness
   check, then switch the task/service during an approved change window.
5. Retain the previous installation directory and the verified ZIP until the
   first operational review is complete. Use the rollback procedure below if
   readiness or startup validation fails.

The package is intentionally unsigned when no certificate is supplied to
`Build-Release.ps1`; record that fact in the change ticket and sign the same
allow-listed package through the site's certificate process when required.

## Upgrade

1. Keep the current installation directory as the rollback copy.
2. Stop the scheduled task or NSSM service.
3. Back up `config.json`, `templates.json`, and the complete `logs` directory.
4. Verify the ZIP checksum and, for a signed build, each script's
   Authenticode status with `Get-AuthenticodeSignature`.
5. Extract the release to a new directory; do not extract over the running
   installation.
6. Copy the existing `config.json`, `templates.json`, and `logs` directory into
   the new directory.
7. Run `.\scripts\Test-BridgeReadiness.ps1` against the new directory, then
   `.\Run-Checks.ps1`. Perform the Telegram/Cinegy smoke test only in a lab, on
   a dedicated non-production layer, or during an explicitly approved change
   window.
8. If the only target is a live working environment without an isolated layer,
   do not send test SHOW/HIDE/EXIT commands. Record the production-safety waiver,
   retain the rollback directory, and switch the task or service through the
   site's controlled deployment procedure.

## Rollback

1. Stop the new bridge instance.
2. Point the scheduled task or NSSM service back to the previous installation.
3. Copy only newer runtime state needed for continuity (`logs\onair.json`, its
   `.bak`, and `logs\schedule.json` with its `.bak`) after validating the JSON.
4. Start the previous version and use the manual Cinegy comparison from the
   layer status screen. Do not clear an uncertain layer.
5. Record the rollback reason and retained version in `bridge.log` or the
   operational change record.
