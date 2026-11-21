using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TelegramSuspensionEndpoints
{
    public static void MapTelegramSuspensionEndpoints(this IEndpointRouteBuilder app)
    {
        var access = app.MapGroup("/api/telegram-access").WithTags("Telegram access")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        access.MapGet("/suspended-operators", List).Produces<SuspendedTelegramOperatorsPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        access.MapPost("/users/{userId:long}/suspension/review", Review).Produces<TelegramSuspensionPreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        access.MapPost("/users/{userId:long}/suspension/confirm", Confirm).Produces<TelegramSuspensionResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> List(int? page, int? pageSize, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.access.suspended-operators",
            new { actor = http.User.UserId(), page, pageSize }, http.RequestAborted);
        return reply.Ok ? Result(ReadPayload<SuspendedTelegramOperatorsPage>(reply)) : Error(reply.Error);
    }

    private static async Task<IResult> Review(long userId, TelegramSuspensionReviewCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Disabled is null) return Error("bad_request");
        var reply = await bridge.SendAsync("telegram.access.suspension.review",
            new { actor = http.User.UserId(), userId, disabled = request.Disabled.Value }, http.RequestAborted);
        return reply.Ok ? Result(ReadPayload<TelegramSuspensionPreview>(reply)) : Error(reply.Error);
    }

    private static async Task<IResult> Confirm(long userId, TelegramSuspensionConfirmCommand request, HttpContext http,
        IBridgeChannel bridge, BridgeIdentity identity, SessionStore sessions)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.access.suspension.confirm",
            new { actor = http.User.UserId(), userId, request.Review }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TelegramSuspensionResult>(reply);
        if (result is null || result.UserId != userId) return ApiErrors.BridgeUnavailable();
        identity.Forget(userId);
        if (result.Disabled) await sessions.RemoveForUserAsync(userId);
        return TypedResults.Ok(result);
    }

    private static T? ReadPayload<T>(BridgeReply reply)
    {
        try { return reply.Data.Deserialize<T>(JsonDefaults.Options); }
        catch (JsonException) { return default; }
    }

    private static IResult Result<T>(T? data) => data is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(data);

    private static IResult Error(string? code) => code switch
    {
        "bad_request" => ApiErrors.Of(400, code),
        "forbidden" or "telegram_user_protected" => ApiErrors.Of(403, code),
        "telegram_user_unavailable" or "telegram_suspension_stale" => ApiErrors.Of(409, code),
        "telegram_suspension_save_failed" or "bridge_busy" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
