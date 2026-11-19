using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

// Mirrors Get-WebStatusSnapshot in Parts/Bridge.WebChannel.ps1. Instants are
// Unix milliseconds; 0 means "not known". The server passes the bridge's JSON
// through untouched - these records exist to document and type it.
public sealed record TelegramStatus(string State, int Failures);

public sealed record CinegyStatus(string Address, int Channel, string Health, long LastReadAt, long FreshUntil);

public sealed record LayerStatus(int Layer, string Key, string Name, long At, long HideAt, string Source, string By);

public sealed record BridgeStatus(string Version, long StartedAt, long PublishedAt, TelegramStatus Telegram, CinegyStatus Cinegy, IReadOnlyList<LayerStatus> Layers);

public sealed record StatusEnvelope(bool Online, BridgeStatus? Status);

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
