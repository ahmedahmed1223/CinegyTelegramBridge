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

        app.MapGet("/api/admin/readiness", ReadReadiness)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<ShiftReadinessReport>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        app.MapGet("/api/admin/notifications/coverage", ReadNotificationCoverage)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AdminNotificationCoverage>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static Task<IResult> ReadNotificationCoverage(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<AdminNotificationCoverage>(http, bridge, "admin.notifications.coverage");

    private static Task<IResult> ReadReadiness(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<ShiftReadinessReport>(http, bridge, "admin.readiness");

    private static Task<IResult> Read(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<AdminOverview>(http, bridge, "admin.overview");

    private static async Task<IResult> ReadReport<T>(HttpContext http, IBridgeChannel bridge, string operation) where T : class
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();

        try
        {
            var report = reply.Data.Deserialize<T>(JsonDefaults.Options);
            return report is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(report);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
