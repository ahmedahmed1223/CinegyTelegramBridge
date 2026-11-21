using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class ShiftNoticeEndpoints
{
    public static void MapShiftNoticeEndpoints(this IEndpointRouteBuilder app)
    {
        var notices = app.MapGroup("/api/notices").WithTags("On-air notices").RequireAuthorization();
        notices.MapGet("/me", GetPersonal).Produces<PersonalAirNotice>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        notices.MapPut("/me", UpdatePersonal).Produces<PersonalAirNotice>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        var rules = notices.MapGroup("/template-rules").RequireAuthorization(AccountEndpoints.AdminPolicy);
        rules.MapGet("", GetRules).Produces<TemplateAirNoticePage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        rules.MapPut("/{key}", UpdateRule).Produces<TemplateAirNoticePage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> GetPersonal(HttpContext http, IBridgeChannel bridge) =>
        Send<PersonalAirNotice>(http, bridge, new { actor = http.User.UserId(), area = "personal", action = "read" });

    private static Task<IResult> UpdatePersonal(PersonalAirNoticeChange change, HttpContext http, IBridgeChannel bridge) =>
        Send<PersonalAirNotice>(http, bridge,
            new { actor = http.User.UserId(), area = "personal", action = "update", change.Muted, change.ExpectedMuted });

    private static Task<IResult> GetRules(int? page, HttpContext http, IBridgeChannel bridge) =>
        Send<TemplateAirNoticePage>(http, bridge, new { actor = http.User.UserId(), area = "rules", action = "list", page = page ?? 0 });

    private static Task<IResult> UpdateRule(string key, TemplateAirNoticeChange change, HttpContext http, IBridgeChannel bridge) =>
        Send<TemplateAirNoticePage>(http, bridge, new
        {
            actor = http.User.UserId(), area = "rules", action = "update", key, change.Scope, change.ExpectedScope, page = change.Page ?? 0
        });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, object arguments)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("shift.notices", arguments, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" => StatusCodes.Status403Forbidden,
            "notices_invalid" => StatusCodes.Status400BadRequest,
            "notices_no_telegram" or "notices_stale" or "notices_template_gone" => StatusCodes.Status409Conflict,
            _ => StatusCodes.Status503ServiceUnavailable
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
