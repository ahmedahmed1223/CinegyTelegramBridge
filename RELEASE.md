# Release, upgrade, and rollback

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
7. Run `.\Run-Checks.ps1`, then start the bridge and perform the Telegram/Cinegy
   smoke test described in the development plan.
8. Switch the scheduled task or service to the new directory only after the
   smoke test succeeds.

## Rollback

1. Stop the new bridge instance.
2. Point the scheduled task or NSSM service back to the previous installation.
3. Copy only newer runtime state needed for continuity (`logs\onair.json`, its
   `.bak`, and `logs\schedule.json` with its `.bak`) after validating the JSON.
4. Start the previous version and use the manual Cinegy comparison from the
   layer status screen. Do not clear an uncertain layer.
5. Record the rollback reason and retained version in `bridge.log` or the
   operational change record.
