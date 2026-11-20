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
}
