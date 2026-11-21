using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TickerReportEndpoints
{
    public static void MapTickerReportEndpoints(this IEndpointRouteBuilder app)
    {
        var report = app.MapGroup("/api/reports/ticker").WithTags("Reports").RequireAuthorization();
        report.MapGet("", Read).Produces<TickerReportResponse>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        report.MapGet("/export", Export).Produces<TickerReportExport>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Read(string? period, string? scope, HttpContext http, IBridgeChannel bridge) =>
        Send<TickerReportResponse>(http, bridge, new { actor = http.User.UserId(), action = "list", period, scope });

    private static Task<IResult> Export(string? period, string? scope, HttpContext http, IBridgeChannel bridge) =>
        Send<TickerReportExport>(http, bridge, new { actor = http.User.UserId(), action = "export", period, scope });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, object args)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("reports.ticker", args, http.RequestAborted);
        if (!reply.Ok)
        {
            return reply.Error switch
            {
                "report_invalid" => ApiErrors.Of(400, reply.Error),
                "forbidden" => ApiErrors.Of(403, reply.Error),
                _ => ApiErrors.BridgeUnavailable()
            };
        }

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
