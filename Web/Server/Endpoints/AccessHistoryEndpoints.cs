using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AccessHistoryEndpoints
{
    public static void MapAccessHistoryEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/telegram-access/history", Read)
            .WithTags("Telegram access")
            .RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AccessHistoryPage>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> Read(int? page, int? pageSize, string? decision, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("telegram.access.history",
            new { actor = http.User.UserId(), page, pageSize, decision }, http.RequestAborted);
        if (!reply.Ok)
        {
            return reply.Error switch
            {
                "bad_request" => ApiErrors.Of(StatusCodes.Status400BadRequest, reply.Error),
                "forbidden" => ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error),
                _ => ApiErrors.BridgeUnavailable()
            };
        }
        try
        {
            var history = reply.Data.Deserialize<AccessHistoryPage>(JsonDefaults.Options);
            return history is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(history);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
