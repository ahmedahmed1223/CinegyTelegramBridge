using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AirLayerRemovalEndpoints
{
    public static void MapAirLayerRemovalEndpoints(this IEndpointRouteBuilder app) =>
        app.MapPost("/api/air/layers/{layer:int}/removal", Remove).WithTags("Air").RequireAuthorization()
            .Produces<AirLayerRemovalResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

    private static async Task<IResult> Remove(int layer, AirLayerRemovalCommand request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.layer-removal", new
        {
            actor = http.User.UserId(), layer, request.Action, request.Operation, request.Review
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<AirLayerRemovalResult>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "layer_removal_invalid" => 400,
            "layer_removal_stale" or "layer_removal_ambiguous" or "layer_removal_unverified" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
