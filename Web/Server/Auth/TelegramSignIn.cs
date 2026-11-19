using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Auth;

public sealed record TelegramSignInStart(string FlowId, string Code, string BotUsername, DateTimeOffset ExpiresAt);

public enum TelegramSignInState { Pending, Approved, Denied, Expired, Unavailable }

public sealed record TelegramSignInPoll(TelegramSignInState State, long UserId = 0);

/// <summary>
/// Sign-in by approval in Telegram. The browser gets a six-digit code and an
/// unguessable flow id; the person sends the code to the bot and approves on a
/// message that names where the request came from; the browser, polling with
/// its flow id, then receives the session. The code alone opens nothing.
/// </summary>
public sealed class TelegramSignIn(IBridgeChannel bridge, TimeProvider clock)
{
    private const int MaxFlows = 200;
    private readonly ConcurrentDictionary<string, (string Code, DateTimeOffset ExpiresAt)> _flows = new();

    public async Task<(TelegramSignInStart? Start, string Error)> BeginAsync(string address, string agent, CancellationToken cancellationToken)
    {
        Purge();
        if (_flows.Count >= MaxFlows) return (null, "too_many");
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
            var reply = await bridge.SendAsync("login.register", new { code, address, agent }, cancellationToken);
            if (reply.IsUnavailable) return (null, "bridge_unavailable");
            if (!reply.Ok && reply.Error == "code_in_use") continue;
            if (!reply.Ok) return (null, reply.Error);

            var lifetime = reply.Data.TryGetProperty("expiresInSeconds", out var seconds) ? seconds.GetInt32() : 300;
            var bot = reply.Data.TryGetProperty("botUsername", out var name) && name.ValueKind == JsonValueKind.String ? name.GetString() ?? "" : "";
            var expiresAt = clock.GetUtcNow().AddSeconds(lifetime);
            var flowId = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
            _flows[flowId] = (code, expiresAt);
            return (new TelegramSignInStart(flowId, code, bot, expiresAt), "");
        }
        return (null, "code_in_use");
    }

    public async Task<TelegramSignInPoll> PollAsync(string flowId, CancellationToken cancellationToken)
    {
        if (!_flows.TryGetValue(flowId, out var flow) || flow.ExpiresAt <= clock.GetUtcNow())
        {
            _flows.TryRemove(flowId, out _);
            return new TelegramSignInPoll(TelegramSignInState.Expired);
        }
        var reply = await bridge.SendAsync("login.status", new { code = flow.Code }, cancellationToken);
        if (!reply.Ok) return new TelegramSignInPoll(TelegramSignInState.Unavailable);

        var state = reply.Data.GetProperty("state").GetString();
        switch (state)
        {
            case "pending":
                return new TelegramSignInPoll(TelegramSignInState.Pending);
            case "approved":
                _flows.TryRemove(flowId, out _);
                return new TelegramSignInPoll(TelegramSignInState.Approved, reply.Data.GetProperty("userId").GetInt64());
            case "denied":
                _flows.TryRemove(flowId, out _);
                return new TelegramSignInPoll(TelegramSignInState.Denied);
            default:
                _flows.TryRemove(flowId, out _);
                return new TelegramSignInPoll(TelegramSignInState.Expired);
        }
    }

    private void Purge()
    {
        var now = clock.GetUtcNow();
        foreach (var (id, flow) in _flows)
        {
            if (flow.ExpiresAt <= now) _flows.TryRemove(id, out _);
        }
    }
}
