using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AdminSettingsEndpoints
{
    public static void MapAdminSettingsEndpoints(this IEndpointRouteBuilder app)
    {
        var settings = app.MapGroup("/api/admin/settings").WithTags("Administration")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        settings.MapPost("/{id}/review", Review)
            .Produces<AdminSettingPreview>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(503);
        settings.MapPost("/{id}/confirm", Confirm)
            .Produces<AdminSettingResult>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Review(string id, AdminSettingReviewCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AdminSettingPreview>(http, bridge, "admin.settings.review",
            new { actor = http.User.UserId(), id, request.Enabled, request.Value });

    private static Task<IResult> Confirm(string id, AdminSettingConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AdminSettingResult>(http, bridge, "admin.settings.confirm",
            new { actor = http.User.UserId(), id, request.Review });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, string operation, object request)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, request, http.RequestAborted);
        if (!reply.Ok)
        {
            var status = reply.Error switch
            {
                "forbidden" => 403,
                "setting_not_editable" or "setting_invalid" => 400,
                "setting_stale" => 409,
                "setting_save_failed" or "bridge_busy" => 503,
                _ => 0
            };
            return status == 0 ? ApiErrors.BridgeUnavailable() : ApiErrors.Of(status, reply.Error);
        }

        try
        {
            var result = reply.Data.Deserialize<T>(JsonDefaults.Options);
            return result is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(result);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
