using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TemplateSceneReplacementEndpoints
{
    public static void MapTemplateSceneReplacementEndpoints(this IEndpointRouteBuilder app) =>
        app.MapPost("/api/air/templates/{key}/scene", Replace).WithTags("Air").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<TemplateSceneReplacementResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

    private static async Task<IResult> Replace(string key, TemplateSceneReplacementCommand request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.templateScene", new
        {
            actor = http.User.UserId(), key, request.Action, request.Revision, request.File, request.Selection, request.Review
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<TemplateSceneReplacementResult>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "scene_definition_invalid" or "scene_replacement_format" or "scene_replacement_size" => 400,
            "scene_not_found" => 404,
            "scene_registry_stale" or "scene_definition_live" or "scene_definition_scheduled" or "scene_definition_linked" or
                "scene_replacement_managed" or "scene_replacement_incompatible" or "scene_replacement_unverified" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
