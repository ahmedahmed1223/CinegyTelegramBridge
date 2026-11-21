using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AirTextEndpoints
{
    public static void MapAirTextEndpoints(this IEndpointRouteBuilder app) =>
        app.MapPost("/api/air/layers/{layer:int}/text", Correct).WithTags("Air").RequireAuthorization()
            .Produces<AirTextResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

    private static async Task<IResult> Correct(int layer, AirTextCommand request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.text", new { actor = http.User.UserId(), layer, request.Action, request.Values, request.Review }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<AirTextResult>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => 403,
            "live_text_invalid" or "live_text_required" or "live_text_too_long" => 400,
            "live_text_stale" or "live_text_managed" or "live_text_busy" or "live_text_no_fields" or
                "live_text_conflict" or "live_text_unverified" or "live_text_refused" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
