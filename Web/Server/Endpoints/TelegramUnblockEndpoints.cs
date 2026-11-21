using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TelegramUnblockEndpoints
{
    public static void MapTelegramUnblockEndpoints(this IEndpointRouteBuilder app)
    {
        var blocked = app.MapGroup("/api/telegram-access/blocked").WithTags("Telegram access")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        blocked.MapGet("", List).Produces<BlockedAccessPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        blocked.MapPost("/{chatId:long}/review", Review).Produces<AccessUnblockPreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        blocked.MapPost("/{chatId:long}/confirm", Confirm).Produces<AccessUnblockResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> List(int? page, int? pageSize, HttpContext http, IBridgeChannel bridge) =>
        Send<BlockedAccessPage>(http, bridge, "telegram.access.blocked", new { actor = http.User.UserId(), page, pageSize });

    private static Task<IResult> Review(long chatId, HttpContext http, IBridgeChannel bridge) =>
        Send<AccessUnblockPreview>(http, bridge, "telegram.access.unblock.review", new { actor = http.User.UserId(), chatId });

    private static Task<IResult> Confirm(long chatId, AccessUnblockCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AccessUnblockResult>(http, bridge, "telegram.access.unblock.confirm", new { actor = http.User.UserId(), chatId, request.Review });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, string operation, object request)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, request, http.RequestAborted);
        if (!reply.Ok)
        {
            var status = reply.Error switch
            {
                "bad_request" => 400,
                "forbidden" => 403,
                "access_blocked_stale" => 409,
                "access_unblock_save_failed" or "bridge_busy" => 503,
                _ => 0
            };
            return status == 0 ? ApiErrors.BridgeUnavailable() : ApiErrors.Of(status, reply.Error);
        }

        try
        {
            var result = reply.Data.Deserialize<T>(JsonDefaults.Options);
            return result is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(result);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
