using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class OperationMetricsEndpoints
{
    public static void MapOperationMetricsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/admin/operations/metrics", GetMetrics)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<OperationMetrics>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);


        app.MapGet("/api/admin/operations/engine-health", GetEngineHealth)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<EngineHealthReading>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(429).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> GetEngineHealth(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.engine-health", new { actor = http.User.UserId() }, http.RequestAborted);
        if (reply.Ok && reply.Data.Deserialize<EngineHealthReading>(JsonDefaults.Options) is { } health)
            return TypedResults.Ok(health);
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "layer_comparison_busy" => ApiErrors.Of(429, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> GetMetrics(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.operation-metrics", new { actor = http.User.UserId() }, http.RequestAborted);
        if (reply.Ok && reply.Data.Deserialize<OperationMetrics>(JsonDefaults.Options) is { } metrics)
            return TypedResults.Ok(metrics);
        return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();
    }
}
