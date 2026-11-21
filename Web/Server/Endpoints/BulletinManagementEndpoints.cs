using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class BulletinManagementEndpoints
{
    public static void MapBulletinManagementEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/content/bulletins/management").WithTags("Bulletins").RequireAuthorization();
        api.MapPost("/review", Review).Produces<BulletinManagementReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        api.MapPost("/confirm", Confirm).Produces<BulletinManagementResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Review(BulletinManagementReviewCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinManagementReview>(http, bridge,
            new { actor = http.User.UserId(), action = "review", request.Id, request.Revision, request.Operation });

    private static Task<IResult> Confirm(BulletinManagementConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinManagementResult>(http, bridge, new { actor = http.User.UserId(), action = "confirm", request.Review });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, object arguments)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("bulletin.management", arguments, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "bulletin_invalid" => StatusCodes.Status400BadRequest,
            "forbidden" => StatusCodes.Status403Forbidden,
            "not_found" => StatusCodes.Status404NotFound,
            "bulletin_stale" or "bulletin_empty" or "bulletin_on_air" or "content_disabled" => StatusCodes.Status409Conflict,
            _ => StatusCodes.Status503ServiceUnavailable
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
