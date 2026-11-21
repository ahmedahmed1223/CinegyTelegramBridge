using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TemplateFavoritesEndpoints
{
    public static void MapTemplateFavoritesEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/air/templates").WithTags("Air").RequireAuthorization();
        group.MapGet("/favorites", Read).Produces<TemplateFavoritesView>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        group.MapPut("/{key}/favorite", Set).Produces<TemplateFavoritesView>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Read(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        return Present(await bridge.SendAsync("air.templateFavorites", new { actor = http.User.UserId() }, http.RequestAborted));
    }

    private static async Task<IResult> Set(string key, TemplateFavoriteCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Selected is null) return ApiErrors.Of(400, "favorites_invalid");
        return Present(await bridge.SendAsync("air.templateFavorite.set",
            new { actor = http.User.UserId(), key, selected = request.Selected.Value }, http.RequestAborted));
    }

    private static IResult Present(BridgeReply reply)
    {
        if (!reply.Ok) return reply.Error switch
        {
            "favorites_invalid" => ApiErrors.Of(400, reply.Error),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "not_found" => ApiErrors.Of(404, reply.Error),
            "favorites_disabled" => ApiErrors.Of(409, reply.Error),
            "favorite_save_failed" or "bridge_busy" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
        try
        {
            var view = reply.Data.Deserialize<TemplateFavoritesView>(JsonDefaults.Options);
            return view is { SelectedKeys: not null, PromotedKeys: not null, EligibleKeys: not null }
                ? TypedResults.Ok(view) : ApiErrors.BridgeUnavailable();
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
