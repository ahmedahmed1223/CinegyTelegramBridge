using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AdminOverviewEndpoints
{
    public static void MapAdminOverviewEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/admin/overview", Read)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AdminOverview>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> Read(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.overview", new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();

        try
        {
            var overview = reply.Data.Deserialize<AdminOverview>(JsonDefaults.Options);
            return overview is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(overview);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
