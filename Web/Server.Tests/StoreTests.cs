using CinegyBridge.Web.Accounts;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;
using Microsoft.Extensions.Time.Testing;

namespace CinegyBridge.Web.Tests;

public sealed class StoreTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("cgb-store-test-").FullName;
    private readonly FakeTimeProvider _clock = new(new DateTimeOffset(2026, 11, 19, 20, 0, 0, TimeSpan.Zero));

    public void Dispose() => Directory.Delete(_root, recursive: true);

    private WebOptions Options => new() { BridgeRoot = _root };

    [Fact]
    public void A_password_verifies_only_against_its_own_hash()
    {
        var hash = PasswordHasher.Hash("correct horse battery");
        Assert.True(PasswordHasher.Verify("correct horse battery", hash));
        Assert.False(PasswordHasher.Verify("correct horse batterY", hash));
        Assert.NotEqual(hash.Salt, PasswordHasher.Hash("correct horse battery").Salt);
    }

    [Fact]
    public async Task A_lockout_ends_on_its_own()
    {
        var store = new AccountStore(Options, _clock);
        await store.AddAsync(new WebAccount { Username = "desk", UserId = 1, DisplayName = "d", Password = PasswordHasher.Hash("correct horse battery") });
        for (var i = 0; i < AccountStore.MaxFailedAttempts; i++) await store.SignInAsync("desk", "wrong password!!");
        Assert.Equal(SignInOutcome.Locked, (await store.SignInAsync("desk", "correct horse battery")).Outcome);

        _clock.Advance(AccountStore.LockoutDuration + TimeSpan.FromSeconds(1));
        Assert.Equal(SignInOutcome.Success, (await store.SignInAsync("desk", "correct horse battery")).Outcome);
    }

    [Fact]
    public async Task Accounts_survive_a_restart_of_the_server()
    {
        await new AccountStore(Options, _clock).AddAsync(new WebAccount { Username = "desk", UserId = 1, DisplayName = "d", Password = PasswordHasher.Hash("correct horse battery") });
        Assert.NotNull(await new AccountStore(Options, _clock).FindAsync("DESK"));
    }

    [Fact]
    public async Task An_idle_session_expires_and_a_used_one_does_not()
    {
        var sessions = new SessionStore(Options, _clock);
        var idle = await sessions.CreateAsync(1, "password", "desk", "127.0.0.1", "test");
        var busy = await sessions.CreateAsync(2, "password", "desk2", "127.0.0.1", "test");
        for (var hour = 0; hour < 13; hour++)
        {
            _clock.Advance(TimeSpan.FromHours(1));
            Assert.NotNull(await sessions.TouchAsync(busy.Id));
        }
        Assert.Null(await sessions.TouchAsync(idle.Id));
    }

    [Fact]
    public async Task No_session_outlives_the_absolute_limit_however_busy()
    {
        var sessions = new SessionStore(Options, _clock);
        var session = await sessions.CreateAsync(1, "password", "desk", "127.0.0.1", "test");
        for (var hour = 0; hour < 24 * 7; hour++)
        {
            _clock.Advance(TimeSpan.FromHours(1));
            await sessions.TouchAsync(session.Id);
        }
        _clock.Advance(TimeSpan.FromHours(1));
        Assert.Null(await sessions.TouchAsync(session.Id));
    }

    [Theory]
    [InlineData("""{"ok":true,"data":{"x":1}}""", true, "")]
    [InlineData("""{"ok":false,"error":"forbidden"}""", false, "forbidden")]
    [InlineData("", false, "bridge_unavailable")]
    public void The_pipe_reply_is_read_as_the_bridge_wrote_it(string line, bool ok, string error)
    {
        var reply = PipeBridgeChannel.Parse(line);
        Assert.Equal(ok, reply.Ok);
        Assert.Equal(error, reply.Error);
    }
}
