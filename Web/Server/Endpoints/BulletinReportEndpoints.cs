using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class BulletinReportEndpoints
{
    public static void MapBulletinReportEndpoints(this IEndpointRouteBuilder app)
    {
        var report = app.MapGroup("/api/reports/bulletins").WithTags("Reports").RequireAuthorization();
        report.MapGet("", List).Produces<BulletinReportPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        report.MapGet("/export", Export).Produces<BulletinReportExport>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> List(string? period, string? scope, int? page, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinReportPage>(http, bridge, new { actor = http.User.UserId(), action = "list", period, scope, page });

    private static Task<IResult> Export(string? period, string? scope, HttpContext http, IBridgeChannel bridge) =>
        Send<BulletinReportExport>(http, bridge, new { actor = http.User.UserId(), action = "export", period, scope });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, object args)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("reports.bulletins", args, http.RequestAborted);
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
