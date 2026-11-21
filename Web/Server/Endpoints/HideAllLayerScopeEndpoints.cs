using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class HideAllLayerScopeEndpoints
{
    public static void MapHideAllLayerScopeEndpoints(this IEndpointRouteBuilder app)
    {
        var air = app.MapGroup("/api/air").WithTags("Air").RequireAuthorization();
        air.MapGet("/emergency-hide/scope", Read).Produces<HideAllLayerScopeView>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        air.MapPost("/emergency-hide/scope/review", Review).RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<HideAllScopePreview>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        air.MapPost("/emergency-hide/scope/confirm", Confirm).RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<HideAllLayerScopeView>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Read(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.hideAllScope", new { actor = http.User.UserId() }, http.RequestAborted);
        return reply.Ok ? Present(ReadPayload<HideAllLayerScopeView>(reply)) : Error(reply.Error);
    }

    private static async Task<IResult> Review(HideAllScopeReviewCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.hideAllScope.review",
            new { actor = http.User.UserId(), request.Revision, request.Mode, request.Layers }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<HideAllScopePreview>(reply);
        return result is { Current: not null, SelectedLayers: not null } && Valid(result.Current)
            ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Confirm(HideAllScopeConfirmCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (string.IsNullOrWhiteSpace(request.Review)) return Error("hide_all_scope_invalid");
        var reply = await bridge.SendAsync("air.hideAllScope.confirm",
            new { actor = http.User.UserId(), request.Review }, http.RequestAborted);
        return reply.Ok ? Present(ReadPayload<HideAllLayerScopeView>(reply)) : Error(reply.Error);
    }

    private static IResult Present(HideAllLayerScopeView? result) =>
        result is not null && Valid(result) ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();

    private static bool Valid(HideAllLayerScopeView result) => result is { SelectedLayers: not null, KnownLayers: not null };

    private static T? ReadPayload<T>(BridgeReply reply)
    {
        try { return reply.Data.Deserialize<T>(JsonDefaults.Options); }
        catch (JsonException) { return default; }
    }

    private static IResult Error(string? code) => code switch
    {
        "hide_all_scope_invalid" => ApiErrors.Of(400, code),
        "forbidden" => ApiErrors.Of(403, code),
        "hide_all_scope_stale" or "hide_all_scope_unchanged" => ApiErrors.Of(409, code),
        "hide_all_scope_save_failed" or "bridge_busy" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
