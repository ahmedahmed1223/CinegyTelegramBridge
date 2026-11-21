using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;


public static class TelegramDeliveryQuarantineEndpoints
{
    public static void MapTelegramDeliveryQuarantineEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/telegram-access")
            .WithTags("Telegram access").RequireAuthorization(AccountEndpoints.AdminPolicy);
        group.MapGet("/delivery-quarantine", List).Produces<TelegramDeliveryQuarantinePage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        group.MapPost("/delivery-quarantine/{chatId:long}/reset/review", Review).Produces<TelegramDeliveryQuarantineReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        group.MapPost("/delivery-quarantine/{chatId:long}/reset/confirm", Confirm).Produces<TelegramDeliveryQuarantineReset>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> List(int? page, int? pageSize, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.delivery.quarantine",
            new { actor = http.User.UserId(), page, pageSize }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TelegramDeliveryQuarantinePage>(reply);
        return result is { Items: not null } ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Review(long chatId, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.delivery.quarantine.reset.review",
            new { actor = http.User.UserId(), chatId }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TelegramDeliveryQuarantineReview>(reply);
        return result?.Target?.ChatId == chatId ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static async Task<IResult> Confirm(long chatId, TelegramDeliveryQuarantineConfirm request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (string.IsNullOrWhiteSpace(request.Review)) return Error("bad_request");
        var reply = await bridge.SendAsync("telegram.delivery.quarantine.reset.confirm",
            new { actor = http.User.UserId(), chatId, request.Review }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var result = ReadPayload<TelegramDeliveryQuarantineReset>(reply);
        return result?.ChatId == chatId ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
    }

    private static T? ReadPayload<T>(BridgeReply reply)
    {
        try { return reply.Data.Deserialize<T>(JsonDefaults.Options); }
        catch (JsonException) { return default; }
    }

    private static IResult Error(string? code) => code switch
    {
        "bad_request" => ApiErrors.Of(400, code),
        "forbidden" or "telegram_quarantine_protected" => ApiErrors.Of(403, code),
        "telegram_quarantine_unavailable" or "telegram_quarantine_stale" => ApiErrors.Of(409, code),
        "telegram_quarantine_save_failed" or "bridge_busy" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable()
    };
}
