using System.Collections.Concurrent;
using System.Text.Json;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Auth;

/// <summary>Who the bridge says a user is. Role is "owner", "admin" or "operator".</summary>
public sealed record BridgeUser(long Id, string Name, string Role, bool WebOnly)
{
    public bool IsAdmin => Role is "owner" or "admin";
    public bool IsOwner => Role == "owner";
}

public enum IdentityState { Known, NotAuthorized, Unavailable }

public sealed record IdentityResult(IdentityState State, BridgeUser? User = null);

/// <summary>
/// Asks the bridge who a user is, through the pipe's in-memory roster, and
/// remembers the answer for a few seconds. The bridge decides; this only
/// avoids asking on every request of one page load.
/// </summary>
public sealed class BridgeIdentity(IBridgeChannel bridge, TimeProvider clock)
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(10);
    private readonly ConcurrentDictionary<long, (IdentityResult Result, DateTimeOffset At)> _cache = new();

    public async Task<IdentityResult> GetAsync(long userId, CancellationToken cancellationToken = default)
    {
        var now = clock.GetUtcNow();
        if (_cache.TryGetValue(userId, out var cached) && now - cached.At < CacheFor) return cached.Result;

        var reply = await bridge.SendAsync("identity", new { userId }, cancellationToken);
        IdentityResult result;
        if (!reply.Ok) result = new IdentityResult(IdentityState.Unavailable);
        else if (reply.Data.ValueKind != JsonValueKind.Object) result = new IdentityResult(IdentityState.NotAuthorized);
        else result = new IdentityResult(IdentityState.Known, Read(reply.Data));

        // An outage is not remembered: the next request should try again.
        if (result.State != IdentityState.Unavailable) _cache[userId] = (result, now);
        return result;
    }

    public async Task<IReadOnlyList<BridgeUser>?> RosterAsync(CancellationToken cancellationToken = default)
    {
        var reply = await bridge.SendAsync("roster", null, cancellationToken);
        if (!reply.Ok || reply.Data.ValueKind != JsonValueKind.Array) return null;
        return [.. reply.Data.EnumerateArray().Select(Read).OrderBy(u => u.Name)];
    }

    public void Forget(long userId) => _cache.TryRemove(userId, out _);

    private static BridgeUser Read(JsonElement element) => new(
        element.GetProperty("id").GetInt64(),
        element.GetProperty("name").GetString() ?? "",
        element.GetProperty("role").GetString() ?? "operator",
        element.TryGetProperty("webOnly", out var webOnly) && webOnly.ValueKind == JsonValueKind.True);
}
