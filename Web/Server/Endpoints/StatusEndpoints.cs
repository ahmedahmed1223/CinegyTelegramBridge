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
public sealed record RelayState(string State, string Revision, bool Enabled, bool Configured, bool CanStart, bool CanStop, string Outcome);
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
