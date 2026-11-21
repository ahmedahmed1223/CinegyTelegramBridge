using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

// Mirrors Get-WebStatusSnapshot in Parts/Bridge.WebChannel.ps1. Instants are
// Unix milliseconds; 0 means "not known". The server passes the bridge's JSON
// through untouched - these records exist to document and type it.
public sealed record TelegramStatus(string State, int Failures);

public sealed record CinegyStatus(string Address, int Channel, string Health, long LastReadAt, long FreshUntil);

public sealed record LayerStatus(int Layer, string Key, string Name, long At, long HideAt, string Source, string By);

public sealed record FeedOutage(string Kind, long StartedAt, long EndedAt);

public sealed record FeedStatus(string State, string ActiveSource, bool BackupConfigured, int IntervalMinutes,
    long LastCheckAt, int OutageCount, int OutageSeconds, IReadOnlyList<FeedOutage> Recent);

public sealed record BridgeStatus(string Version, long StartedAt, long PublishedAt, TelegramStatus Telegram, CinegyStatus Cinegy,
    IReadOnlyList<LayerStatus> Layers, FeedStatus? Feed);

public sealed record StatusEnvelope(bool Online, BridgeStatus? Status);
public sealed record LivePlayback(string? Url);
public sealed record RelayState(string State, string Revision, bool Enabled, bool Configured, bool CanStart, bool CanStop, bool CanEditDestination, string Outcome);
public sealed record RelayRequest(string Action, string? Revision = null);

public static class StatusEndpoints
{
    private static readonly TimeSpan Heartbeat = TimeSpan.FromSeconds(15);

    public static void MapStatusEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/status").WithTags("Status").RequireAuthorization();

        api.MapGet("", (StatusFeed feed) => Results.Content(feed.Latest, "application/json"))
            .Produces<StatusEnvelope>();

        // Server-sent events: one "status" event per change, the same
        // envelope as GET /api/status. EventSource reconnects by itself.
        api.MapGet("/stream", Stream).Produces(StatusCodes.Status200OK, contentType: "text/event-stream");

        api.MapGet("/programme", (IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<ProgrammeNowNext>(bridge, http, null, "air.programme"))
            .Produces<ProgrammeNowNext>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);

        api.MapGet("/layer-comparison", (IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerComparisonTargets>(bridge, http, null))
            .Produces<LayerComparisonTargets>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        api.MapGet("/layer-comparison/{layer:int}", (int layer, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerComparison>(bridge, http, layer))
            .Produces<LayerComparison>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);
        api.MapPost("/layer-comparison/{layer:int}/adopt/review", (int layer, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerAdoptionReview>(bridge, http, layer, "air.layer-adoption.review"))
            .Produces<LayerAdoptionReview>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);
        api.MapPost("/layer-comparison/{layer:int}/adopt/confirm", (int layer, LayerAdoptionConfirmCommand request, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerAdoptionResult>(bridge, http, layer, "air.layer-adoption.confirm", request.Review))
            .Produces<LayerAdoptionResult>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);
        api.MapPost("/layer-comparison/{layer:int}/forget/review", (int layer, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerForgetReview>(bridge, http, layer, "air.layer-forget.review"))
            .Produces<LayerForgetReview>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);
        api.MapPost("/layer-comparison/{layer:int}/forget/confirm", (int layer, LayerForgetConfirmCommand request, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerForgetResult>(bridge, http, layer, "air.layer-forget.confirm", request.Review))
            .Produces<LayerForgetResult>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);

        api.MapPost("/layer-comparison/{layer:int}/replace/review", (int layer, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerReplacementReview>(bridge, http, layer, "air.layer-replacement.review"))
            .Produces<LayerReplacementReview>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);
        api.MapPost("/layer-comparison/{layer:int}/replace/confirm", (int layer, LayerReplacementConfirmCommand request, IBridgeChannel bridge, HttpContext http) =>
                ReadLayerComparison<LayerReplacementResult>(bridge, http, layer, "air.layer-replacement.confirm", request.Review))
            .Produces<LayerReplacementResult>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);

        app.MapGet("/api/live", (HttpContext http, WebOptions options) =>
            {
                http.Response.Headers.CacheControl = "no-store";
                return TypedResults.Ok(new LivePlayback(options.LivePlaybackUri?.AbsoluteUri));
            })
            .WithTags("Status")
            .RequireAuthorization()
            .Produces<LivePlayback>();

        var relay = app.MapGroup("/api/live/relay").WithTags("Status").RequireAuthorization(AccountEndpoints.AdminPolicy);
        relay.MapGet("", (IBridgeChannel bridge, HttpContext http) => ControlRelay(new("status"), bridge, http))
            .Produces<RelayState>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        relay.MapPost("", ControlRelay)
            .Produces<RelayState>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        relay.MapPost("/destination/review", ReviewRelayDestination)
            .Produces<RelayDestinationReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        relay.MapPost("/destination/confirm", ConfirmRelayDestination)
            .Produces<RelayState>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        var captures = app.MapGroup("/api/live/captures").WithTags("Status").RequireAuthorization();
        captures.MapPost("", (CaptureCreateRequest request, IBridgeChannel bridge, HttpContext http) =>
                request.Kind is "photo" or "clip"
                    ? ReadCapture(bridge, http, "start", null, request.Kind)
                    : Task.FromResult(ApiErrors.Of(400, "capture_invalid")))
            .Produces<OutputCapture>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(429)
            .Produces<ErrorResponse>(503);
        captures.MapGet("/{id}", (string id, IBridgeChannel bridge, HttpContext http) =>
                ReadCapture(bridge, http, "status", id, null))
            .Produces<OutputCapture>()
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(503);
        captures.MapGet("/{id}/file", ReadCaptureFile)
            .Produces(200, contentType: "image/jpeg", additionalContentTypes: ["video/mp4"])
            .Produces(206, contentType: "video/mp4")
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> ReadLayerComparison<T>(IBridgeChannel bridge, HttpContext http, int? layer,
        string operation = "air.layer-comparison", string? review = null)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, new { actor = http.User.UserId(), layer, review }, http.RequestAborted);
        if (reply.Ok)
            return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "layer_comparison_missing" => ApiErrors.Of(404, reply.Error),
            "layer_comparison_busy" => ApiErrors.Of(429, reply.Error),
            "layer_adoption_stale" or "layer_adoption_unavailable" or
                "layer_forget_stale" or "layer_forget_unavailable" or
                "layer_replacement_stale" or "layer_replacement_unavailable" => ApiErrors.Of(409, reply.Error),
            "bridge_busy" or "layer_adoption_save_failed" or "layer_forget_save_failed" or "layer_replacement_save_failed" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable(),
        };
    }

    private static IResult CaptureError(string? code) => code switch
    {
        "forbidden" => ApiErrors.Of(403, code),
        "not_found" => ApiErrors.Of(404, code),
        "capture_invalid" => ApiErrors.Of(400, code),
        "capture_disabled" or "capture_busy" => ApiErrors.Of(409, code),
        "capture_capacity" or "capture_actor_capacity" => ApiErrors.Of(429, code),
        "capture_no_source" or "capture_no_encoder" or "capture_bad_input" or "capture_start_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };

    private static async Task<IResult> ReadCapture(IBridgeChannel bridge, HttpContext http, string action, string? id, string? kind)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (id is not null && !Guid.TryParseExact(id, "N", out _)) return CaptureError("not_found");
        var reply = await bridge.SendAsync("media.capture", new { actor = http.User.UserId(), action, id, kind }, http.RequestAborted);
        return reply.Ok ? TypedResults.Ok(reply.Data.Deserialize<OutputCapture>(JsonDefaults.Options)) : CaptureError(reply.Error);
    }

    private sealed record CaptureFile(string Kind, string Path);

    private static async Task<IResult> ReadCaptureFile(string id, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (!Guid.TryParseExact(id, "N", out var captureId)) return CaptureError("not_found");
        var reply = await bridge.SendAsync("media.capture", new { actor = http.User.UserId(), action = "file", id }, http.RequestAborted);
        if (!reply.Ok) return CaptureError(reply.Error);
        var file = reply.Data.Deserialize<CaptureFile>(JsonDefaults.Options);
        var extension = file?.Kind switch { "photo" => "jpg", "clip" => "mp4", _ => null };
        if (file is null || extension is null || string.IsNullOrEmpty(file.Path) || !Path.IsPathFullyQualified(file.Path) ||
            !string.Equals(Path.GetFileName(file.Path), $"snapshot-web-{captureId:N}.{extension}", StringComparison.OrdinalIgnoreCase))
            return CaptureError("not_found");
        try
        {
            if ((File.GetAttributes(file.Path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                return CaptureError("not_found");
            var stream = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (stream.Length is > 0 and <= 32 * 1024 * 1024)
                return Results.File(stream, extension == "mp4" ? "video/mp4" : "image/jpeg", enableRangeProcessing: true);
            stream.Dispose();
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return CaptureError("not_found");
    }

    private static async Task<IResult> ControlRelay(RelayRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("relay.control", new { actor = http.User.UserId(), request.Action, request.Revision }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<RelayState>(JsonDefaults.Options));
        }
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "relay_invalid" => ApiErrors.Of(400, reply.Error),
            "relay_stale" or "relay_unavailable" => ApiErrors.Of(409, reply.Error),
            "relay_start_failed" or "relay_stop_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static Task<IResult> ReviewRelayDestination(RelayDestinationReviewRequest request, IBridgeChannel bridge, HttpContext http) =>
        SendRelayDestination<RelayDestinationReview>("relay.destination.review", request.Destination, request.Revision, null, bridge, http);

    private static Task<IResult> ConfirmRelayDestination(RelayDestinationConfirmRequest request, IBridgeChannel bridge, HttpContext http) =>
        SendRelayDestination<RelayState>("relay.destination.confirm", request.Destination, request.Revision, request.Review, bridge, http);

    private static async Task<IResult> SendRelayDestination<T>(string op, string? destination, string? revision, string? review,
        IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (destination is not { Length: > 0 and <= 4096 } || revision is not { Length: 64 } ||
            (op.EndsWith(".confirm", StringComparison.Ordinal) && review is not { Length: 32 }))
            return ApiErrors.Of(400, "relay_invalid");

        var reply = await bridge.SendAsync(op, new { actor = http.User.UserId(), destination, revision, review }, http.RequestAborted);
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "relay_invalid" => ApiErrors.Of(400, reply.Error),
            "relay_stale" or "relay_unavailable" => ApiErrors.Of(409, reply.Error),
            "relay_config_failed" or "bridge_timeout" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task Stream(HttpContext http, StatusFeed feed)
    {
        http.Response.Headers.ContentType = "text/event-stream";
        http.Response.Headers.CacheControl = "no-store";
        // Cloudflare and other proxies buffer a response unless told not to.
        http.Response.Headers["X-Accel-Buffering"] = "no";
        var (id, reader) = feed.Subscribe();
        try
        {
            var aborted = http.RequestAborted;
            while (!aborted.IsCancellationRequested)
            {
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(aborted);
                wait.CancelAfter(Heartbeat);
                string message;
                try { message = await reader.ReadAsync(wait.Token); }
                catch (OperationCanceledException) when (!aborted.IsCancellationRequested)
                {
                    await http.Response.WriteAsync(": keep-alive\n\n", aborted);
                    await http.Response.Body.FlushAsync(aborted);
                    continue;
                }
                await http.Response.WriteAsync($"event: status\ndata: {message}\n\n", aborted);
                await http.Response.Body.FlushAsync(aborted);
            }
        }
        catch (OperationCanceledException) { /* the browser went away */ }
        finally { feed.Unsubscribe(id); }
    }
}
