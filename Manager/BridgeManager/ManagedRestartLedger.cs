using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace BridgeManager;

internal sealed record RestartWireRequest(string Action, string Pairing, string? Id = null, long Actor = 0,
    string? Session = null, string? Revision = null, string? Receipt = null);
internal sealed record RestartWireReply(bool Ok, string Error = "", string State = "", string? Id = null, string? Receipt = null);
internal sealed record RestartJournalRecord(string Id, long Actor, string Session, string Revision, int Pid, long StartedAt,
    string State, DateTimeOffset ExpiresAt, string? ReceiptHash = null, int? ReplacementPid = null, long? ReplacementStartedAt = null);

internal sealed class ManagedRestartLedger(Func<RestartJournalRecord, bool> publish, RestartJournalRecord? previous = null)
{
    private const string Reserved = "reserved";
    private const string Reviewed = "reviewed";
    private const string Received = "received";
    private const string Granted = "granted";
    private const string Clean = "clean";
    private const string Launching = "launching";
    private const string Running = "running";
    private const string Failed = "failed";
    private const string Stalled = "stalled";
    private const string RelayActive = "relay-active";

    private bool _stallNeedsPersistence;
    private DateTimeOffset _nextStallWrite;

    public RestartJournalRecord? Current { get; private set; } = previous;
    public bool HasCommittedExit => Current?.State is Granted or Clean or Launching;
    public bool HasGrantedExit => Current?.State == Granted;
    public bool IsStalled => Current?.State == Stalled;
    public bool BlocksAutomation => HasCommittedExit || IsStalled;
    public static bool NeedsManualRecovery(RestartJournalRecord? record) => record?.State is Granted or Clean or Launching or Stalled;

    public RestartWireReply Request(RestartWireRequest supplied, BridgeChildIdentity tracked, DateTimeOffset now)
    {
        ExpireHandshake(now);
        if (supplied.Action == "probe") return new(true, State: IsStalled ? Stalled : HasCommittedExit ? "busy" : "available");
        if (supplied.Action == "reserve")
        {
            if (supplied.Actor <= 0 || !IsHex(supplied.Session, 64) || !IsHex(supplied.Revision, 64))
                return Error("restart_invalid");
            if (BlocksAutomation || (Current is { } active && active.ExpiresAt > now && active.State is Reserved or Reviewed or Received))
                return Error("restart_busy");
            return Save(new RestartJournalRecord(NewId(), supplied.Actor, supplied.Session!, supplied.Revision!,
                tracked.ProcessId, tracked.StartedAtUtcTicks, Reserved, now.AddSeconds(90)));
        }

        if (Current is not { } record || supplied.Id != record.Id) return Error("restart_stale");
        if (supplied.Action == "status")
            return supplied.Actor == record.Actor && SameHash(supplied.Session, record.Session)
                ? new(true, State: record.State, Id: record.Id) : Error("restart_forbidden");
        if (supplied.Action == "ready")
        {
            if (record.State != Launching || record.ReplacementPid != tracked.ProcessId ||
                record.ReplacementStartedAt != tracked.StartedAtUtcTicks)
                return Error("restart_stale");
            return Save(record with { State = Running });
        }

        if (record.Pid != tracked.ProcessId || record.StartedAt != tracked.StartedAtUtcTicks)
            return Error("restart_stale");
        if (supplied.Action == "cleanup")
            return record.State == Granted ? Save(record with { State = Clean }) : Error("restart_stale");
        if (supplied.Actor != record.Actor || !SameHash(supplied.Session, record.Session) ||
            (supplied.Action is not ("cancel" or RelayActive) && (!SameHash(supplied.Revision, record.Revision) || now >= record.ExpiresAt)))
            return Error("restart_stale");

        switch (supplied.Action, record.State)
        {
            case ("confirm", Reserved):
                var receipt = NewId();
                var reply = Save(record with { State = Reviewed, ReceiptHash = Hash(receipt) });
                return reply.Ok ? reply with { Receipt = receipt } : reply;
            case ("ack", Reviewed) when IsHex(supplied.Receipt, 32) && SameHash(Hash(supplied.Receipt!), record.ReceiptHash):
                return Save(record with { State = Received });
            case ("ack", Received) when IsHex(supplied.Receipt, 32) && SameHash(Hash(supplied.Receipt!), record.ReceiptHash):
                return new(true, State: Received, Id: record.Id);
            case ("grant", Received):
                return Save(record with { State = Granted, ReceiptHash = null, ExpiresAt = now.AddMinutes(2) });
            case ("grant", Granted):
                return new(true, State: Granted, Id: record.Id);
            case ("cancel", Reserved or Reviewed or Received or Granted):
                return Save(record with { State = Failed, ReceiptHash = null });
            case (RelayActive, Received or Granted):
                return Save(record with { State = RelayActive, ReceiptHash = null });
            default:
                return Error("restart_stale");
        }
    }

    public bool ExpireHandshake(DateTimeOffset now)
    {
        if (HasCommittedExit && Current is { } active && now >= active.ExpiresAt)
            return StallHandshake(now);
        PersistStall(now);
        return false;
    }

    public bool StallHandshake(DateTimeOffset now)
    {
        if (!HasCommittedExit) return false;
        // The prior committed record also blocks unattended recovery after a Manager
        // restart if this in-memory latch cannot immediately reach the journal.
        Current = Current! with { State = Stalled, ReceiptHash = null };
        _stallNeedsPersistence = true;
        _nextStallWrite = now;
        PersistStall(now);
        return true;
    }

    private void PersistStall(DateTimeOffset now)
    {
        if (_stallNeedsPersistence && now >= _nextStallWrite)
        {
            _stallNeedsPersistence = !publish(Current!);
            _nextStallWrite = now.AddSeconds(1);
        }
    }

    public bool TryClaimReplacement(BridgeChildIdentity child, DateTimeOffset now)
    {
        ExpireHandshake(now);
        if (Current is not { State: Clean } record || record.Pid != child.ProcessId || record.StartedAt != child.StartedAtUtcTicks)
            return false;
        return Save(record with { State = Launching, ExpiresAt = now.AddMinutes(2) }).Ok;
    }

    public bool TryRegisterReplacement(BridgeChildIdentity child, DateTimeOffset now)
    {
        ExpireHandshake(now);
        if (Current is not { State: Launching, ReplacementPid: null } record ||
            child.StartedAtUtcTicks <= record.StartedAt)
            return false;
        return Save(record with { ReplacementPid = child.ProcessId, ReplacementStartedAt = child.StartedAtUtcTicks }).Ok;
    }

    public bool Fail() => !IsStalled && CompleteManualRecovery();

    public bool CompleteManualRecovery()
    {
        if (Current is not { } record) return true;
        return Save(record with { State = Failed, ReceiptHash = null }).Ok;
    }

    private RestartWireReply Save(RestartJournalRecord next)
    {
        if (!publish(next)) return Error("restart_unavailable");
        Current = next;
        _stallNeedsPersistence = false;
        return new(true, State: next.State, Id: next.Id);
    }

    public static bool IsHex(string? value, int length) =>
        value is not null && value.Length == length && value.All(Uri.IsHexDigit);

    public static bool SameHash(string? first, string? second) =>
        first is not null && second is not null && first.Length == second.Length &&
        CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(first), Encoding.ASCII.GetBytes(second));

    private static string NewId() => Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture);
    private static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.ASCII.GetBytes(text)));
    private static RestartWireReply Error(string error) => new(false, error);
}

internal static class RestartJournalStorage
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static RestartJournalRecord? Read(string directory)
    {
        var file = new FileInfo(Path.Combine(directory, "manager-restart.json"));
        if (!file.Exists) return null;
        if ((file.Attributes & FileAttributes.ReparsePoint) != 0 || file.Length > 4096)
            throw new IOException("Invalid managed restart journal.");
        using var stream = file.Open(FileMode.Open, FileAccess.Read, FileShare.Read);
        return JsonSerializer.Deserialize<RestartJournalRecord>(stream, Json) ??
            throw new IOException("Invalid managed restart journal.");
    }

    public static bool Publish(string directory, RestartJournalRecord record)
    {
        string? temporary = null;
        try
        {
            var dir = Directory.CreateDirectory(directory);
            if ((dir.Attributes & FileAttributes.ReparsePoint) != 0) return false;
            var destination = Path.Combine(dir.FullName, "manager-restart.json");
            if (File.Exists(destination) && (File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0)
                return false;
            temporary = Path.Combine(dir.FullName, $"manager-restart-{Guid.NewGuid():N}.tmp");
            using (new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            SettingsForm.ProtectConfigAcl(temporary);
            using (var file = new FileStream(temporary, FileMode.Open, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(file, record, Json);
                file.Flush(flushToDisk: true);
            }
            File.Move(temporary, destination, overwrite: true);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (System.Security.SecurityException) { return false; }
        finally
        {
            if (temporary is not null)
            {
                try { File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
