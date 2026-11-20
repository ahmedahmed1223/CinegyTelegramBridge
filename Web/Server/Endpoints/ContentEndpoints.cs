using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class ContentEndpoints
{
    public static void MapContentEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/content/{view}", List)
            .WithTags("Content")
            .RequireAuthorization()
            .Produces<ContentPage>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        app.MapPost("/api/content/urgent", WriteUrgent)
            .WithTags("Content")
            .RequireAuthorization()
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        var playback = app.MapGroup("/api/content/urgent/playback").WithTags("Content").RequireAuthorization();
        playback.MapGet("", (IBridgeChannel bridge, HttpContext http) => UrgentPlayback(new("status"), bridge, http))
            .Produces<UrgentPlaybackResponse>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        playback.MapPost("", UrgentPlayback)
            .Produces<UrgentPlaybackResponse>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        var ticker = app.MapGroup("/api/content/ticker/draft").WithTags("Content").RequireAuthorization();
        ticker.MapGet("", (IBridgeChannel bridge, HttpContext http) => TickerEditor(new("status"), bridge, http))
            .Produces<TickerEditorState>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        ticker.MapPost("", TickerEditor)
            .Produces<TickerEditorState>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> List(string view, int? page, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("content.list", new { actor = http.User.UserId(), view, page = page ?? 0 }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<ContentPage>(JsonDefaults.Options));
        }

        return reply.Error switch
        {
            "bad_view" => ApiErrors.Of(400, reply.Error),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "content_unreadable" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> WriteUrgent(UrgentWriteRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("urgent.write", new
        {
            actor = http.User.UserId(), request.Action, request.Revision, request.Id, request.Row
        }, http.RequestAborted);
        if (reply.Ok) return TypedResults.NoContent();
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "not_found" or "content_disabled" => ApiErrors.Of(404, reply.Error),
            "urgent_stale" => ApiErrors.Of(409, reply.Error),
            "urgent_invalid" => ApiErrors.Of(400, reply.Error),
            "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
            "urgent_save_failed" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> TickerEditor(TickerDraftRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("ticker.edit", new
        {
            actor = http.User.UserId(), request.Action, request.Revision, request.Index, request.Text, request.Review
        }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<TickerEditorState>(JsonDefaults.Options));
        }
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "ticker_stale" or "ticker_locked" or "ticker_conflict" => ApiErrors.Of(409, reply.Error),
            "ticker_invalid" or "ticker_full" => ApiErrors.Of(400, reply.Error),
            "content_unreadable" or "ticker_start_failed" or "ticker_publish_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> UrgentPlayback(UrgentPlaybackRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("urgent.playback", new
        {
            actor = http.User.UserId(), request.Action, request.SelectedIds, request.Review, request.RunId, request.Step
        }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<UrgentPlaybackResponse>(JsonDefaults.Options));
        }
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "urgent_stale" or "urgent_air_busy" or "urgent_stop_unconfirmed" => ApiErrors.Of(409, reply.Error),
            "urgent_invalid" => ApiErrors.Of(400, reply.Error),
            "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
            "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }
}
