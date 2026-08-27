# Cinegy Telegram Bridge Desktop Application Design

## Goal

Deliver a standalone Windows application that provides a full local management console for the existing Cinegy Telegram Bridge while a separately installed Windows service keeps Telegram, Cinegy, scheduling, monitoring, and alerts running when the desktop window is closed.

## Scope

The desktop application exposes every operational capability already available in Telegram: live layers, SHOW/HIDE/EXIT, text updates, templates and presets, timers, schedules, snapshots, source failover status, users and roles, audit history, diagnostics, configuration, backups, and health monitoring. Telegram remains supported as the remote operator interface.

The solution adds installation, service ownership, data migration, secure local control, diagnostics, and signed updates. It does not replace Cinegy Air Pro or change the existing Telegram command semantics.

## Architecture

```text
Desktop Window (WPF, .NET 8)
    │  named-pipe JSON RPC + per-install secret
    ▼
Windows Service (Worker Service, .NET 8)
    │  supervised local worker protocol
    ▼
PowerShell Bridge Runtime (existing TelegramBridge.ps1 initially)
    │
    ├── Telegram Bot API
    ├── Cinegy Air Pro HTTP control
    └── local persistent state

Standalone Updater (Updater.exe)
    └── stops service, verifies package, swaps files, starts service, rolls back
```

### Components

| Component | Responsibility |
|---|---|
| `CinegyBridge.Desktop` | WPF management window; no direct Telegram or Cinegy calls. |
| `CinegyBridge.Service` | Windows Service, runtime supervisor, local RPC endpoint, health/status cache, controlled restart. |
| `CinegyBridge.Contracts` | Versioned request, response, event, error, and role contracts shared by desktop and service. |
| `CinegyBridge.RuntimeHost` | Service-side adapter that starts and observes the existing PowerShell runtime in phase one, then hosts migrated .NET capabilities incrementally. |
| `CinegyBridge.Updater` | Separate executable used only during updates so in-use service files can be replaced safely. |
| `installer` | Signed setup package; installs app, service, updater, shortcuts, and migration wizard. |

The desktop process connects only to a named pipe owned by the local service. The pipe accepts the current Windows user only when the per-install secret and Windows access policy both validate. It is never exposed on the network.

## Data and migration

All mutable data lives below:

```text
%ProgramData%\CinegyTelegramBridge\
  config.json
  templates.json
  logs\
  schedules\
  backups\
  updates\
  runtime\
```

The installer detects an existing project-local bridge configuration, Scheduled Task, NSSM service, and currently running bridge process. It displays the detected items and does nothing until the operator confirms migration. Migration copies state to a timestamped backup, validates JSON, writes the new data store, and leaves the legacy installation intact until the new service has passed a health check. It never automatically stops the existing bot.

## Service operation

The service starts automatically with Windows and has service recovery configured. The setup wizard offers `LocalSystem` by default and a dedicated Windows account when Cinegy files, UNC paths, or DPAPI secret ownership require it.

The full desktop application may be opened while the service is stopped. It can inspect logs, edit draft configuration, validate prerequisites, and install or repair the service. Any on-air operation requires a healthy service.

The runtime host starts the existing bridge logic as a supervised local worker during the compatibility phase. It forwards status and commands through a versioned local protocol and records process exits, restart counts, and startup errors. The worker preserves the existing bot's behavior while desktop-facing actions are added one domain at a time. This avoids a one-time rewrite of Telegram and Cinegy logic.

## Desktop experience

The WPF navigation has these pages:

| Page | Main actions |
|---|---|
| Dashboard | Service, Telegram, Cinegy, primary/backup source, alerts, recent activity. |
| On Air and Layers | SHOW, HIDE, EXIT, text updates, active graphics, auto-hide timers, snapshots. |
| Templates | Definitions, fields, presets, `reminderMinutes`, `longRunning`, isolated testing. |
| Schedule | Create, edit, cancel, inspect execution and template validation status. |
| Users and roles | Users, requests, aliases, disabled state, owner/administrator/operator hierarchy. |
| Monitoring and logs | Output monitor, Cinegy health, source failover, filtered logs, diagnostic export. |
| Settings and service | Configuration, readiness, backups, install/start/stop/restart/repair service. |
| Updates | GitHub release status, local package installation, history, rollback state. |

Dashboard is deliberately action-oriented: active alerts and safe next actions are visible first. On-air controls and template administration are separate pages. Destructive or live-impacting actions use a review screen that states the target, current state, initiating Windows user, and backup consequence.

## Local authorization

The service identifies the connected Windows user from the named pipe identity. Read-only monitoring is allowed to configured local viewer accounts. Live operations and configuration require local operator/admin permissions. Owner-only actions retain the existing rule: owner > administrator > operator. An owner inherits administrator capabilities; an administrator never inherits owner-only role-management capabilities.

The initial setup wizard creates the first local owner from the installing Windows account. Existing Telegram owner configuration is preserved and remains authoritative for Telegram operations. Every desktop action is written to the existing audit trail with the Windows identity and, where applicable, the matching Telegram identity.

## Updates

### Release source

GitHub Releases is the initial update source. A future private web endpoint uses the same manifest contract and is selected through configuration; the desktop is not coupled to GitHub APIs outside the release-source adapter.

The update manifest contains version, release channel, published time, asset URI, SHA-256, Authenticode certificate subject/thumbprint, minimum supported database/configuration version, and release notes. The desktop compares stable releases by default; preview releases require explicit opt-in.

### Trust and rollback

An update is accepted only when all checks pass:

1. HTTPS download or explicitly chosen local file.
2. SHA-256 equals the signed manifest value.
3. Authenticode signature chains to the configured trusted publisher.
4. Package version and compatibility requirements are valid.

`Updater.exe` receives a short-lived, one-use plan from the service. It takes a versioned backup, stops the service, applies the package, starts the service, and waits for a bounded health check. If the service does not report healthy, it restores binaries and state and starts the previous version. The update is refused while a live-sensitive operation is in progress unless the owner explicitly confirms it.

## Test and CI strategy

| Layer | Coverage |
|---|---|
| Contracts | Serialization compatibility and rejected protocol versions. |
| Service | Pipe authorization, runtime restart policy, health state, data migration, update plan validation. |
| Desktop | View-model behavior, permission-driven controls, destructive-action review states. |
| Updater | Signature/hash validation, apply success, restart verification, automatic rollback. |
| Existing bridge | Existing Pester suite remains mandatory. |
| Windows CI | Install an isolated temporary service, start it, verify its startup log, stop it, uninstall it, and remove its workspace. |
| Staging | Dedicated configuration with all Cinegy commands blocked unless an explicit test endpoint is configured. |

The existing CI lifecycle script runs only with fake credentials and an isolated `ProgramData` workspace. It never reads or writes production `config.json`, logs, schedules, or templates.

## Delivery phases

1. **Foundation:** .NET solution, contracts, ProgramData layout, installer skeleton, named-pipe security, service installation and readiness page.
2. **Runtime compatibility:** service host for the current PowerShell bridge, health/events, dashboard, logs, safe service operations, data migration.
3. **Operational desktop:** layers, templates, schedules, monitoring, users, role checks, backups, and diagnostics through the local protocol.
4. **Updater:** GitHub release adapter, signed manifest validation, local package support, updater process, rollback, update UI.
5. **Hardening:** staging mode, full Windows CI, migration tests, installer upgrade tests, documentation, and signed stable release.

## Non-negotiable constraints

- Target Windows 10/11 and .NET 8 LTS.
- The desktop window must never be required for Telegram or monitoring to remain active.
- No service, updater, or installer action may overwrite or stop a detected legacy bridge without explicit confirmation.
- No local RPC endpoint may listen on a network interface.
- Every update path requires trusted signing plus SHA-256 validation.
- Testing mode blocks Cinegy on-air actions by default.
- Existing Telegram commands, persisted timers, schedules, reminders, source failover, and role behavior remain compatible.
