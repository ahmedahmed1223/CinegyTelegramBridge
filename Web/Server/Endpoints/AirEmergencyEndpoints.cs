using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AirEmergencyEndpoints
{
    public static void MapAirEmergencyEndpoints(this IEndpointRouteBuilder app)
    {
        var air = app.MapGroup("/api/air").RequireAuthorization().WithTags("Air");
        air.MapPost("/maintenance", Maintenance).RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AirMaintenanceResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        air.MapPost("/emergency-hide", Hide).Produces<EmergencyHideResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Maintenance(AirMaintenanceCommand request, IBridgeChannel bridge, HttpContext http) =>
        Reply<AirMaintenanceResult>(http, await bridge.SendAsync("air.maintenance", new
        {
            actor = http.User.UserId(), request.Action, request.Enabled, request.Review
        }, http.RequestAborted));

    private static async Task<IResult> Hide(EmergencyHideCommand request, IBridgeChannel bridge, HttpContext http) =>
        Reply<EmergencyHideResult>(http, await bridge.SendAsync("air.emergency-hide", new
        {
            actor = http.User.UserId(), request.Action, request.Review
        }, http.RequestAborted));

    private static IResult Reply<T>(HttpContext http, BridgeReply reply)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "maintenance_invalid" or "emergency_invalid" => 400,
            "maintenance_stale" or "emergency_stale" or "emergency_ambiguous" or
                "emergency_unverified" or "emergency_none" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
