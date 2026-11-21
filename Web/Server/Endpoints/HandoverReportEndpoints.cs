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
        reports.MapPost("/handover/acknowledge", Acknowledge).Produces<HandoverAcknowledgement>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Weekly(HttpContext http, IBridgeChannel bridge) =>
        Send<WeeklyReport>(http, bridge, "reports.weekly");

    private static Task<IResult> Handover(HttpContext http, IBridgeChannel bridge) =>
        Send<ShiftHandoverReport>(http, bridge, "reports.handover");

    private static Task<IResult> Acknowledge(HandoverAcknowledgementCommand command, HttpContext http, IBridgeChannel bridge) =>
        Send<HandoverAcknowledgement>(http, bridge, "reports.handover.acknowledge",
            new { actor = http.User.UserId(), command.Reference });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, string operation, object? arguments = null) where T : class
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, arguments ?? new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error switch
            {
                "forbidden" => ApiErrors.Of(403, reply.Error),
                "handover_stale" or "handover_disabled" => ApiErrors.Of(409, reply.Error),
                "handover_unavailable" => ApiErrors.Of(503, reply.Error),
                _ => ApiErrors.BridgeUnavailable()
            };
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
