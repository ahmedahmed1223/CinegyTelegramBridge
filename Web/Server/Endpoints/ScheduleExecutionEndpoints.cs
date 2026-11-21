using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class ScheduleExecutionEndpoints
{
    public static void MapScheduleExecutionEndpoints(this IEndpointRouteBuilder app) =>
        app.MapGet("/api/schedule/executions", List).WithTags("Template schedule").RequireAuthorization()
            .Produces<ScheduleExecutionPage>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);

    private static async Task<IResult> List(string? kind, string? result, int? page, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("schedule.executions",
            new { actor = http.User.UserId(), kind, result, page = page ?? 0 }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<ScheduleExecutionPage>(JsonDefaults.Options));
        var status = reply.Error == "forbidden" ? StatusCodes.Status403Forbidden :
            reply.Error == "schedule_execution_invalid" ? StatusCodes.Status400BadRequest : StatusCodes.Status503ServiceUnavailable;
        return ApiErrors.Of(status, reply.Error);
    }
}
