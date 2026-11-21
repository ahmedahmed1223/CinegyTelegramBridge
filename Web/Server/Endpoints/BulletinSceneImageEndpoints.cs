using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

internal static class BulletinSceneImageEndpoints
{
    internal static void Map(RouteGroupBuilder bulletin)
    {
        bulletin.MapGet("/scene-images", List).Produces<BulletinSceneImagePage>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        bulletin.MapPost("/scene-images", Apply).Produces<BulletinEditor>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> List(string id, string rowId, int revision, int? page, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinSceneImagePage>(http, bridge, new { actor = http.User.UserId(), action = "list", id, rowId, revision, page });

    private static Task<IResult> Apply(BulletinSceneImageApply command, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinEditor>(http, bridge, new
        {
            actor = http.User.UserId(), action = "apply", command.Id, command.RowId, command.Revision, command.Selection, command.Slot
        });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, object arguments)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("bulletin.scene-images", arguments, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "bulletin_photo_invalid" => StatusCodes.Status400BadRequest,
            "forbidden" => StatusCodes.Status403Forbidden,
            "not_found" or "content_disabled" or "bulletin_scene_images_unavailable" => StatusCodes.Status404NotFound,
            "bulletin_stale" or "bulletin_scene_image_stale" => StatusCodes.Status409Conflict,
            _ => StatusCodes.Status503ServiceUnavailable
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
