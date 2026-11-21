using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class LayerNamesEndpoints
{
    public static void MapLayerNamesEndpoints(this IEndpointRouteBuilder app)
    {
        var admin = app.MapGroup("/api/admin").WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy);
        admin.MapGet("/layer-names", List).Produces<LayerNamesPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        admin.MapPost("/layer-names/{layer:int}/review", Review).Produces<LayerNamePreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        admin.MapPost("/layer-names/{layer:int}/confirm", Confirm).Produces<LayerNameView>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> List(int? page, int? pageSize, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.layerNames", new { actor = http.User.UserId(), page, pageSize }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<LayerNamesPage>(reply);
        return result is { Items: not null } ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Review(int layer, LayerNameReviewCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Name is null) return Error("bad_request");
        var reply = await bridge.SendAsync("admin.layerName.review",
            new { actor = http.User.UserId(), layer, request.Name }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<LayerNamePreview>(reply);
        return result?.Current?.Layer == layer ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Confirm(int layer, LayerNameConfirmCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (string.IsNullOrWhiteSpace(request.Review)) return Error("bad_request");
        var reply = await bridge.SendAsync("admin.layerName.confirm",
            new { actor = http.User.UserId(), layer, request.Review }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<LayerNameView>(reply);
        return result?.Layer == layer ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static T? ReadPayload<T>(BridgeReply reply)
    {
        try { return reply.Data.Deserialize<T>(JsonDefaults.Options); }
        catch (JsonException) { return default; }
    }

    private static IResult Error(string? code) => code switch
    {
        "bad_request" or "layer_name_invalid" or "layer_name_single_line" => ApiErrors.Of(400, code),
        "forbidden" => ApiErrors.Of(403, code),
        "layer_name_not_found" => ApiErrors.Of(404, code),
        "layer_name_stale" or "layer_name_unchanged" => ApiErrors.Of(409, code),
        "layer_name_save_failed" or "bridge_busy" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
