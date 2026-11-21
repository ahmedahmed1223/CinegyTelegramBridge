using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TelegramAliasEndpoints
{
    public static void MapTelegramAliasEndpoints(this IEndpointRouteBuilder app)
    {
        var access = app.MapGroup("/api/telegram-access").WithTags("Telegram access")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        access.MapPost("/users/{userId:long}/alias/review", Review).Produces<TelegramAliasPreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        access.MapPost("/users/{userId:long}/alias/confirm", Confirm).Produces<TelegramAliasResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Review(long userId, TelegramAliasReviewCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Alias is null) return Error("bad_request");
        var reply = await bridge.SendAsync("telegram.access.alias.review",
            new { actor = http.User.UserId(), userId, request.Alias }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var preview = ReadPayload<TelegramAliasPreview>(reply);
        return preview?.Target?.Id == userId ? TypedResults.Ok(preview) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Confirm(long userId, TelegramAliasConfirmCommand request, HttpContext http,
        IBridgeChannel bridge, BridgeIdentity identity)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (string.IsNullOrWhiteSpace(request.Review)) return Error("bad_request");
        var reply = await bridge.SendAsync("telegram.access.alias.confirm",
            new { actor = http.User.UserId(), userId, request.Review }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TelegramAliasResult>(reply);
        if (result is null || result.UserId != userId) return ApiErrors.BridgeUnavailable();
        identity.Forget(userId);
        return TypedResults.Ok(result);
    }

    private static T? ReadPayload<T>(BridgeReply reply)
    {
        try { return reply.Data.Deserialize<T>(JsonDefaults.Options); }
        catch (JsonException) { return default; }
    }

    private static IResult Error(string? code) => code switch
    {
        "bad_request" or "telegram_alias_too_long" or "telegram_alias_multiline" => ApiErrors.Of(400, code),
        "forbidden" or "telegram_user_protected" => ApiErrors.Of(403, code),
        "telegram_user_unavailable" or "telegram_alias_stale" or "telegram_alias_unchanged" => ApiErrors.Of(409, code),
        "telegram_alias_save_failed" or "bridge_busy" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
