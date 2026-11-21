using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TemplateMaxAirEndpoints
{
    public static void MapTemplateMaxAirEndpoints(this IEndpointRouteBuilder app)
    {
        var air = app.MapGroup("/api/air/templates").WithTags("Air").RequireAuthorization(AccountEndpoints.AdminPolicy);
        air.MapGet("/{key}/max-air", Read).Produces<TemplateMaxAirView>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(503);
        air.MapPost("/{key}/max-air/review", Review).Produces<TemplateMaxAirPreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        air.MapPost("/{key}/max-air/confirm", Confirm).Produces<TemplateMaxAirResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Read(string key, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.templateMaxAir", new { actor = http.User.UserId(), key }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TemplateMaxAirView>(reply);
        return result?.Key == key ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Review(string key, TemplateMaxAirReviewCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.templateMaxAir.review",
            new { actor = http.User.UserId(), key, request.Revision, request.Mode, request.Seconds }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TemplateMaxAirPreview>(reply);
        return result?.Current?.Key == key ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Confirm(string key, TemplateMaxAirConfirm request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (string.IsNullOrWhiteSpace(request.Review)) return Error("template_air_limit_invalid");
        var reply = await bridge.SendAsync("air.templateMaxAir.confirm",
            new { actor = http.User.UserId(), key, request.Review }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TemplateMaxAirResult>(reply);
        return result?.Key == key ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static T? ReadPayload<T>(BridgeReply reply)
    {
        try { return reply.Data.Deserialize<T>(JsonDefaults.Options); }
        catch (JsonException) { return default; }
    }

    private static IResult Error(string? code) => code switch
    {
        "template_air_limit_invalid" => ApiErrors.Of(400, code),
        "forbidden" => ApiErrors.Of(403, code),
        "scene_not_found" => ApiErrors.Of(404, code),
        "template_air_limit_stale" or "template_air_limit_unchanged" => ApiErrors.Of(409, code),
        "template_air_limit_save_failed" or "bridge_busy" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
