using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class WorkSummaryEndpoints
{
    public static void MapWorkSummaryEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/reports/work-summary", Read)
            .WithTags("Reports")
            .RequireAuthorization()
            .Produces<WorkSummaryResponse>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> Read(string? period, string? scope, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("reports.work-summary",
            new { actor = http.User.UserId(), period, scope }, http.RequestAborted);
        if (!reply.Ok)
        {
            return reply.Error switch
            {
                "forbidden" => ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error),
                "report_invalid" => ApiErrors.Of(StatusCodes.Status400BadRequest, reply.Error),
                _ => ApiErrors.BridgeUnavailable()
            };
        }

        try
        {
            var summary = reply.Data.Deserialize<WorkSummaryResponse>(JsonDefaults.Options);
            return summary is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(summary);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
