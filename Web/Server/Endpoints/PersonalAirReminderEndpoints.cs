using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class PersonalAirReminderEndpoints
{
    public static void MapPersonalAirReminderEndpoints(this IEndpointRouteBuilder app)
    {
        var air = app.MapGroup("/api/air").WithTags("Air").RequireAuthorization();
        air.MapGet("/reminders", Read).Produces<PersonalAirRemindersView>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        air.MapPost("/reminders/{id}", Act).Produces<PersonalAirRemindersView>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Read(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        return Present(await bridge.SendAsync("air.personalReminders", new { actor = http.User.UserId() }, http.RequestAborted));
    }

    private static async Task<IResult> Act(string id, PersonalAirReminderCommand request, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        return Present(await bridge.SendAsync("air.personalReminder.act",
            new { actor = http.User.UserId(), id, request.Action }, http.RequestAborted));
    }

    private static IResult Present(BridgeReply reply)
    {
        if (!reply.Ok) return reply.Error switch
        {
            "reminder_invalid" => ApiErrors.Of(400, reply.Error),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "reminder_stale" => ApiErrors.Of(409, reply.Error),
            "reminder_save_failed" or "bridge_busy" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
        try
        {
            var view = reply.Data.Deserialize<PersonalAirRemindersView>(JsonDefaults.Options);
            return view is { Items: not null } ? TypedResults.Ok(view) : ApiErrors.BridgeUnavailable();
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
