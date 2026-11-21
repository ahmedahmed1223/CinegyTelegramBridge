using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TelegramRosterEndpoints
{
    public static void MapTelegramRosterEndpoints(this IEndpointRouteBuilder app)
    {
        var roster = app.MapGroup("/api/telegram-access/users/{userId:long}/revoke")
            .WithTags("Telegram access").RequireAuthorization(AccountEndpoints.AdminPolicy);
        roster.MapPost("/review", Review)
            .Produces<TelegramRevokePreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        roster.MapPost("/confirm", Confirm)
            .Produces<TelegramRevokeResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Review(long userId, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.access.revoke.review",
            new { actor = http.User.UserId(), userId }, http.RequestAborted);
        return reply.Ok ? TypedResults.Ok(reply.Data.Deserialize<TelegramRevokePreview>(JsonDefaults.Options)) : Error(reply.Error);
    }

    private static async Task<IResult> Confirm(
        long userId, TelegramRevokeConfirmCommand request, HttpContext http,
        IBridgeChannel bridge, BridgeIdentity identity, SessionStore sessions)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.access.revoke.confirm",
            new { actor = http.User.UserId(), userId, request.Review }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = reply.Data.Deserialize<TelegramRevokeResult>(JsonDefaults.Options);
        if (result is null || result.UserId != userId) return ApiErrors.BridgeUnavailable();
        identity.Forget(userId);
        await sessions.RemoveForUserAsync(userId);
        return TypedResults.Ok(result);
    }

    private static IResult Error(string? code) => code switch
    {
        "bad_request" => ApiErrors.Of(400, code),
        "forbidden" or "telegram_user_protected" => ApiErrors.Of(403, code),
        "telegram_user_unavailable" or "telegram_user_stale" => ApiErrors.Of(409, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
