using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TemplateIssueEndpoints
{
    public static void MapTemplateIssueEndpoints(this IEndpointRouteBuilder app) =>
        app.MapPost("/api/air/template-issues", Manage).WithTags("Air").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<TemplateIssueResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

    private static async Task<IResult> Manage(TemplateIssueCommand request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.template-issues", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Review
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<TemplateIssueResult>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "template_issue_invalid" => 400,
            "scene_registry_stale" or "template_issue_layer_unverified" or "scene_definition_live" or
                "scene_definition_scheduled" or "scene_definition_linked" or "scene_definition_alias" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
