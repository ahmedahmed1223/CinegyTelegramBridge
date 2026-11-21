using System.Collections.Concurrent;
using System.Security.Cryptography;
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
    public string? RegistryTransferDirectory { get; set; }
    public byte[] RegistryTransferBytes { get; set; } = [123, 32, 13, 10, 125];
    public byte[]? RegistryUploadBytes { get; private set; }

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
            "air.layer-removal" => a.GetProperty("action").GetString() switch
            {
                "preview" => Reply("""{"preview":{"review":"remove-fixture","layer":5,"operation":"hide","templateKey":"test_l3d","expiresAt":1893456000000}}"""),
                "apply" when a.GetProperty("review").GetString() == "remove-fixture" => Reply("""{"sent":true}"""),
                _ => new BridgeReply(false, default, "layer_removal_stale")
            },
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
            "bulletin.scene-images" => a.GetProperty("action").GetString() switch
            {
                "list" => Reply("""{"selection":"scene-image-ticket","page":0,"pageCount":1,"truncated":false,"items":[{"slot":0,"label":"logo.png","bytes":532}]}"""),
                "apply" when a.GetProperty("selection").GetString() == "scene-image-ticket" =>
                    Reply("""{"id":"morning","name":"Morning","design":"bulletin","revision":4,"fields":[],"rows":[],"pageCount":1}"""),
                _ => new BridgeReply(false, default, "bulletin_scene_image_stale")
            },
            "reports.bulletins" when a.GetProperty("scope").GetString() == "all" && a.GetProperty("actor").GetInt64() == WebApp.Operator =>
                new BridgeReply(false, default, "forbidden"),
            "reports.bulletins" when a.GetProperty("action").GetString() == "export" =>
                Reply("""{"html":"<!doctype html><p>Fixture bulletin</p>","count":1,"total":1,"truncated":false}"""),
            "reports.ticker" when a.GetProperty("scope").GetString() == "all" && a.GetProperty("actor").GetInt64() == WebApp.Operator =>
                new BridgeReply(false, default, "forbidden"),
            "reports.ticker" when a.GetProperty("action").GetString() == "export" =>
                Reply("""{"html":"<!doctype html><p>Fixture ticker</p>","days":1,"publishes":2,"truncated":false}"""),
            "air.template-registry-import" => RegistryTransfer(a, export: false),
            "air.template-registry-export" => RegistryTransfer(a, export: true),
            "shift.operation-reference" => a.GetProperty("reference").GetString() switch
            {
                "5023333B" => Reply("""{"status":"found","readLimit":5000,"truncated":false,"items":[{"atMs":1773133200000,"stationTime":"2026-03-10 09:00:00 +00:00","action":"SHOW","result":"failed","layer":7,"durationMs":50}]}"""),
                "abcdef01" => Reply("""{"status":"collision","readLimit":5000,"truncated":false,"items":[]}"""),
                "f00dcafe" => Reply("""{"status":"missing","readLimit":5000,"truncated":false,"items":[]}"""),
                _ => new BridgeReply(false, default, "operation_reference_invalid"),
            },
            "reports.weekly" => Reply("""{"from":"2026-03-04 00:00:00 +02:00","through":"2026-03-10 09:00:00 +02:00","tickerPublishes":2,"tickerLast":"","urgentRuns":1,"urgentStories":1,"nearLimit":false,"peakScreen":"","peakPercent":0,"idleCount":0,"idle":[],"repeatCounts":[2],"changedCount":0,"changed":[],"truncated":false}"""),
            "reports.handover" => Reply("""{"hours":4,"truncated":false,"connection":"Cinegy: healthy","activeCount":0,"active":[],"showCount":2,"hiddenGroups":0,"shows":[],"removalCount":1,"lastRemoval":"","failureCount":0,"blockedCount":0,"notableCount":0,"recentFailures":[]}"""),
            "reports.templates" when a.GetProperty("scope").GetString() == "all" && a.GetProperty("actor").GetInt64() == WebApp.Operator =>
                new BridgeReply(false, default, "forbidden"),
            "reports.templates" when a.GetProperty("action").GetString() == "export" =>
                Reply("""{"html":"<!doctype html><p>Fixture banner</p>","count":1,"total":1,"truncated":false}"""),
            "reports.templates" =>
                Reply("""{"period":"today","scope":"mine","total":1,"operators":1,"withoutEnd":0,"truncated":false,"page":0,"pageCount":1,"items":[{"name":"Fixture banner","operatorName":"Operator desk","layer":4,"started":"2026-03-10 08:00:00 +02:00","ended":"2026-03-10 08:02:00 +02:00","duration":"2 min","endedBy":"Replacement"}]}"""),
            "reports.ticker" =>
                Reply("""{"period":"today","scope":"mine","publishes":2,"items":11,"silentDays":0,"lastPublishedAt":"2026-03-10 08:05:00 +02:00","truncated":false,"days":[{"date":"2026-03-10","publishes":2,"items":11,"first":"2026-03-10 08:00:00 +02:00","last":"2026-03-10 08:05:00 +02:00","range":"8–11","edits":"8 ← 11","operators":"Ticker desk"}]}"""),
            "reports.bulletins" =>
                Reply("""{"period":"today","scope":"mine","total":1,"rows":3,"operators":1,"scheduled":1,"truncated":false,"page":0,"pageCount":1,"items":[{"name":"Fixture bulletin","operatorName":"Fixture operator","started":"2026-03-10 08:00:00 +02:00","ended":"","duration":"","rows":3,"scheduled":true}]}"""),
            "bulletin.management" => a.GetProperty("action").GetString() switch
            {
                "review" => Reply("""{"id":"morning","revision":3,"operation":"delete","name":"Morning","rowCount":4,"pendingCount":2,"referenceCount":3,"review":"management-ticket"}"""),
                "confirm" when a.GetProperty("review").GetString() == "management-ticket" =>
                    Reply("""{"id":"morning","operation":"delete","revision":null}"""),
                _ => new BridgeReply(false, default, "bulletin_stale")
            },
            "bulletin.afterUrgent" => a.GetProperty("action").GetString() switch
            {
                "review" => Reply("""{"id":"morning","revision":3,"name":"Morning","rowCount":4,"urgentLayer":7,"review":"queue-ticket"}"""),
                "confirm" when a.GetProperty("review").GetString() == "queue-ticket" =>
                    Reply("""{"id":"morning","alreadyQueued":false}"""),
                _ => new BridgeReply(false, default, "bulletin_urgent_gone")
            },
            "relay.control" => a.GetProperty("action").GetString() == "status"
                ? Reply("""{"state":"stopped","revision":"review","enabled":true,"configured":true,"canStart":true,"canStop":false,"outcome":""}""")
                : Reply("""{"state":"starting","revision":"next","enabled":true,"configured":true,"canStart":false,"canStop":true,"outcome":"starting"}"""),
            "urgent.write" => a.GetProperty("revision").GetInt32() == 3
                ? Reply("null")
                : new BridgeReply(false, default, "urgent_stale"),
            _ => new BridgeReply(false, default, "unknown_op"),
        });
    }

    private BridgeReply RegistryTransfer(JsonElement args, bool export)
    {
        const string ticket = "0123456789abcdef0123456789abcdef";
        var action = args.GetProperty("action").GetString();
        if (RegistryTransferDirectory is not { } directory) return BridgeReply.Unavailable;
        if (action == "prepare")
            return Reply(JsonSerializer.Serialize(new { directory, maximumBytes = 10 * 1024 * 1024 }));
        if (export && action == "review")
            return Reply(JsonSerializer.Serialize(new { review = ticket, templates = 1, bytes = RegistryTransferBytes.Length }));
        if (action != "review" && args.GetProperty("review").GetString() != ticket)
            return new BridgeReply(false, default, "template_registry_import_stale");
        var id = args.GetProperty("transferId").GetString();
        var path = Path.Combine(directory, $"{(export ? "download" : "upload")}-{id}.json");
        const FileShare share = FileShare.ReadWrite | FileShare.Delete;
        if (export)
        {
            using var target = new FileStream(path, FileMode.Open, FileAccess.Write, share);
            target.Write(RegistryTransferBytes);
            return Reply(JsonSerializer.Serialize(new
            {
                bytes = RegistryTransferBytes.Length,
                sha256 = Convert.ToHexString(SHA256.HashData(RegistryTransferBytes)),
            }));
        }
        using var upload = new FileStream(path, FileMode.Open, FileAccess.Read, share);
        var bytes = new byte[checked((int)upload.Length)];
        upload.ReadExactly(bytes);
        RegistryUploadBytes = bytes;
        if (action == "review")
            return Reply("""{"review":"0123456789abcdef0123456789abcdef","templates":2,"added":1,"changed":0,"removed":0,"unchanged":1}""");
        RegistryTransferBytes = bytes;
        return Reply("{}");
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
