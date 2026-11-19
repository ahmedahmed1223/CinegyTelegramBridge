using System.Security.Cryptography;
using CinegyBridge.Web.Storage;

namespace CinegyBridge.Web.Auth;

public sealed record WebSession
{
    public required string Id { get; init; }
    public required long UserId { get; init; }
    /// <summary>"telegram" or "password".</summary>
    public required string Method { get; init; }
    public string Username { get; init; } = "";
    public required string Address { get; init; }
    public required string Agent { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset LastSeenAt { get; init; }
}

public sealed class SessionsDocument
{
    public List<WebSession> Sessions { get; set; } = [];
}

/// <summary>
/// Server-side record of every signed-in browser. The cookie carries only the
/// session id; deleting the record here - from the control program, from the
/// sessions page, or because the person lost their access - ends it on the
/// next request, which a self-contained cookie could not do.
/// </summary>
public sealed class SessionStore(WebOptions options, TimeProvider clock)
{
    public static readonly TimeSpan IdleLimit = TimeSpan.FromHours(12);
    public static readonly TimeSpan AbsoluteLimit = TimeSpan.FromDays(7);
    // Last-seen is written at most this often; it is shown, not enforced finely.
    private static readonly TimeSpan TouchInterval = TimeSpan.FromMinutes(1);

    private readonly JsonFileStore<SessionsDocument> _store =
        new(Path.Combine(options.StateDirectory, "sessions.json"), () => new SessionsDocument());

    public Task<WebSession> CreateAsync(long userId, string method, string username, string address, string agent)
    {
        var now = clock.GetUtcNow();
        var session = new WebSession
        {
            Id = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant(),
            UserId = userId,
            Method = method,
            Username = username,
            Address = Trim(address, 64),
            Agent = Trim(agent, 160),
            CreatedAt = now,
            LastSeenAt = now,
        };
        return _store.UpdateAsync(document =>
        {
            document.Sessions.RemoveAll(s => IsExpired(s, now));
            document.Sessions.Add(session);
            return (true, session);
        });
    }

    /// <summary>The live session for this id, or null when it is gone or past
    /// either limit.</summary>
    public Task<WebSession?> TouchAsync(string id)
    {
        var now = clock.GetUtcNow();
        return _store.UpdateAsync(document =>
        {
            var index = document.Sessions.FindIndex(s => s.Id == id);
            if (index < 0) return (false, (WebSession?)null);
            var session = document.Sessions[index];
            if (IsExpired(session, now))
            {
                document.Sessions.RemoveAt(index);
                return (true, null);
            }
            if (now - session.LastSeenAt < TouchInterval) return (false, session);
            document.Sessions[index] = session with { LastSeenAt = now };
            return (true, document.Sessions[index]);
        });
    }

    public Task<IReadOnlyList<WebSession>> ListAsync()
    {
        var now = clock.GetUtcNow();
        return _store.ReadAsync<IReadOnlyList<WebSession>>(document =>
            [.. document.Sessions.Where(s => !IsExpired(s, now)).OrderByDescending(s => s.LastSeenAt)]);
    }

    public Task<bool> RemoveAsync(string id) =>
        _store.UpdateAsync(document =>
        {
            var removed = document.Sessions.RemoveAll(s => s.Id == id) > 0;
            return (removed, removed);
        });

    public Task<int> RemoveForUserAsync(long userId) =>
        _store.UpdateAsync(document =>
        {
            var count = document.Sessions.RemoveAll(s => s.UserId == userId);
            return (count > 0, count);
        });

    /// <summary>Password sessions of one account, after its password changed
    /// or it was removed. Telegram sign-ins of the same person stay.</summary>
    public Task<int> RemoveForUsernameAsync(string username) =>
        _store.UpdateAsync(document =>
        {
            var count = document.Sessions.RemoveAll(s => s.Method == "password" && s.Username == username);
            return (count > 0, count);
        });

    private static bool IsExpired(WebSession session, DateTimeOffset now) =>
        now - session.LastSeenAt > IdleLimit || now - session.CreatedAt > AbsoluteLimit;

    private static string Trim(string value, int length) =>
        value.Length <= length ? value : value[..length];
}
