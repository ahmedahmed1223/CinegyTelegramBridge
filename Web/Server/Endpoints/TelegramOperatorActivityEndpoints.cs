using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TelegramOperatorActivityEndpoints
{
    public static void MapTelegramOperatorActivityEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/telegram-access/presence", ReadPresence)
            .WithTags("Telegram access").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<TelegramPresencePage>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);

        app.MapGet("/api/telegram-access/users/{userId:long}/activity", Read)
            .WithTags("Telegram access").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<TelegramOperatorActivity>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> ReadPresence(int? page, string? q, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (page < 0 || q?.Length > 80) return ApiErrors.Of(400, "bad_request");

        var reply = await bridge.SendAsync("telegram.access.presence",
            new { actor = http.User.UserId(), page, q }, http.RequestAborted);
        if (!reply.Ok) return reply.Error switch
        {
            "bad_request" => ApiErrors.Of(400, reply.Error),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };

        try
        {
            var result = reply.Data.Deserialize<TelegramPresencePage>(JsonDefaults.Options);
            return result is { Items: not null } ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }

    private static async Task<IResult> Read(long userId, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.access.operator-activity",
            new { actor = http.User.UserId(), userId }, http.RequestAborted);
        if (!reply.Ok) return reply.Error switch
        {
            "bad_request" => ApiErrors.Of(400, reply.Error),
            "forbidden" or "telegram_user_protected" => ApiErrors.Of(403, reply.Error),
            "telegram_user_unavailable" => ApiErrors.Of(409, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };

        try
        {
            var result = reply.Data.Deserialize<TelegramOperatorActivity>(JsonDefaults.Options);
            return result is { Today: not null } && result.UserId == userId
                ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
