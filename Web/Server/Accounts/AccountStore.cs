using System.Text.RegularExpressions;
using CinegyBridge.Web.Storage;

namespace CinegyBridge.Web.Accounts;

/// <summary>A password sign-in. <see cref="UserId"/> is the bridge identity it
/// opens: a Telegram user's own id, or one from the browser-only range.</summary>
public sealed record WebAccount
{
    public required string Username { get; init; }
    public required long UserId { get; init; }
    public required string DisplayName { get; init; }
    public bool WebOnly { get; init; }
    public required PasswordHash Password { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    public long CreatedBy { get; init; }
    public DateTimeOffset? LastLoginAt { get; init; }
    public int FailedAttempts { get; init; }
    public DateTimeOffset? LockedUntil { get; init; }
}

public sealed class AccountsDocument
{
    /// <summary>Must match $script:WebOnlyUserIdBase in Bridge.WebChannel.ps1.</summary>
    public const long WebOnlyIdBase = 9_000_000_000_000_000L;

    public long NextWebOnlyId { get; set; } = WebOnlyIdBase + 1;
    public List<WebAccount> Accounts { get; set; } = [];
}

public enum SignInOutcome { Success, Invalid, Locked }

public sealed record SignInResult(SignInOutcome Outcome, WebAccount? Account = null, DateTimeOffset? LockedUntil = null);

public sealed partial class AccountStore(WebOptions options, TimeProvider clock)
{
    public const int MaxFailedAttempts = 5;
    public static readonly TimeSpan LockoutDuration = TimeSpan.FromMinutes(15);

    private readonly JsonFileStore<AccountsDocument> _store =
        new(Path.Combine(options.StateDirectory, "accounts.json"), () => new AccountsDocument());

    [GeneratedRegex("^[a-z0-9._-]{3,32}$")]
    private static partial Regex UsernamePattern();

    public static string Normalize(string username) => username.Trim().ToLowerInvariant();

    public static bool IsValidUsername(string? username) =>
        username is not null && UsernamePattern().IsMatch(Normalize(username));

    public Task<IReadOnlyList<WebAccount>> ListAsync() =>
        _store.ReadAsync<IReadOnlyList<WebAccount>>(document => [.. document.Accounts.OrderBy(a => a.Username)]);

    public Task<WebAccount?> FindAsync(string username)
    {
        var key = Normalize(username);
        return _store.ReadAsync(document => document.Accounts.FirstOrDefault(a => a.Username == key));
    }

    public Task<long> ReserveWebOnlyIdAsync() =>
        _store.UpdateAsync(document => (true, document.NextWebOnlyId++));

    public Task<bool> AddAsync(WebAccount account) =>
        _store.UpdateAsync(document =>
        {
            if (document.Accounts.Any(a => a.Username == account.Username || a.UserId == account.UserId)) return (false, false);
            document.Accounts.Add(account);
            return (true, true);
        });

    public Task<WebAccount?> RemoveAsync(string username)
    {
        var key = Normalize(username);
        return _store.UpdateAsync(document =>
        {
            var account = document.Accounts.FirstOrDefault(a => a.Username == key);
            if (account is null) return (false, (WebAccount?)null);
            document.Accounts.Remove(account);
            return (true, account);
        });
    }

    public Task<bool> SetPasswordAsync(string username, PasswordHash password) =>
        Replace(username, account => account with { Password = password, FailedAttempts = 0, LockedUntil = null });

    /// <summary>Checks a password and keeps the lockout count. The answer for
    /// an unknown name and a wrong password is the same, and takes as long.</summary>
    public async Task<SignInResult> SignInAsync(string username, string password)
    {
        var account = await FindAsync(username);
        if (account is null)
        {
            PasswordHasher.VerifyDummy(password);
            return new SignInResult(SignInOutcome.Invalid);
        }
        var now = clock.GetUtcNow();
        if (account.LockedUntil > now) return new SignInResult(SignInOutcome.Locked, LockedUntil: account.LockedUntil);

        if (!PasswordHasher.Verify(password, account.Password))
        {
            var failures = account.FailedAttempts + 1;
            var lockedUntil = failures >= MaxFailedAttempts ? now + LockoutDuration : (DateTimeOffset?)null;
            await Replace(account.Username, a => a with { FailedAttempts = lockedUntil is null ? failures : 0, LockedUntil = lockedUntil });
            return lockedUntil is null
                ? new SignInResult(SignInOutcome.Invalid)
                : new SignInResult(SignInOutcome.Locked, LockedUntil: lockedUntil);
        }
        var signedIn = account with { FailedAttempts = 0, LockedUntil = null, LastLoginAt = now };
        await Replace(account.Username, _ => signedIn);
        return new SignInResult(SignInOutcome.Success, signedIn);
    }

    private Task<bool> Replace(string username, Func<WebAccount, WebAccount> change)
    {
        var key = Normalize(username);
        return _store.UpdateAsync(document =>
        {
            var index = document.Accounts.FindIndex(a => a.Username == key);
            if (index < 0) return (false, false);
            document.Accounts[index] = change(document.Accounts[index]);
            return (true, true);
        });
    }
}
