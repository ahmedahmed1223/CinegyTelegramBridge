# Desktop Preview 1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the first installable Windows preview: a .NET 10 WPF desktop shell connected to a secure local Windows Service, with an isolated ProgramData store, readiness reporting, service lifecycle controls, and a WiX installer.

**Architecture:** The desktop and service share versioned contracts but no implementation assemblies. The service owns a local named pipe protected by Windows identity, ACLs, and a DPAPI-protected installation secret. Preview 1 deliberately does not host `TelegramBridge.ps1`; that is Preview 2, after service installation and local control are proven.

**Tech Stack:** .NET 10 LTS (`net10.0-windows`), C# 14, WPF, .NET Worker Service, Windows named pipes, DPAPI, xUnit, WiX Toolset 7.0.0 MSI/Burn, PowerShell/Pester compatibility tests, GitHub Actions `windows-latest`.

**Spec:** `docs/superpowers/specs/2026-08-27-desktop-standalone-application-design.md`

## Global Constraints

- Target supported Windows 10/11 editions and `net10.0-windows`.
- Install .NET 10 SDK before Task 1; the current development machine has SDK 8 and 9 only.
- Use WPF for the desktop and a .NET Worker Service for the Windows Service.
- The desktop must not contact Telegram or Cinegy directly.
- No RPC listener may bind to TCP or any network interface.
- Store mutable state only under `%ProgramData%\CinegyTelegramBridge`.
- Protect the per-install RPC secret with DPAPI and restrict its file ACL to `SYSTEM`, the service identity, and configured local owners.
- Keep Windows roles and Telegram roles separate.
- Do not stop, replace, or migrate a detected legacy bridge during Preview 1.
- Use WiX Toolset 7.0.0 only after the owner accepts its applicable OSMF/EULA terms; if not accepted, replace only the installer project in a separate approved design revision.
- Keep all existing PowerShell/Pester tests green.

---

## File map

```text
global.json                                      pinned .NET SDK policy
Directory.Build.props                           common warnings, nullable, deterministic build
CinegyBridge.sln                                 solution entry point
src/CinegyBridge.Contracts/                     RPC DTOs and protocol constants only
src/CinegyBridge.Platform/                      paths, DPAPI secret store, ACL helpers
src/CinegyBridge.Service/                       Windows Service and named-pipe host
src/CinegyBridge.Desktop/                       WPF shell, readiness/service view models
tools/CinegyBridge.HealthProbe/                 CI-only authenticated health probe
installer/CinegyBridge.Installer/               WiX MSI and Burn bundle
tests/CinegyBridge.Contracts.Tests/             contract compatibility tests
tests/CinegyBridge.Platform.Tests/              data and security tests
tests/CinegyBridge.Service.Tests/               RPC/service behavior tests
tests/CinegyBridge.Desktop.Tests/               view-model behavior tests
scripts/Test-DesktopServiceLifecycle.ps1        isolated installed-service smoke test
```

### Task 1: Solution skeleton and versioned contracts

**Files:**
- Create: `global.json`
- Create: `Directory.Build.props`
- Create: `CinegyBridge.sln`
- Create: `src/CinegyBridge.Contracts/CinegyBridge.Contracts.csproj`
- Create: `src/CinegyBridge.Contracts/Protocol/BridgeProtocol.cs`
- Create: `src/CinegyBridge.Contracts/Health/BridgeHealthSnapshot.cs`
- Create: `tests/CinegyBridge.Contracts.Tests/CinegyBridge.Contracts.Tests.csproj`
- Create: `tests/CinegyBridge.Contracts.Tests/ProtocolCompatibilityTests.cs`

**Interfaces:**
- Produces: `BridgeProtocol.CurrentVersion`, `BridgeProtocol.PipeName`, `BridgeHealthSnapshot`.
- Consumed by: service and desktop projects in Tasks 4 and 5.

- [ ] **Step 1: Install and verify the required SDK**

Run:

```powershell
winget install --id Microsoft.DotNet.SDK.10 --exact
dotnet --list-sdks
```

Expected: at least one `10.0.*` SDK is listed. Stop if installation is unavailable; do not retarget the project to SDK 9.

- [ ] **Step 2: Create the solution and projects**

Run:

```powershell
dotnet new globaljson --sdk-version 10.0.100 --roll-forward latestFeature
dotnet new sln --name CinegyBridge
dotnet new classlib --name CinegyBridge.Contracts --output src/CinegyBridge.Contracts --framework net10.0
dotnet new xunit --name CinegyBridge.Contracts.Tests --output tests/CinegyBridge.Contracts.Tests --framework net10.0
dotnet sln CinegyBridge.sln add src/CinegyBridge.Contracts/CinegyBridge.Contracts.csproj tests/CinegyBridge.Contracts.Tests/CinegyBridge.Contracts.Tests.csproj
dotnet add tests/CinegyBridge.Contracts.Tests/CinegyBridge.Contracts.Tests.csproj reference src/CinegyBridge.Contracts/CinegyBridge.Contracts.csproj
```

Expected: solution restore succeeds.

- [ ] **Step 3: Write the failing protocol compatibility test**

```csharp
using System.Text.Json;
using CinegyBridge.Contracts.Health;
using CinegyBridge.Contracts.Protocol;

namespace CinegyBridge.Contracts.Tests;

public sealed class ProtocolCompatibilityTests
{
    [Fact]
    public void Health_snapshot_serializes_with_current_protocol_version()
    {
        var snapshot = BridgeHealthSnapshot.Starting("5.7.7");
        var json = JsonSerializer.Serialize(snapshot);

        Assert.Contains($"\"protocolVersion\":{BridgeProtocol.CurrentVersion}", json);
        Assert.Contains("\"state\":\"starting\"", json);
    }
}
```

- [ ] **Step 4: Run the test and verify RED**

Run: `dotnet test tests/CinegyBridge.Contracts.Tests/CinegyBridge.Contracts.Tests.csproj`

Expected: compilation fails because `BridgeProtocol` and `BridgeHealthSnapshot` do not exist.

- [ ] **Step 5: Implement the minimal contracts**

```csharp
namespace CinegyBridge.Contracts.Protocol;

public static class BridgeProtocol
{
    public const int CurrentVersion = 1;
    public const string PipeName = "CinegyTelegramBridge.Control.v1";
}
```

```csharp
using System.Text.Json.Serialization;
using CinegyBridge.Contracts.Protocol;

namespace CinegyBridge.Contracts.Health;

public sealed record BridgeHealthSnapshot(
    [property: JsonPropertyName("protocolVersion")] int ProtocolVersion,
    [property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("bridgeVersion")] string BridgeVersion,
    [property: JsonPropertyName("observedAtUtc")] DateTimeOffset ObservedAtUtc)
{
    public static BridgeHealthSnapshot Starting(string bridgeVersion) =>
        new(BridgeProtocol.CurrentVersion, "starting", bridgeVersion, DateTimeOffset.UtcNow);
}
```

- [ ] **Step 6: Add deterministic build rules and verify GREEN**

Create `Directory.Build.props` with nullable and warnings enabled, then run:

```powershell
dotnet test CinegyBridge.sln --configuration Release
```

Expected: contract test passes with zero warnings.

- [ ] **Step 7: Commit**

```powershell
git add global.json Directory.Build.props CinegyBridge.sln src/CinegyBridge.Contracts tests/CinegyBridge.Contracts.Tests
git commit -m "feat(desktop): add .NET 10 solution and RPC contracts"
```

### Task 2: ProgramData layout and atomic initialization

**Files:**
- Create: `src/CinegyBridge.Platform/CinegyBridge.Platform.csproj`
- Create: `src/CinegyBridge.Platform/Storage/BridgeDataPaths.cs`
- Create: `src/CinegyBridge.Platform/Storage/BridgeDataInitializer.cs`
- Create: `tests/CinegyBridge.Platform.Tests/CinegyBridge.Platform.Tests.csproj`
- Create: `tests/CinegyBridge.Platform.Tests/BridgeDataInitializerTests.cs`

**Interfaces:**
- Produces: `BridgeDataPaths.ForRoot(string root)`, `BridgeDataPaths.Resolve(string[] args)`, and `BridgeDataInitializer.InitializeAsync(...)`.
- Consumed by: DPAPI store, service startup, and installer migration detection.

- [ ] **Step 1: Add platform and test projects to the solution**

Run the `dotnet new classlib`, `dotnet new xunit`, `dotnet sln add`, and project-reference commands for the paths above.

- [ ] **Step 2: Write the failing directory-layout test**

```csharp
[Fact]
public async Task Initialize_creates_only_the_declared_mutable_directories()
{
    var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    try
    {
        var paths = BridgeDataPaths.ForRoot(root);
        await new BridgeDataInitializer().InitializeAsync(paths, CancellationToken.None);

        Assert.True(Directory.Exists(paths.Logs));
        Assert.True(Directory.Exists(paths.Schedules));
        Assert.True(Directory.Exists(paths.Backups));
        Assert.True(Directory.Exists(paths.Updates));
        Assert.True(Directory.Exists(paths.Runtime));
        Assert.False(File.Exists(paths.Config));
    }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
```

- [ ] **Step 3: Verify RED**

Run: `dotnet test tests/CinegyBridge.Platform.Tests/CinegyBridge.Platform.Tests.csproj`

Expected: compilation fails because storage types are missing.

- [ ] **Step 4: Implement the immutable path record, resolver, and initializer**

Use `%ProgramData%\CinegyTelegramBridge` as the production default. Accept `--data-root <absolute-path>` only when the normalized path remains beneath `%ProgramData%`; reject relative paths, traversal, duplicates, and paths outside ProgramData. This narrow override exists for isolated MSI/CI lifecycle tests. Unit tests inject a temporary root directly through `ForRoot`. `InitializeAsync` creates the five declared directories and never creates or overwrites `config.json` or `templates.json`.

- [ ] **Step 5: Verify GREEN and commit**

Run: `dotnet test CinegyBridge.sln --configuration Release`

Expected: all .NET tests pass.

```powershell
git add src/CinegyBridge.Platform tests/CinegyBridge.Platform.Tests CinegyBridge.sln
git commit -m "feat(desktop): initialize isolated ProgramData layout"
```

### Task 3: DPAPI secret storage and Windows ACLs

**Files:**
- Modify: `src/CinegyBridge.Platform/CinegyBridge.Platform.csproj`
- Create: `src/CinegyBridge.Platform/Security/IInstallationSecretStore.cs`
- Create: `src/CinegyBridge.Platform/Security/DpapiInstallationSecretStore.cs`
- Create: `src/CinegyBridge.Platform/Security/SecretFileAcl.cs`
- Create: `src/CinegyBridge.Platform/Security/LocalAccessPolicy.cs`
- Create: `src/CinegyBridge.Platform/Security/LocalAccessPolicyStore.cs`
- Create: `tests/CinegyBridge.Platform.Tests/DpapiInstallationSecretStoreTests.cs`
- Create: `tests/CinegyBridge.Platform.Tests/LocalAccessPolicyStoreTests.cs`

**Interfaces:**
- Produces: `LocalAccessPolicy.OwnerSid` and `Task<byte[]> GetOrCreateAsync(SecurityIdentifier ownerSid, CancellationToken cancellationToken)`.
- Consumed by: named-pipe host and client in Task 4.

- [ ] **Step 1: Add Windows cryptography package**

Run:

```powershell
dotnet add src/CinegyBridge.Platform/CinegyBridge.Platform.csproj package System.Security.Cryptography.ProtectedData --version 10.0.0
```

- [ ] **Step 2: Write failing access-policy, round-trip, and ACL tests**

The access-policy test atomically writes and reloads one valid Windows SID, rejects malformed/multiple SIDs, and refuses to overwrite an existing owner unless an explicit administrative replacement method is called. The secret test creates a temporary secret file, calls `GetOrCreateAsync` twice, asserts both results are the same 32-byte value, asserts the file does not contain the plaintext bytes, and asserts inherited ACLs are disabled with explicit rules for `SYSTEM` and the policy owner SID.

- [ ] **Step 3: Verify RED**

Run: `dotnet test tests/CinegyBridge.Platform.Tests/CinegyBridge.Platform.Tests.csproj --filter DpapiInstallationSecretStoreTests`

Expected: compilation fails because the store is missing.

- [ ] **Step 4: Implement the store**

Store the initial local owner SID atomically in `runtime\local-access.json` and protect that file from inherited ACLs. Generate 32 random bytes with `RandomNumberGenerator.GetBytes(32)`, protect using `ProtectedData.Protect(..., DataProtectionScope.LocalMachine)`, write through `secret.bin.tmp`, atomically move it to `runtime\secret.bin`, and apply explicit ACLs for `SYSTEM` and the configured owner after the move. On read, call `ProtectedData.Unprotect` and reject lengths other than 32.

- [ ] **Step 5: Verify GREEN and commit**

Run: `dotnet test CinegyBridge.sln --configuration Release`

```powershell
git add src/CinegyBridge.Platform tests/CinegyBridge.Platform.Tests
git commit -m "feat(desktop): protect local RPC secret with DPAPI and ACLs"
```

### Task 4: Authenticated named-pipe service endpoint

**Files:**
- Create: `src/CinegyBridge.Service/CinegyBridge.Service.csproj`
- Create: `src/CinegyBridge.Service/Program.cs`
- Create: `src/CinegyBridge.Service/Control/BridgeControlWorker.cs`
- Create: `src/CinegyBridge.Service/Control/NamedPipeControlServer.cs`
- Create: `src/CinegyBridge.Contracts/Control/ControlRequest.cs`
- Create: `src/CinegyBridge.Contracts/Control/ControlResponse.cs`
- Create: `tests/CinegyBridge.Service.Tests/CinegyBridge.Service.Tests.csproj`
- Create: `tests/CinegyBridge.Service.Tests/NamedPipeControlServerTests.cs`
- Create: `tools/CinegyBridge.HealthProbe/CinegyBridge.HealthProbe.csproj`
- Create: `tools/CinegyBridge.HealthProbe/Program.cs`

**Interfaces:**
- Consumes: `BridgeProtocol`, `BridgeHealthSnapshot`, `IInstallationSecretStore`.
- Produces: newline-delimited JSON commands `authenticate` and `get-health` over `BridgeProtocol.PipeName`.

- [ ] **Step 1: Scaffold Worker Service and references**

Run:

```powershell
dotnet new worker --name CinegyBridge.Service --output src/CinegyBridge.Service --framework net10.0
dotnet add src/CinegyBridge.Service/CinegyBridge.Service.csproj package Microsoft.Extensions.Hosting.WindowsServices --version 10.0.0
dotnet add src/CinegyBridge.Service/CinegyBridge.Service.csproj package System.IO.Pipes.AccessControl --version 5.0.0
dotnet add src/CinegyBridge.Service/CinegyBridge.Service.csproj reference src/CinegyBridge.Contracts/CinegyBridge.Contracts.csproj src/CinegyBridge.Platform/CinegyBridge.Platform.csproj
```

Set the service project's target framework to `net10.0-windows`; create the health-probe console project targeting the same framework and reference Contracts and Platform. The probe accepts only `--data-root`, connects to the fixed control pipe, authenticates from the protected installation secret, requests health, prints typed JSON, and returns a nonzero exit code for authentication, protocol, or readiness failure.

- [ ] **Step 2: Write failing authentication tests**

Test three real named-pipe exchanges using a unique injected pipe name: unauthenticated `get-health` returns `unauthorized`; wrong secret returns `unauthorized`; correct Base64 secret followed by `get-health` returns protocol version 1 and state `service-ready`.

- [ ] **Step 3: Verify RED**

Run: `dotnet test tests/CinegyBridge.Service.Tests/CinegyBridge.Service.Tests.csproj`

Expected: compilation fails because the server is missing.

- [ ] **Step 4: Implement the bounded protocol**

Use `NamedPipeServerStreamAcl.Create` with local ACLs, `PipeOptions.Asynchronous`, one request per line, maximum line length 64 KiB, and fixed-time secret comparison with `CryptographicOperations.FixedTimeEquals`. Close the connection after any authentication failure or malformed JSON. Do not implement generic method reflection or shell execution.

- [ ] **Step 5: Register as Windows Service and verify GREEN**

`Program.cs` calls `AddWindowsService(options => options.ServiceName = "CinegyTelegramBridge")`, resolves the guarded data root, loads the configured local owner policy, initializes ProgramData, obtains the secret, and runs `BridgeControlWorker`.

Run: `dotnet test CinegyBridge.sln --configuration Release`

- [ ] **Step 6: Commit**

```powershell
git add src/CinegyBridge.Contracts src/CinegyBridge.Service tools/CinegyBridge.HealthProbe tests/CinegyBridge.Service.Tests CinegyBridge.sln
git commit -m "feat(desktop): expose authenticated local service health pipe"
```

### Task 5: WPF shell and readiness dashboard

**Files:**
- Create: `src/CinegyBridge.Desktop/CinegyBridge.Desktop.csproj`
- Create: `src/CinegyBridge.Desktop/App.xaml`
- Create: `src/CinegyBridge.Desktop/MainWindow.xaml`
- Create: `src/CinegyBridge.Desktop/Control/IBridgeControlClient.cs`
- Create: `src/CinegyBridge.Desktop/Control/NamedPipeBridgeControlClient.cs`
- Create: `src/CinegyBridge.Desktop/Dashboard/DashboardViewModel.cs`
- Create: `tests/CinegyBridge.Desktop.Tests/CinegyBridge.Desktop.Tests.csproj`
- Create: `tests/CinegyBridge.Desktop.Tests/DashboardViewModelTests.cs`

**Interfaces:**
- Consumes: authenticated `get-health` protocol.
- Produces: `DashboardViewModel.RefreshAsync()` with `ServiceState`, `BridgeVersion`, `LastCheckedUtc`, and `ErrorMessage`.

- [ ] **Step 1: Scaffold WPF and test projects**

Run:

```powershell
dotnet new wpf --name CinegyBridge.Desktop --output src/CinegyBridge.Desktop --framework net10.0-windows
dotnet new xunit --name CinegyBridge.Desktop.Tests --output tests/CinegyBridge.Desktop.Tests --framework net10.0-windows
```

Add solution entries and references to Contracts and Platform.

- [ ] **Step 2: Write the failing dashboard tests**

Use an in-memory fake implementing `IBridgeControlClient`. Assert `RefreshAsync` maps a healthy snapshot to `service-ready`; a `TimeoutException` maps to `offline` with an actionable Arabic message; a protocol mismatch maps to `incompatible` and does not claim the service is stopped.

- [ ] **Step 3: Verify RED**

Run: `dotnet test tests/CinegyBridge.Desktop.Tests/CinegyBridge.Desktop.Tests.csproj`

Expected: compilation fails because the view model and client interface are missing.

- [ ] **Step 4: Implement client and view model**

The client connects with a 3-second timeout, authenticates using the DPAPI store, sends `get-health`, validates `BridgeProtocol.CurrentVersion`, and returns the typed snapshot. The view model never invokes service-control commands in Preview 1.

- [ ] **Step 5: Build the minimal Arabic WPF shell**

Create a right-to-left main window with a sidebar containing only `الرئيسية`, `الجاهزية`, and `الخدمة`. Dashboard cards show service state, protocol version, data path, and last check. Disabled navigation entries may name future pages but must say `يتوفر في Preview 3` and perform no action.

- [ ] **Step 6: Verify GREEN and commit**

Run:

```powershell
dotnet test CinegyBridge.sln --configuration Release
dotnet build src/CinegyBridge.Desktop/CinegyBridge.Desktop.csproj --configuration Release
```

```powershell
git add src/CinegyBridge.Desktop tests/CinegyBridge.Desktop.Tests CinegyBridge.sln
git commit -m "feat(desktop): add WPF service readiness dashboard"
```

### Task 6: Safe service lifecycle commands

**Files:**
- Create: `src/CinegyBridge.Desktop/Service/IBridgeServiceManager.cs`
- Create: `src/CinegyBridge.Desktop/Service/WindowsBridgeServiceManager.cs`
- Create: `src/CinegyBridge.Desktop/Service/ServicePageViewModel.cs`
- Modify: `src/CinegyBridge.Desktop/MainWindow.xaml`
- Create: `tests/CinegyBridge.Desktop.Tests/ServicePageViewModelTests.cs`

**Interfaces:**
- Produces: `GetStatusAsync`, `StartAsync`, `StopAsync`, `RestartAsync` returning `ServiceOperationResult`.
- Consumed by: Service page only; installation remains the MSI's responsibility.

- [ ] **Step 1: Write failing confirmation and status tests**

Assert the view model never calls `StopAsync` or `RestartAsync` until `ConfirmAsync` returns true, refreshes status after success, and displays Win32 access-denied as an elevation instruction rather than a generic failure.

- [ ] **Step 2: Verify RED**

Run: `dotnet test tests/CinegyBridge.Desktop.Tests/CinegyBridge.Desktop.Tests.csproj --filter ServicePageViewModelTests`

- [ ] **Step 3: Implement service control**

Add `System.ServiceProcess.ServiceController` version `10.0.0` to the desktop project. Use `ServiceController` for the fixed service name `CinegyTelegramBridge`, bounded 20-second waits, and no process killing. Restart is stop-to-stopped then start-to-running. Return structured errors with native error codes.

- [ ] **Step 4: Verify GREEN and commit**

Run: `dotnet test CinegyBridge.sln --configuration Release`

```powershell
git add src/CinegyBridge.Desktop tests/CinegyBridge.Desktop.Tests
git commit -m "feat(desktop): add confirmed Windows service controls"
```

### Task 7: WiX installer and Burn bundle

**Files:**
- Create: `installer/CinegyBridge.Installer/CinegyBridge.Installer.wixproj`
- Create: `installer/CinegyBridge.Installer/Package.wxs`
- Create: `installer/CinegyBridge.Installer/Bundle.wxs`
- Create: `installer/CinegyBridge.Installer/License.rtf`
- Create: `tests/CinegyBridge.Installer.Tests/InstallerManifest.Tests.ps1`
- Modify: `CinegyBridge.sln`

**Interfaces:**
- Consumes: published Desktop and Service artifacts.
- Produces: `CinegyTelegramBridge-Desktop-Preview1-x64.exe` bootstrapper and MSI payload.

- [ ] **Step 1: Resolve the licensing gate**

Record explicit owner acceptance of the WiX Toolset 7.0.0 OSMF/EULA in the project release checklist before installing the SDK package. If acceptance is not recorded, stop this task and request an installer design revision; do not silently select another installer.

- [ ] **Step 2: Write the failing installer manifest test**

The Pester test parses `Package.wxs` and asserts: per-machine scope, x64 platform, service name `CinegyTelegramBridge`, automatic start, failure restart actions, installation below `ProgramFilesFolder`, capture of the invoking interactive user's SID into the guarded `INITIAL_OWNER_SID` property, and no harvested `config.json`, `templates.json`, `logs`, or ProgramData runtime files.

- [ ] **Step 3: Verify RED**

Run: `Invoke-Pester tests/CinegyBridge.Installer.Tests/InstallerManifest.Tests.ps1`

Expected: failure because WiX sources do not exist.

- [ ] **Step 4: Implement MSI and bundle**

Pin `WixToolset.Sdk` to `7.0.0`. MSI installs signed binaries, initializes `local-access.json` with the invoking interactive user's SID, applies the local ACL, and registers the service. Expose a hidden `BRIDGE_DATA_ROOT` MSI property solely for CI; its custom action must apply the same beneath-ProgramData validation as `BridgeDataPaths.Resolve`. Burn detects/installs the .NET 10 Desktop Runtime prerequisite and chains the MSI. Preserve `%ProgramData%\CinegyTelegramBridge` on uninstall unless the owner selects a separate explicit data-removal action.

- [ ] **Step 5: Build and inspect the installer**

Run:

```powershell
dotnet publish src/CinegyBridge.Service/CinegyBridge.Service.csproj -c Release -r win-x64 --self-contained false
dotnet publish src/CinegyBridge.Desktop/CinegyBridge.Desktop.csproj -c Release -r win-x64 --self-contained false
dotnet build installer/CinegyBridge.Installer/CinegyBridge.Installer.wixproj -c Release
Invoke-Pester tests/CinegyBridge.Installer.Tests/InstallerManifest.Tests.ps1
```

Expected: bundle exists and installer tests pass.

- [ ] **Step 6: Commit**

```powershell
git add installer tests/CinegyBridge.Installer.Tests CinegyBridge.sln
git commit -m "feat(desktop): package Preview 1 Windows service and desktop"
```

### Task 8: Windows CI and isolated service lifecycle

**Files:**
- Create: `scripts/Test-DesktopServiceLifecycle.ps1`
- Modify: `.github/workflows/windows-ci.yml`
- Modify: `Run-Checks.ps1`
- Modify: `Build-Release.ps1`
- Create: `Tests/DesktopFoundationWiring.Tests.ps1`

**Interfaces:**
- Consumes: Preview 1 bundle/MSI and service health pipe.
- Produces: CI artifact containing .NET test results, installer, lifecycle log, and hashes.

- [ ] **Step 1: Write failing repository-wiring tests**

Assert the workflow installs .NET 10, runs `dotnet test CinegyBridge.sln`, builds the WiX bundle, invokes `Test-DesktopServiceLifecycle.ps1`, and uploads the installer. Assert the PowerShell release allow-list includes desktop documentation but never includes generated secrets or ProgramData state.

- [ ] **Step 2: Verify RED**

Run: `Invoke-Pester Tests/DesktopFoundationWiring.Tests.ps1`

Expected: failure because workflow wiring is absent.

- [ ] **Step 3: Implement the lifecycle script**

The script creates a unique `%ProgramData%\CinegyTelegramBridge-CI-<guid>` root, installs the MSI with `BRIDGE_DATA_ROOT` set to that resolved path and `INITIAL_OWNER_SID` set to the CI account SID, starts the service, runs `CinegyBridge.HealthProbe.exe --data-root <resolved-path>`, asserts protocol version 1 and `service-ready`, stops and uninstalls the service, then removes only that exact resolved unique CI root in `finally`. It must never enumerate and delete broad ProgramData paths.

- [ ] **Step 4: Update CI**

Add `actions/setup-dotnet` for `10.0.x`, retain the existing Pester checks, run all .NET tests, build the installer, run the lifecycle script on `windows-latest`, and upload NUnit/Pester results plus the signed-or-explicitly-unsigned preview artifact.

- [ ] **Step 5: Verify all gates**

Run:

```powershell
.\Run-Checks.ps1
dotnet test CinegyBridge.sln --configuration Release
Invoke-Pester Tests/DesktopFoundationWiring.Tests.ps1
```

Expected: all PowerShell and .NET tests pass locally. The real install/start/stop lifecycle is verified by the Windows CI job, not against the operator's running bridge machine.

- [ ] **Step 6: Commit**

```powershell
git add .github/workflows/windows-ci.yml Run-Checks.ps1 Build-Release.ps1 scripts/Test-DesktopServiceLifecycle.ps1 Tests/DesktopFoundationWiring.Tests.ps1
git commit -m "ci(desktop): verify Preview 1 service lifecycle"
```

### Task 9: Preview 1 documentation and acceptance gate

**Files:**
- Create: `docs/desktop/PREVIEW-1.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `RELEASE.md`

**Interfaces:**
- Consumes: completed installer and CI outputs.
- Produces: operator installation, repair, uninstall, data-retention, and limitation documentation.

- [ ] **Step 1: Write the acceptance checklist first**

Document exact pass conditions: install on clean Windows, service starts automatically, desktop reads health, unauthorized local user is rejected, stop/restart require confirmation/elevation, uninstall leaves ProgramData intact, existing PowerShell bot is not detected or stopped automatically, and current Telegram/Cinegy runtime is not hosted until Preview 2.

- [ ] **Step 2: Add user documentation**

Describe prerequisites, installer steps, service status meanings, ProgramData paths, diagnostic locations, repair/uninstall behavior, and how to return to the existing PowerShell deployment. State Preview 1 limitations visibly.

- [ ] **Step 3: Run final verification**

Run:

```powershell
.\Run-Checks.ps1
dotnet test CinegyBridge.sln --configuration Release
git diff --check
```

Expected: all checks pass and the worktree contains only intended Preview 1 changes.

- [ ] **Step 4: Commit**

```powershell
git add docs/desktop/PREVIEW-1.md README.md CHANGELOG.md RELEASE.md
git commit -m "docs(desktop): publish Preview 1 installation guide"
```

## Plan boundary

Preview 1 ends when the service, secure pipe, WPF readiness dashboard, service controls, installer, and isolated CI lifecycle are green. Hosting `TelegramBridge.ps1`, migrating existing runtime state, exposing on-air operations, and implementing updates belong to their own Preview 2–RC plans derived from the same specification.
