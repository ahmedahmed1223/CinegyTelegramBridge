using System.Collections.Concurrent;
using System.Text.Json;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Tests;

/// <summary>
/// Stands in for the bridge at the pipe boundary: everything above it - the
/// server's own checks, cookies, anti-forgery - runs for real.
/// </summary>
public sealed class FakeBridge : IBridgeChannel
{
    public ConcurrentDictionary<long, (string Name, string Role)> Users { get; } = new();
    public ConcurrentDictionary<string, string> LoginStates { get; } = new();
    public ConcurrentDictionary<string, long> LoginApprovals { get; } = new();
    public ConcurrentQueue<(string Op, string Args)> Calls { get; } = new();
    public bool Online { get; set; } = true;
    public string LastLoginCode { get; private set; } = "";
    public string? CapturePath { get; set; }
    public (string Root, string Path)? BulletinPreviewImage { get; set; }
    public string CaptureId { get; } = Guid.NewGuid().ToString("N");
    public string? TickerTxtDirectory { get; set; }
    public byte[]? TickerTxtBytes { get; private set; }

    public Task<BridgeReply> SendAsync(string op, object? args = null, CancellationToken cancellationToken = default)
    {
        var json = args is null ? "{}" : JsonSerializer.Serialize(args, JsonDefaults.Options);
        Calls.Enqueue((op, json));
        if (!Online) return Task.FromResult(BridgeReply.Unavailable);
        using var document = JsonDocument.Parse(json);
        var a = document.RootElement;
        return Task.FromResult(op switch
        {
            "status" => Reply("""{"version":"test","startedAt":0,"publishedAt":0,"telegram":{"state":"connected","failures":0},"cinegy":{"address":"127.0.0.1","channel":0,"health":"healthy","lastReadAt":0,"freshUntil":0},"layers":[]}"""),
            "identity" => Users.TryGetValue(a.GetProperty("userId").GetInt64(), out var user) ? Reply(UserJson(a.GetProperty("userId").GetInt64(), user)) : Reply("null"),
            "roster" => Reply("[" + string.Join(',', Users.Select(u => UserJson(u.Key, u.Value))) + "]"),
            "login.register" => Register(a.GetProperty("code").GetString()!),
            "login.status" => LoginStatus(a.GetProperty("code").GetString()!),
            "account.grant" => Grant(a),
            "account.revoke" => Revoke(a),
            "air.templates" => Reply("""[{"key":"test_l3d","name":"Lower Third","layer":5,"category":"news","disabled":false,"fields":[{"name":"title","label":"العنوان","required":true,"maxLength":40}]}]"""),
            "air.show" => Reply("null"),
            "air.hide" => Reply("null"),
            "air.exit" => Reply("null"),
            "content.list" => Reply("""{"items":[{"title":"خبر منشور","state":"published","rows":null}],"page":1,"pageCount":2,"total":21}"""),
            "ticker.txt" => TickerTxt(a),
            "media.capture" => Capture(a),
            "bulletin.playback" => a.GetProperty("action").GetString() switch
            {
                "status" => Reply("""{"canStart":true,"busy":false}"""),
                "review" => Reply("""{"canStart":true,"busy":false,"review":"ticket","layer":4,"replacing":false}"""),
                _ => new BridgeReply(false, default, "bulletin_playback_stale")
            },
            "bulletin.preview-image" => BulletinPreviewImage is { } picture
                ? Reply(JsonSerializer.Serialize(new { root = picture.Root, path = picture.Path }))
                : new BridgeReply(false, default, "not_found"),
            "relay.control" => a.GetProperty("action").GetString() == "status"
                ? Reply("""{"state":"stopped","revision":"review","enabled":true,"configured":true,"canStart":true,"canStop":false,"outcome":""}""")
                : Reply("""{"state":"starting","revision":"next","enabled":true,"configured":true,"canStart":false,"canStop":true,"outcome":"starting"}"""),
            "urgent.write" => a.GetProperty("revision").GetInt32() == 3
                ? Reply("null")
                : new BridgeReply(false, default, "urgent_stale"),
            _ => new BridgeReply(false, default, "unknown_op"),
        });
    }

    private BridgeReply TickerTxt(JsonElement args)
    {
        if (args.GetProperty("actor").GetInt64() != WebApp.Operator || TickerTxtDirectory is null)
            return new BridgeReply(false, default, "ticker_locked");
        if (args.GetProperty("action").GetString() == "prepare")
            return Reply(JsonSerializer.Serialize(new { directory = TickerTxtDirectory, maximumBytes = 70_000 }));
        var id = args.GetProperty("upload").GetString();
        using var upload = new FileStream(Path.Combine(TickerTxtDirectory, $"web-{id}.txt"), FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete);
        using var copy = new MemoryStream();
        upload.CopyTo(copy);
        TickerTxtBytes = copy.ToArray();
        return Reply("""{"review":"review","items":["خبر جديد"],"currentItems":["المسودة"],"duplicates":0,"identical":false,"cancelsSchedule":true}""");
    }

    private BridgeReply Capture(JsonElement args)
    {
        if (args.GetProperty("actor").GetInt64() != WebApp.Operator)
            return new BridgeReply(false, default, "not_found");
        return args.GetProperty("action").GetString() == "file"
            ? Reply(JsonSerializer.Serialize(new { kind = "clip", path = CapturePath }))
            : Reply(JsonSerializer.Serialize(new { id = CaptureId, kind = "clip", state = "ready", source = "primary", completedAt = 1, expiresAt = 2 }));
    }

    public void Approve(string code, long userId)
    {
        LoginStates[code] = "approved";
        LoginApprovals[code] = userId;
    }

    private BridgeReply Register(string code)
    {
        LastLoginCode = code;
        LoginStates[code] = "pending";
        return Reply("""{"botUsername":"test_bot","expiresInSeconds":300}""");
    }

    private BridgeReply LoginStatus(string code)
    {
        if (!LoginStates.TryGetValue(code, out var state)) return Reply("""{"state":"expired"}""");
        if (state == "approved")
        {
            LoginStates.TryRemove(code, out _);
            return Reply($$"""{"state":"approved","userId":{{LoginApprovals[code]}}}""");
        }
        return Reply($$"""{"state":"{{state}}"}""");
    }

    private BridgeReply Grant(JsonElement a)
    {
        var actor = a.GetProperty("actor").GetInt64();
        var role = a.GetProperty("role").GetString()!;
        if (!Users.TryGetValue(actor, out var who) || who.Role is not ("admin" or "owner")) return new BridgeReply(false, default, "forbidden");
        if (role == "admin" && who.Role != "owner") return new BridgeReply(false, default, "owner_only");
        Users[a.GetProperty("userId").GetInt64()] = (a.GetProperty("name").GetString()!, role);
        return Reply("null");
    }

    private BridgeReply Revoke(JsonElement a)
    {
        Users.TryRemove(a.GetProperty("userId").GetInt64(), out _);
        return Reply("null");
    }

    private static string UserJson(long id, (string Name, string Role) user) =>
        JsonSerializer.Serialize(new { id, name = user.Name, role = user.Role, webOnly = id >= 9_000_000_000_000_000L });

    private static BridgeReply Reply(string data)
    {
        using var document = JsonDocument.Parse(data);
        return new BridgeReply(true, document.RootElement.Clone(), "");
    }
}
