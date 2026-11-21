using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class HandoverReportEndpoints
{
    public static void MapHandoverReportEndpoints(this IEndpointRouteBuilder app)
    {
        var reports = app.MapGroup("/api/reports").WithTags("Reports").RequireAuthorization();
        reports.MapGet("/weekly", Weekly).Produces<WeeklyReport>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        reports.MapGet("/handover", Handover).Produces<ShiftHandoverReport>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Weekly(HttpContext http, IBridgeChannel bridge) =>
        Send<WeeklyReport>(http, bridge, "reports.weekly");

    private static Task<IResult> Handover(HttpContext http, IBridgeChannel bridge) =>
        Send<ShiftHandoverReport>(http, bridge, "reports.handover");

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, string operation)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error == "forbidden" ? ApiErrors.Of(403, reply.Error) : ApiErrors.BridgeUnavailable();
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
