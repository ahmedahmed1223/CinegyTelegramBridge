using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AirTimerEndpoints
{
    public static void MapAirTimerEndpoints(this IEndpointRouteBuilder app) =>
        app.MapPost("/api/air/layers/{layer:int}/timer", Timer).WithTags("Air").RequireAuthorization()
            .Produces<AirTimerResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

    private static async Task<IResult> Timer(int layer, AirTimerCommand request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.timer", new
        {
            actor = http.User.UserId(), layer, request.Action, request.Seconds, request.AdjustSeconds, request.Review
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<AirTimerResult>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "live_timer_invalid" => 400,
            "live_timer_stale" or "live_timer_managed" or "live_timer_unverified" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
