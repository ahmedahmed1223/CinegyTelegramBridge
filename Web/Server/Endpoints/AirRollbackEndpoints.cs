using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AirRollbackEndpoints
{
    public static void MapAirRollbackEndpoints(this IEndpointRouteBuilder app) =>
        app.MapPost("/api/air/rollback", Rollback).WithTags("Air").RequireAuthorization()
            .Produces<AirRollbackResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

    private static async Task<IResult> Rollback(AirRollbackCommand request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.rollback", new
        {
            actor = http.User.UserId(), request.Action, request.Layer, request.Review
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<AirRollbackResult>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "rollback_invalid" => 400,
            "rollback_missing" => 404,
            "rollback_stale" or "rollback_managed" or "rollback_scheduled" or "rollback_busy" or
                "rollback_unavailable" or "rollback_unverified" or "rollback_refused" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
