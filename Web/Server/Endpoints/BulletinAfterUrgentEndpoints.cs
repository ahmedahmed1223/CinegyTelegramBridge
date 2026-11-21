using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class BulletinAfterUrgentEndpoints
{
    public static void MapBulletinAfterUrgentEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/content/bulletins/after-urgent").WithTags("Bulletins").RequireAuthorization();
        api.MapPost("/review", Review).Produces<BulletinAfterUrgentReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        api.MapPost("/confirm", Confirm).Produces<BulletinAfterUrgentResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Review(BulletinAfterUrgentReviewCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinAfterUrgentReview>(http, bridge, new { actor = http.User.UserId(), action = "review", request.Id, request.Revision });

    private static Task<IResult> Confirm(BulletinAfterUrgentConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinAfterUrgentResult>(http, bridge, new { actor = http.User.UserId(), action = "confirm", request.Review });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, object arguments)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("bulletin.afterUrgent", arguments, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "bulletin_invalid" => StatusCodes.Status400BadRequest,
            "forbidden" => StatusCodes.Status403Forbidden,
            "not_found" => StatusCodes.Status404NotFound,
            "bulletin_stale" or "bulletin_on_air" or "content_disabled" or "bulletin_playback_empty" or
                "bulletin_playback_unavailable" or "bulletin_urgent_gone" or "bulletin_urgent_unconfirmed" or
                "bulletin_schedule_clock" => StatusCodes.Status409Conflict,
            _ => StatusCodes.Status503ServiceUnavailable
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
