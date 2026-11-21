using System.Diagnostics;
using System.Text;

namespace BridgeManager;

internal sealed record BridgeChildIdentity(object Handle, int ProcessId, long StartedAtUtcTicks)
{
    public bool Matches(BridgeChildIdentity? other) =>
        other is not null && ReferenceEquals(Handle, other.Handle) &&
        ProcessId == other.ProcessId && StartedAtUtcTicks == other.StartedAtUtcTicks;
}

internal sealed record BridgeLaunchPlan(string PowerShell, string ScriptPath, string Root, string ConfigPath, bool Strict = false)
{
    public ProcessStartInfo CreateStartInfo()
    {
        var info = new ProcessStartInfo
        {
            FileName = PowerShell,
            WorkingDirectory = Root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        info.ArgumentList.Add("-NoProfile");
        if (Strict) info.ArgumentList.Add("-NonInteractive");
        info.ArgumentList.Add("-File");
        info.ArgumentList.Add(ScriptPath);
        info.ArgumentList.Add("-ConfigPath");
        info.ArgumentList.Add(ConfigPath);
        info.ArgumentList.Add(Strict ? "-RequireSingleInstance" : "-StopExisting");
        return info;
    }
}

// The Manager UI thread owns this reservation and consumes it from the
// exact watched child's Exited callback.
internal sealed class ManagedBridgeReplacement
{
    private BridgeChildIdentity? _outgoing;
    private BridgeLaunchPlan? _launch;

    public bool IsPending => _outgoing is not null;

    public bool TryReserve(BridgeChildIdentity? owned, BridgeChildIdentity? current, BridgeLaunchPlan? launch)
    {
        if (IsPending || owned is null || !owned.Matches(current) || launch is null) return false;
        _outgoing = owned;
        _launch = launch with { Strict = true };
        return true;
    }

    public BridgeLaunchPlan? Take(BridgeChildIdentity? exited)
    {
        if (_outgoing is null || !_outgoing.Matches(exited)) return null;
        var launch = _launch;
        Cancel();
        return launch;
    }

    public void Cancel()
    {
        _outgoing = null;
        _launch = null;
    }
}
